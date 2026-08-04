# Robin 3 SMU table-3 and queue-4 analysis

## Executive conclusion

Robin 3 table 3 is real, queue 4 is implemented, and the firmware explicitly
permits table-3 transfers from queues 3 and 4. The queue-4 messages used by
`bc250-cyan-skillfish-8core-cpu-metrics.patch` are the correct firmware API:

| Operation | Message | Firmware function |
|---|---:|---:|
| Set tools address high | `0x3e` | `0x1b9f4` |
| Set tools address low | `0x3f` | `0x1ba10` |
| Transfer SMU to host | `0x22` | `0x1ba5c` |

The earlier queue-3 patch is deterministically broken for table 3. Messages
`0x7a/0x7b` update the *driver* address descriptor, while table 3's transfer
function requires the separately published *tools* descriptor. With the
current correct queue-3 argument register, the firmware should reject the
transfer rather than DMA table 3.

The queue-4 implementation can still appear unstable for reasons outside the
three mailbox handlers:

1. Table 3 is a stateful interval accumulator. Its first request starts the
   sampler and returns mailbox success **without doing a DMA**.
2. The queue-4 patch poisons the BO before taking `smu->message_lock`, releases
   the lock before invalidating HDP and decoding, and uses the same BO for every
   reader. Concurrent `gpu_metrics` reads can poison or overwrite one another.
3. Any transient failure in any queue-4 message sets a module-global permanent
   disable latch. It never retries and is not reset per device or after an SMU
   reset.
4. `smu->message_lock` coordinates kernel callers only. It cannot serialize a
   userspace queue-3/queue-4 client, and the firmware tools destination is
   global mutable state.
5. The current build does not use the queue-4 patch. `build.sh` applies
   `bc250-cyan-skillfish-8core-metrics.patch`, which is the non-working
   `0x7a/0x7b` queue-3 version. The separate
   `bc250-cyan-skillfish-8core-cpu-metrics.patch` contains the queue-4 code.

Static analysis therefore does **not** show that firmware functions `0x1b9f4`,
`0x1ba10`, or `0x1ba5c` are intrinsically broken. It shows a valid firmware
route wrapped by unsafe host-side lifetime/concurrency behavior. Live hardware
tracing is still required to distinguish a queue-4 transport timeout from the
expected first-request no-DMA result.

## Provenance and Ghidra setup

| Artifact | Value |
|---|---|
| ROM | `BC250_3.00_CHIPSETMENU.ROM` |
| ROM SHA-256 | `48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5` |
| PMFW ROM range | offset `0x8ff000`, size `0x40200` |
| PMFW SHA-256 | `6a3da1ef6024c3143283fb92468fd71d628e9402a751c4a9799a20f473549ad9` |
| Runtime payload | PMFW offset `0x100`, size `0x40100` |
| Ghidra | 12.1.2, `Xtensa:LE:32:default` |

The executable/data runtime mapping is:

```text
PMFW file offset = runtime address + 0x100
```

The previous version of this report said `+0x104`. That was wrong: it places
each function four bytes after its Xtensa `entry` instruction. The old verifier
still read the intended physical bytes because all of its named runtime
locations were also four bytes low. `verify-robin3-firmware.py` now uses the
correct `+0x100` mapping and true runtime locations.

`ghidra/ExportSmuAnalysis.java` handles two raw-image analysis issues: Ghidra
initially marks the mailbox argument getter as non-returning, and it cannot
decode one Xtensa floating-point helper. Correcting those flow properties
exposes the complete handlers and the `0x188`-byte table callback.

## Mailbox layout

Firmware stores these queue descriptors at runtime `0x7030`:

| Queue | Argument | Response | Command | Host PCIe aperture used by patch |
|---:|---:|---:|---:|---|
| 3 | `0x03010a88` | `0x03010a80` | `0x03010a20` | `0x03b10a88/80/20` |
| 4 | `0x03010a8c` | `0x03010a84` | `0x03010a24` | `0x03b10a8c/84/24` |

Queues 3 and 4 use the same message dispatch table but independent mailbox
registers. The shared table starts at runtime `0x7464`; therefore the actual
pointer slots are `0x7574` for message `0x22`, `0x7654/0x765c` for
`0x3e/0x3f`, and `0x7834/0x783c` for `0x7a/0x7b`.

## Address handlers

The firmware represents an address as a 12-byte descriptor. Offset `0` is the
high word, offset `4` is the low word, and byte `0xb` contains validity bits.

| Function | Behavior |
|---:|---|
| `0x0ffc` | Read the current queue's argument register |
| `0x0fa8` | Write the current queue's response register |
| `0x398d4` | Store address high word and set validity bit 0 |
| `0x398e8` | Store address low word and set validity bit 1 |
| `0x398fc` | Return true only when both validity bits are set (`byte[0xb] == 3`) |
| `0x39910` | Copy a complete address descriptor, with carry handling |

### Driver setters `0x1b998/0x1b9b4`

These handlers read the mailbox argument and write high/low words to the
driver descriptor at `0xca38`. They then return response `1`.

Primary messages `0x04/0x05` and queue-3 messages `0x7a/0x7b` point here.
They are suitable for the normal driver tables but do not publish table 3's
tools destination.

### Tools setters `0x1b9f4/0x1ba10`

These handlers write high/low words to a tools staging descriptor at `0xca48`
and call `0x1b9d0`. Once both words are valid, `0x1b9d0` copies that descriptor
to table 3's effective descriptor at `0xcad8` and copies associated mode
metadata. Each handler then returns response `1`.

This staging/publish step is why merely pointing table 3 at the driver setters
cannot work.

## Transfer handler `0x1ba5c`

Message `0x22` performs these checks synchronously:

1. Read the table ID from the active queue argument register.
2. Reject unsupported IDs; this image accepts `0`, `3`, and `6`.
3. Select the address descriptor according to queue and table. Queue 3 or 4,
   table 3 selects the effective tools descriptor at `0xcad8`.
4. Require the selected descriptor to have both address words valid.
5. Check the table's queue permission bit.
6. Require a non-null table callback and invoke it with the descriptor.
7. Return response `1`; any failed check returns `0xff`.

Table 3's descriptor is based at runtime `0xca28`. Its callback slot at
`0xcac8` contains `0x276dc`, and its permission byte at `0xcad4` is `0x18`.
Bits 3 and 4 are therefore explicitly enabled.

The handler does not inspect whether the callback actually initiated DMA. A
callback that only initializes sampling still produces mailbox success.

## Table-3 producer

### Sampler `0x27528`

The sampler is installed as firmware event/callback ID `0x1b`. On every sample
it locks firmware state, adds current power/temperature/frequency values into
float accumulators, increments the sample count at accumulator offset `0x2f4`,
and unlocks.

It accumulates eight instances of the per-core groups and two instances of the
L3 groups. These are averages over the interval between successful exports,
not point-in-time values.

### Export callback `0x276dc`

The callback has two distinct paths:

**No samples available:** It calls `0x276cc`, which clears `0xbf` words
(`0x2fc` bytes) of accumulator state and registers sampler `0x27528`. It then
returns. No destination descriptor is consumed and no DMA occurs, but
`0x1ba5c` still reports success.

**Samples available:** It locks accumulator state, calculates the inverse
sample count, writes averaged values into a static `0x344`-byte export buffer,
resets the accumulator, unlocks, then calls DMA helper `0x3a850` with:

```text
destination = table-3 tools descriptor
source      = firmware export buffer
size        = 0x344
```

The DMA helper serializes its own firmware DMA resources and returns before
the mailbox success is posted. An optional post-transfer path at `0x286f8`
toggles a hardware control bit when enabled.

### CPU fields used by the patch

| Offset | Count | Firmware representation | Driver conversion |
|---:|---:|---|---|
| `0x118` | 8 | Average core power, float W | `*1000` to mW |
| `0x158` | 8 | Average core temperature, float C | `*100` to centi-C |
| `0x198` | 8 | Average core frequency, float GHz | `*1000` to MHz |
| `0x2a8` | 2 | Average L3 temperature, float C | `*100` to centi-C |
| `0x2c0` | 2 | Average L3 frequency, float GHz | `*1000` to MHz |

## Patch analysis

### Queue-3 patch currently selected by `build.sh`

`bc250-cyan-skillfish-8core-metrics.patch` sends:

```text
queue 3: 0x7a(high), 0x7b(low), 0x22(table 3)
```

The argument register in the checked-in file, `0x03b10a88`, is correct. The
failure is descriptor selection: `0x7a/0x7b` complete `0xca38`, but queue-3
table 3 checks `0xcad8`. Normally the transfer returns `0xff` and the driver
logs core metrics unavailable.

`bc250-cyan-skillfish-q3-table3-tools-fix.patch` is an experimental follow-up
that retains queue 3 but replaces `0x7a/0x7b` with `0x3e/0x3f`. This sequence is
statically valid because queue 3 shares those dispatch entries and table 3's
permission mask includes bit 3. The correction also keeps BO poisoning, HDP
synchronization, transfer, poison detection, and decode under one message-lock
transaction. It is intentionally not applied by `build.sh` pending live tests.

An older experiment used `0x03b10a60` as the queue-3 argument register. That is
not queue 3's argument register. Stale table IDs/addresses in that experiment
could select another valid table and initiate DMA to an unintended address,
which is a plausible explanation for the historical machine-wide wedge. That
specific register bug is not present in the checked-in patch.

### Queue-4 patch

`bc250-cyan-skillfish-8core-cpu-metrics.patch` uses the correct sequence and
poisons the destination to detect the first-request no-DMA case. Its important
host-side problems are:

**Shared BO race:** `memset` and HDP flush occur before `message_lock`; HDP
invalidate and all decoding occur after unlocking. The lock protects only the
three mailbox commands, not the table transaction. Two readers can interleave
as follows:

```text
A: poison BO
A: transfer, unlock
B: poison BO
A: invalidate/decode B's poison
B: transfer, unlock
```

The reverse ordering can also make one reader decode another reader's interval.
All BO access, address publication, transfer, invalidate, and decode must be one
critical section.

**Expected success without data:** The first firmware callback returns success
without DMA. Poison validation correctly rejects the bytes, but diagnostics
that only record mailbox response will misleadingly report a successful
transfer. A warm-up state or explicit `-EAGAIN` result is required.

**Permanent global latch:** Any timeout, busy response, prerequisite rejection,
or setter failure sets `cyan_skillfish_q4_disabled = true`. This is global to
the module and survives until unload/reboot. A single transient event therefore
looks like a permanently broken queue.

**External-client race:** A userspace OC/metrics tool can alter the global tools
descriptor between the low-word publish and transfer. Kernel mutexes and
userspace `flock` do not coordinate with each other.

**No queue-idle ownership protocol:** The helper clears queue 4's response and
submits immediately. This is safe only if the kernel is the sole queue-4 owner.
It cannot detect an in-flight command issued by another client.

## Recommended safe design

1. Use tools messages `0x3e`, `0x3f`, `0x22` for table 3. Queue 4 is preferred
   for isolation; queue 3 is valid only when other queue-3 clients are excluded.
2. Move poison/flush inside the same lock as address publication and transfer.
3. Keep that lock through HDP invalidation, poison detection, and copying the
   five arrays into private stack storage; decode can then finish after unlock.
4. Treat untouched poison after mailbox success as expected warm-up (`-EAGAIN`),
   not as a queue failure. Retry only after at least one sampler interval.
5. Remove the module-global permanent disable flag. Track state per SMU device
   and permit recovery after transient errors or SMU reset.
6. Ensure no userspace tool accesses queues 3 or 4 while kernel table-3 metrics
   are enabled. A kernel-owned queue cannot be made safe with userspace-only
   advisory locks.
7. Trace each message, argument, raw response, elapsed time, and whether the BO
   changed. This separates transport failure from the callback's valid no-DMA
   initialization path.
8. Do not fall back to table 6 on an unlocked eight-core Robin 3; its CPU rows
   overlap unrelated fields.

## Confidence and limits

The dispatch, descriptor publication, permission check, sampler, averaging,
`0x344` size, and DMA call are confirmed statically in the exact ROM image.
Static analysis cannot prove that queue 4 is routed correctly on every board or
that an observed PCIe timeout has no electrical/firmware scheduling cause. The
next useful evidence is a serialized live trace that records all three queue-4
responses and detects whether the destination changed on the first and second
requests.
