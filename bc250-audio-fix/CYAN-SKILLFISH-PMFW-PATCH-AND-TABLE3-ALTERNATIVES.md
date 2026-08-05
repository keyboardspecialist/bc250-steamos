# Cyan Skillfish PMFW patch and table 3 alternatives

## Purpose

This document describes possible changes to the Cyan Skillfish power-management
firmware (PMFW). It also describes the PMFW table 3 transfer path and the known
alternatives to message `0x22`.

This document applies to Cyan Skillfish PMFW version `0x00580600` from
`BC250_3.00_CHIPSETMENU.ROM`.

This document uses ASD-STE100 Simplified Technical English principles. Code
identifiers, register names, and firmware terms keep their technical spelling.

## Main conclusions

1. A normal DXE driver cannot replace the signed PMFW image before PMFW starts.
2. An early PEI module (PEIM) can possibly change the running PMFW after the
   Platform Security Processor (PSP) authenticates it.
3. PMFW messages `0x28` and `0x29` provide a gated local-memory write path.
4. The useful access period can exist before the PMFW scheduler starts. This
   access period is not confirmed on the BC-250.
5. Message `0x22` is the only full table 3 transfer command.
6. The table 3 failure probably occurs in one of two unbounded DMA waits.
7. Message `0x27` is the preferred alternative if an early PEIM can remove its
   runtime prerequisite.
8. Message `0x43` is an ungated alternative for per-core frequency only.

## Terms

| Term | Definition |
|---|---|
| DXE | Driver Execution Environment, which runs after PEI |
| PEI | Pre-EFI Initialization phase |
| PEIM | A module that runs during PEI |
| PMFW | AMD power-management firmware that runs on MP1 |
| PSP | AMD Platform Security Processor |
| SMN | AMD System Management Network |
| DMA | Direct memory access |
| Queue | A host-to-PMFW mailbox interface |
| Prerequisite | A PMFW dispatcher condition that permits a message |

## PMFW image and start sequence

The ROM stores PMFW at file offset `0x8ff000`. The complete PMFW container is
`0x40200` bytes.

The container has these parts:

| Container offset | Size | Contents |
|---:|---:|---|
| `0x000` | `0x100` | PSP firmware header |
| `0x100` | `0x40000` | PMFW code and data |
| `0x40100` | `0x100` | RSA-PSS signature |

The PSP directory identifies this container as type `0x08`. The SHA-256 digest
in the header matches the code and data. The RSA-PSS signature also verifies
against an AMD public key in the ROM.

UEFI Secure Boot does not control this signature. Disabling Secure Boot does
not permit an unsigned PMFW image.

The ROM contains an `AmdNbioSmuV10Pei` PEIM. This PEIM performs early SMU
initialization. PMFW is therefore active before the DXE phase.

A DXE driver can send SMN and mailbox commands to the running PMFW. The existing
core-unlock EFI application uses this method. A DXE driver cannot change the
signed image before its first execution.

## Possible runtime patch path

The PMFW queue 3 and queue 4 dispatch table contains three local-memory
operations.

| Message | Handler | Operation |
|---:|---:|---|
| `0x27` | `0x27c94` | Read one PMFW-local 32-bit word |
| `0x28` | `0x27cc0` | Store a PMFW-local pointer |
| `0x29` | `0x27cd8` | Write one 32-bit argument through the stored pointer |

All three dispatch entries have configuration `0x00000201`. Prerequisite bit
`0x02` controls these entries.

The dispatcher recalculates bit `0x02` for each message. It enables the bit when
the gate-state word at `0x7b3c` is zero. It also enables the bit when SMN
register `0x03210064` contains `0x80000000`. Normal runtime does not enable the
bit.

A live queue 4 request for message `0x27` returned response `0xfd`. This response
means that a prerequisite was not available. Messages `0x28` and `0x29` have
the same prerequisite and must also fail in this state.

An early PEIM can possibly use messages `0x28` and `0x29` after PMFW starts and
before the scheduler closes this access. This sequence is not yet confirmed.

### Preferred early patch

The preferred patch changes only the dispatch configuration for message
`0x27`.

The message `0x27` dispatch entry starts at PMFW runtime address `0x759c`. Its
configuration word is at runtime address `0x75a0`.

An early PEIM can try this sequence:

1. Wait for a valid queue response value.
2. Send message `0x28` with argument `0x000075a0`.
3. Require response `0x01`.
4. Send message `0x29` with argument `0x00000001`.
5. Require response `0x01`.
6. Send message `0x27` for one known safe address.
7. Require response `0x01` and verify the returned value.

The patch changes `0x00000201` to `0x00000001`. It removes prerequisite
`0x02` from message `0x27`. It does not remove the prerequisite from the local
write messages.

This design has a smaller risk than an unrestricted runtime write interface.
Linux can use message `0x27` to read the source records. Linux does not have to
request table 3 or use the table 3 DMA path.

### PEIM timing risk

The required access period can be very short. PMFW must accept mailbox commands,
and the gate-state word at `0x7b3c` must still be zero.

A PEIM that runs too early cannot communicate with PMFW. A PEIM that runs too
late receives response `0xfd`.

The firmware load order must be measured before implementation. Static analysis
does not show when PMFW writes the gate-state word in relation to the x86 PEI
modules.

Do not try to create the required prerequisite through a PMFW exception. An
exception can leave PMFW and the graphics device in an unknown state.

## Table 3 host sequence

The host uses three messages for a table 3 transfer.

| Message | Argument | Operation |
|---:|---:|---|
| `0x3e` | Destination high 32 bits | Set tools address high |
| `0x3f` | Destination low 32 bits | Set tools address low |
| `0x22` | `3` | Transfer table 3 to the host |

Queues 3 and 4 use separate mailbox registers. Both queues use the same PMFW
dispatch entries, table callback, address descriptor, and DMA engine.

Messages `0x3e` and `0x3f` write a staging descriptor at `0xca48`. Function
`0x1b9d0` publishes the complete descriptor at `0xcad8` after both address words
are valid.

Message `0x22` calls handler `0x1ba5c`. The handler does these checks:

1. Read the table identifier from the active queue argument register.
2. Accept only table identifiers `0`, `3`, and `6`.
3. Select an address descriptor for the queue and table.
4. Require both address words to be valid.
5. Check the table queue-permission mask.
6. Require a valid table callback.
7. Call the callback.
8. Write mailbox response `0x01` after the callback returns.

Table 3 uses callback `0x276dc`. Its queue-permission mask is `0x18`. This mask
permits queues 3 and 4.

## Table 3 sampler and callback

Table 3 is an interval average. It is not an immediate snapshot.

The sampler is function `0x27528`. It collects these groups:

| Group | Count |
|---|---:|
| Scalar values | 47 |
| Per-core groups | 12 groups for 8 cores |
| L3 groups | 9 groups for 2 L3 instances |

The sampler increments the sample count at accumulator offset `0x2f4`.

Callback `0x276dc` has two paths.

### No-sample path

If the sample count is zero, the callback clears the accumulator. It registers
sampler `0x27528` as event `0x1b`. It then returns without DMA.

Handler `0x1ba5c` still writes mailbox response `0x01`. A successful mailbox
response does not prove that PMFW transferred data.

### Export path

If samples are available, the callback performs this sequence:

1. Lock the accumulator.
2. Calculate the reciprocal of the sample count.
3. Average the accumulated values.
4. Build the `0x344`-byte export at PMFW address `0x11b08`.
5. Clear the accumulator.
6. Unlock the accumulator.
7. Call `0x3a850(destination, 0x11b08, 0x344)`.
8. Perform an optional hardware action.
9. Return to handler `0x1ba5c`.

The callback clears the accumulator before DMA. A failed DMA therefore also
loses the accumulated interval.

## DMA path

Function `0x3a850` transfers PMFW-local memory to the host destination.

For table 3, its arguments are:

```text
destination = tools descriptor at 0xcad8
source      = PMFW export buffer at 0x11b08
size        = 0x344 bytes
```

Function `0x3a850` performs this sequence:

1. Select two address-translation slots.
2. Take PMFW lock `0x100`.
3. Program address translation from the destination descriptor.
4. Build a short DMA request.
5. Submit the DMA request.
6. Wait for DMA completion.
7. Remove the translation entries.
8. Release PMFW lock `0x100`.

The function does not return an error value.

### Unbounded waits

The short DMA submission function waits while bit 0 of SMN register
`0x03270d00` is set. This wait has no timeout.

The completion function waits for the low nibble of channel 0 status register
`0x03270100` to become `0` or `0xf`. This wait also has no timeout.

Handler `0x1ba5c` cannot write a mailbox response while either wait is active.

### Live result

The isolated queue 4 probe produced this sequence:

1. The first `0x3e`, `0x3f`, and `0x22` sequence returned response `0x01`.
2. The first sequence did not change the destination buffer.
3. The driver waited 250 ms for samples.
4. The second `0x3e` and `0x3f` messages returned response `0x01`.
5. The second `0x22` message did not complete in one second.
6. The driver marked PMFW as hung and blocked later SMU messages.

This result places the failure in the sampled export path. Queue separation and
host serialization do not prevent the failure.

The most probable stop location is one of the two DMA waits. A stop in the
accumulator lock is less probable because the callback releases that lock before
it calls the DMA helper.

## Address-translation difference

Table 3 and table 6 use the same DMA helper. They use different destination
descriptor modes.

| Transfer | Descriptor mode byte | Additional mode byte | Size path |
|---|---:|---:|---|
| Table 3 tools descriptor | `0` | `0` | Short DMA |
| Table 6 driver descriptor | `1` | `4` | Short DMA |

Mode `0` calls translation function `0x39768`. Mode `1` calls translation
function `0x39698` with the additional mode value `4`.

Table 3 is `0x344` bytes. Table 6 is `0xf4` bytes. Both sizes use the same short
DMA format. The transfer-size mode does not explain the failure.

The tools translation mode is the main known difference. It is a hypothesis,
not a confirmed cause. Other AMD drivers also allocate the tools table in VRAM,
so a VRAM destination is not by itself an error.

A test can copy the driver descriptor mode bytes to the tools descriptor. This
test can show whether mode `1/4` avoids the DMA stop. The test can still hang the
graphics device. Use it only as an isolated one-shot test with reset recovery.

## Alternatives to message 0x22

There is no other command that transfers the complete table 3 export.

| Mechanism | Queues | Result for table 3 |
|---|---|---|
| Message `0x06` | Primary queue 0 | Uses the same transfer handler, but queue 0 cannot select table 3 |
| Message `0x11` | Queue 2 | Uses the same transfer handler, but queue 2 can transfer table 0 only |
| Message `0x22` | Queues 3 and 4 | Only complete table 3 transfer route |
| Message `0x23` | Queues 3 and 4 | Transfers host data to PMFW and does not accept table 3 |
| Message `0x27` | Queues 3 and 4 | Reads PMFW-local source data without DMA, but prerequisite `0x02` blocks normal runtime |
| Message `0x43` | Queues 3 and 4 | Returns one core frequency without DMA or a special prerequisite |
| Table 6 | Primary queue 0 | Transfers safely before a table 3 failure, but eight-core data overwrites adjacent fields |
| Messages `0x31` to `0x33` | Queues 3 and 4 | Control a separate telemetry subsystem that is not fully understood |

### Message 0x27

Message `0x27` accepts a PMFW-local aligned address. It returns one 32-bit word
in the mailbox argument register.

The source-record base is `0xfac4`. Each core record has size `0x178`.

```text
record[n] = 0xfac4 + n * 0x178
power     = float32(record[n] + 0x10)
temperature = float32(record[n] + 0x1c)
frequency = float32(record[n] + 0x140)
C0 ratio  = float32(record[n] + 0x14c)
```

This path does not use the table 3 accumulator. It does not call callback
`0x276dc`. It does not use DMA helper `0x3a850`.

### Message 0x43

Message `0x43` accepts a core identifier from `0` through `7`. It reads the
frequency value at source-record offset `0x140`. It multiplies the value by
1000 and returns an integer frequency in MHz.

The dispatch entry has no special prerequisite. This command is the lowest-risk
unvalidated source for all eight core frequencies.

No equivalent ungated direct command is known for per-core power, current
temperature, or C0 ratio.

### Table 6 partial data

Table 6 has six entries in each published per-core array. Cyan Skillfish writes
eight entries when all eight cores are active. The last two entries overwrite
fields that follow each array.

Some raw fields can possibly be recovered from the overwritten positions. This
method cannot recover a complete and reliable set of power, temperature,
frequency, and C0 values. It is not a replacement for table 3 or message
`0x27`.

## Firmware patch options

| Option | Feasibility | Main risk |
|---|---|---|
| Replace PMFW in SPI flash | Low | PSP rejects the modified RSA-PSS signature |
| Patch PMFW from a normal DXE driver | Low | DXE runs after the prerequisite closes |
| Patch PMFW from an early PEIM with `0x28/0x29` | Possible but not confirmed | The usable mailbox period can be absent or very short |
| Remove the `0x27` prerequisite | Preferred | Requires one successful early local write |
| Change the tools descriptor to mode `1/4` | Experimental | The next table 3 DMA can still hang |
| Add timeouts to PMFW DMA loops | Difficult | Requires Xtensa code patching, instruction-cache control, and correct cleanup |
| Find a host-writable MP1 memory aperture | Unknown | No safe aperture or MP1 halt sequence is known |

## Recommended work

1. Do not issue another table 3 transfer during normal operation.
2. Add a read-only failure capture for registers `0x03270d00` and `0x03270100`.
3. Capture the DMA register state immediately after a controlled timeout.
4. Validate message `0x43` for core identifiers `0` through `7` after a clean
   reboot.
5. Identify the exact PEI order between PSP PMFW start and
   `AmdNbioSmuV10Pei` scheduler initialization.
6. Build a PEIM that first tests message `0x27` and records its response.
7. Permit the PEIM to use `0x28/0x29` only when a persistent one-attempt guard
   is present.
8. If the early write succeeds, remove only the message `0x27` prerequisite.
9. Use message `0x27` to read source records from Linux.
10. Aggregate source values in the host driver instead of using table 3 DMA.

## Safety requirements

Do not retry a mailbox command after a timeout. Do not use a table 6 health
check after an unfinished table 3 transfer. Reset the graphics device or reboot
the system first.

Use a persistent one-attempt guard for every PEI or EFI patch experiment. Verify
the exact ROM hash and PMFW version before each write. Refuse the operation when
the firmware version, dispatch entry, or expected old value does not match.

Keep a verified firmware recovery method before a modified PEIM is installed in
the SPI image. A bad PEI dependency or flash-volume change can prevent the
system from booting.

## Evidence files

The main repository evidence is in these files:

- `CYAN-SKILLFISH-METRICS-ANALYSIS.md`
- `SMU-QUEUE3-QUEUE4-TABLE3-REFERENCE.md`
- `verify-cyan-skillfish-firmware.py`
- `probe-cyan-skillfish-metrics.py`
- `bc250-cyan-skillfish-table3-probe.patch`
- `core-unlock/bc250-unlock-cores-efi.c`

The external aligned Ghidra decompilation artifact used for the detailed
control flow is:

```text
smu-3.00-aligned-decompiled.c
```
