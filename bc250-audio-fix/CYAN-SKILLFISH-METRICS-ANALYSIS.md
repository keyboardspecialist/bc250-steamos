# Cyan Skillfish SMU table-3 and queue-4 analysis

## Conclusion

Table 3 and queue 4 are available in the Cyan Skillfish firmware. The firmware
allows table-3 transfers from queues 3 and 4. The queue-4 patch uses the correct
firmware messages:

| Operation | Message | Firmware function |
|---|---:|---:|
| Set the high word of the tools address | `0x3e` | `0x1b9f4` |
| Set the low word of the tools address | `0x3f` | `0x1ba10` |
| Transfer data from the SMU to the host | `0x22` | `0x1ba5c` |

The earlier queue-3 patch cannot transfer table 3. Messages `0x7a` and `0x7b`
update the driver address descriptor. The table-3 transfer function requires
the tools address descriptor. The firmware publishes this descriptor
separately. With the correct queue-3 argument register, the firmware rejects
the transfer. It does not transfer table 3.

The queue-4 implementation can appear unstable for these reasons:

1. Table 3 uses an interval accumulator. The first request starts the sampler.
   The firmware reports mailbox success, but it does not do a DMA transfer.
2. The queue-4 patch poisons the buffer object (BO) before it takes
   `smu->message_lock`. It releases the lock before HDP invalidation and decode.
   All readers use the same BO. Concurrent `gpu_metrics` reads can poison or
   overwrite data from other readers.
3. A temporary queue-4 message failure activates a permanent global disable
   latch. The patch does not try the operation again. An SMU reset does not
   reset the latch, and the latch is not specific to a device.
4. `smu->message_lock` controls kernel callers only. It cannot control a
   user-space client on queue 3 or queue 4. The firmware tools destination is
   global state that clients can change.
5. The current build uses queue 3 with tools messages `0x3e`, `0x3f`, and
   `0x22`. One message-lock transaction contains BO poisoning, transfer, HDP
   synchronization, and decode. The separate
   `bc250-cyan-skillfish-8core-cpu-metrics.patch` contains the queue-4 test.

Static analysis does not show a fault in firmware functions `0x1b9f4`,
`0x1ba10`, or `0x1ba5c`. Use a live hardware trace to identify a transport
timeout. The trace also identifies the expected no-DMA result from the first
request.

## Source data and Ghidra setup

| Artifact | Value |
|---|---|
| ROM | `BC250_3.00_CHIPSETMENU.ROM` |
| ROM SHA-256 | `48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5` |
| PMFW ROM range | Offset `0x8ff000`, size `0x40200` |
| PMFW SHA-256 | `6a3da1ef6024c3143283fb92468fd71d628e9402a751c4a9799a20f473549ad9` |
| Runtime payload | PMFW offset `0x100`, size `0x40100` |
| Ghidra | 12.1.2, `Xtensa:LE:32:default` |

Use this equation for the executable and data runtime mapping:

```text
PMFW file offset = runtime address + 0x100
```

The previous report used `+0x104`. This value was incorrect. It puts each
function four bytes after its Xtensa `entry` instruction. The old verifier read
the correct physical bytes because its named runtime locations were also four
bytes too low. `verify-cyan-skillfish-firmware.py` uses the correct `+0x100`
mapping and the correct runtime locations.

`ghidra/ExportSmuAnalysis.java` corrects two raw-image analysis problems. At
first, Ghidra marks the mailbox argument getter as a function that does not
return. Ghidra also cannot decode one Xtensa floating-point helper. The script
corrects these flow properties. Ghidra then shows the complete handlers and the
`0x188`-byte table callback.

## Mailbox layout

The firmware stores these queue descriptors at runtime address `0x7030`:

| Queue | Argument | Response | Command | Host PCIe aperture used by the patch |
|---:|---:|---:|---:|---|
| 3 | `0x03010a88` | `0x03010a80` | `0x03010a20` | `0x03b10a88/80/20` |
| 4 | `0x03010a8c` | `0x03010a84` | `0x03010a24` | `0x03b10a8c/84/24` |

Queues 3 and 4 use the same message dispatch table. Each queue has separate
mailbox registers. The shared table starts at runtime address `0x7464`:

- Message `0x22` uses pointer slot `0x7574`.
- Messages `0x3e` and `0x3f` use pointer slots `0x7654` and `0x765c`.
- Messages `0x7a` and `0x7b` use pointer slots `0x7834` and `0x783c`.

## Address handlers

The firmware represents an address with a 12-byte descriptor. Offset `0`
contains the high word. Offset `4` contains the low word. Byte `0xb` contains
the validity bits.

| Function | Function operation |
|---:|---|
| `0x0ffc` | Read the argument register of the current queue |
| `0x0fa8` | Write the response register of the current queue |
| `0x398d4` | Store the high address word and set validity bit 0 |
| `0x398e8` | Store the low address word and set validity bit 1 |
| `0x398fc` | Return true only if `byte[0xb] == 3` |
| `0x39910` | Copy a complete address descriptor and process the carry |

### Driver setters `0x1b998` and `0x1b9b4`

These handlers read the mailbox argument. They write the high and low words to
the driver descriptor at `0xca38`. Then, each handler returns response `1`.

Primary messages `0x04` and `0x05` use these handlers. Queue-3 messages `0x7a`
and `0x7b` also use them. The handlers are correct for the standard driver
tables. They do not publish the tools destination for table 3.

### Tools setters `0x1b9f4` and `0x1ba10`

These handlers write the high and low words to a tools staging descriptor at
`0xca48`. They also call `0x1b9d0`. When the two words are valid, `0x1b9d0`
copies the descriptor to the effective table-3 descriptor at `0xcad8`. It also
copies the related mode data. Then, each handler returns response `1`.

This staging and publication step is necessary. The driver setters cannot
publish the tools destination for table 3.

## Transfer handler `0x1ba5c`

Message `0x22` does these checks in sequence:

1. Read the table ID from the argument register of the active queue.
2. Reject an unsupported ID. This firmware accepts IDs `0`, `3`, and `6`.
3. Select the address descriptor for the queue and table. For queue 3 or 4 and
   table 3, select the effective tools descriptor at `0xcad8`.
4. Make sure that the selected descriptor has two valid address words.
5. Check the queue permission bit for the table.
6. Make sure that the table callback is not null. Call the callback with the
   descriptor.
7. Return response `1`. If a check fails, return response `0xff`.

The descriptor for table 3 starts at runtime address `0xca28`. The callback
slot at `0xcac8` contains `0x276dc`. The permission byte at `0xcad4` is `0x18`.
Thus, permission bits 3 and 4 are enabled.

The handler does not check if the callback starts a DMA transfer. A callback
that only initializes the sampler still causes mailbox success.

## Table-3 data producer

### Sampler `0x27528`

The firmware installs the sampler as event and callback ID `0x1b`. For each
sample, the sampler locks the firmware state. It adds current power,
temperature, and frequency values to floating-point accumulators. It increments
the sample count at accumulator offset `0x2f4`. Then, it unlocks the firmware
state.

The sampler collects eight instances of each per-core group. It also collects
two instances of each L3 group. The exported values are averages for the
interval between successful exports. They are not point-in-time values.

### Export callback `0x276dc`

The callback has two paths.

#### No samples available

The callback calls `0x276cc`. This function clears `0xbf` words (`0x2fc` bytes)
of accumulator state. It also registers sampler `0x27528`. Then, the callback
returns. It does not use the destination descriptor, and no DMA transfer occurs.
However, `0x1ba5c` reports success.

#### Samples available

The callback does these operations:

1. Lock the accumulator state.
2. Calculate the inverse sample count.
3. Write the average values to a static `0x344`-byte export buffer.
4. Reset the accumulator.
5. Unlock the accumulator state.
6. Call DMA helper `0x3a850` with these values:

```text
destination = table-3 tools descriptor
source      = firmware export buffer
size        = 0x344
```

The DMA helper controls access to its firmware DMA resources. It returns before
the firmware posts mailbox success. An optional path at `0x286f8` changes a
hardware control bit after the transfer. Firmware uses this path only when the
option is enabled.

### CPU fields that the patch uses

| Offset | Count | Firmware representation | Driver conversion |
|---:|---:|---|---|
| `0x118` | 8 | Average core power, float W | `*1000` to mW |
| `0x158` | 8 | Average core temperature, float C | `*100` to centi-C |
| `0x198` | 8 | Average core frequency, float GHz | `*1000` to MHz |
| `0x2a8` | 2 | Average L3 temperature, float C | `*100` to centi-C |
| `0x2c0` | 2 | Average L3 frequency, float GHz | `*1000` to MHz |

## Patch analysis

### Queue-3 patch selected by `build.sh`

`bc250-cyan-skillfish-8core-metrics.patch` sends this sequence:

```text
queue 3: 0x3e(tools high), 0x3f(tools low), 0x22(table 3)
```

Argument register `0x03b10a88` is correct. Queue 3 uses the tools-setter
dispatch entries. The table-3 permission mask includes bit 3. One message-lock
transaction contains these operations:

- BO poisoning.
- HDP synchronization.
- Transfer.
- Poison detection.
- Decode.

The patch returns `-EAGAIN` if the first result is unchanged.

The previous revision used messages `0x7a` and `0x7b`. These messages complete
the driver descriptor at `0xca38`. Table 3 checks the tools descriptor at
`0xcad8`. Thus, the firmware rejected the transfer.

An older test used `0x03b10a60` as the queue-3 argument register. This register
is not the queue-3 argument register. Stale table IDs or addresses could select
a different valid table. They could also start DMA to an incorrect address.
This is a possible cause of the previous system-wide hang. The checked-in
patch does not have this register error.

### Queue-4 patch

`bc250-cyan-skillfish-8core-cpu-metrics.patch` uses the correct message
sequence. It poisons the destination to detect the first-request no-DMA
condition. However, it has these host-side problems.

#### Shared BO race condition

`memset` and the HDP flush occur before `message_lock`. HDP invalidation and
decode occur after the patch releases the lock. The lock protects only the
three mailbox commands. It does not protect the complete table transaction.
Two readers can use this sequence:

```text
A: poison BO
A: transfer, unlock
B: poison BO
A: invalidate/decode B's poison
B: transfer, unlock
```

The opposite order can cause one reader to decode another reader's interval.
Put all BO access in one critical section. This section must include address
publication, transfer, invalidation, and decode.

#### Expected success without data

The first firmware callback reports success without a DMA transfer. Poison
validation correctly rejects the unchanged bytes. However, mailbox-response
diagnostics report success although no data moved. Use a warm-up state or
return `-EAGAIN`.

#### Permanent global latch

A timeout, busy response, prerequisite rejection, or setter failure sets
`cyan_skillfish_q4_disabled = true`. This value is global to the module. It
remains set until module unload or reboot. Thus, one temporary event can make
the queue appear permanently faulty.

#### External-client race condition

A user-space overclocking or metrics tool can change the global tools
descriptor. This can occur between low-word publication and transfer. Kernel
mutexes and user-space `flock` locks do not control each other.

#### No queue ownership protocol

The helper clears the queue-4 response and immediately submits a command. This
is safe only when the kernel is the only queue-4 owner. The helper cannot detect
a command from a different client that is in progress.

## Safe design

1. Use tools messages `0x3e`, `0x3f`, and `0x22` for table 3.
2. Prefer queue 4 because it gives more isolation. Use queue 3 only when no
   other queue-3 client can operate.
3. Put BO poisoning and the HDP flush in the address-publication and transfer
   lock.
4. Keep the lock during HDP invalidation and poison detection. Also keep it
   while you copy the five arrays to private stack storage.
5. Decode the copied values after you release the lock.
6. Treat unchanged poison after mailbox success as warm-up result `-EAGAIN`.
   Do not treat it as a queue failure.
7. Wait for one sampler interval before you try the operation again.
8. Remove the permanent module-global disable flag.
9. Keep the state for each SMU device. Permit recovery after a temporary error
   or an SMU reset.
10. Make sure that user-space tools do not use queue 3 or 4 when kernel table-3
    metrics are enabled. A user-space advisory lock cannot make a kernel-owned
    queue safe.
11. Trace each message, argument, raw response, and elapsed time. Also record if
    the BO changed.
12. Use the trace to identify transport failures and valid no-DMA
    initialization results.
13. Do not use table 6 when all eight Cyan Skillfish cores are enabled. Its CPU
    rows overlap unrelated fields.

## Confidence and limits

Static analysis of the exact ROM confirms these items:

- Dispatch entries.
- Descriptor publication.
- Permission checks.
- Sampler operation.
- Average calculations.
- The `0x344`-byte table size.
- The DMA call.

Static analysis cannot prove correct queue-4 routing on every board. It also
cannot exclude an electrical or firmware-scheduling cause for a PCIe timeout.
The next useful test is a serialized live trace. Record all three queue-4
responses. Also record if the destination changes on the first and second
requests.
