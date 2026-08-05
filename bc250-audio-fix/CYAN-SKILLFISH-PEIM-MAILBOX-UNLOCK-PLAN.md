# Cyan Skillfish PEIM mailbox unlock plan

## Purpose

This document gives a plan for a PEI module (PEIM). The PEIM will make PMFW
message `0x27` available after PMFW initialization.

This plan does not make the PMFW write messages available at normal runtime.
Messages `0x28` and `0x29` will stay protected.

This document applies to Cyan Skillfish PMFW version `0x00580600` from
`BC250_3.00_CHIPSETMENU.ROM`.

This document uses ASD-STE100 Simplified Technical English principles. Code
identifiers and firmware terms keep their technical spelling.

## Safety status

The test system does not have a verified external SPI recovery method.

Do not flash a modified ROM to this system. Development can continue through
build, emulation, and offline ROM verification. Hardware tests must wait until
a safe recovery method is available.

CMOS reset does not restore executable firmware. The built-in AMI recovery path
is not a verified substitute for an external SPI programmer.

## Objective

The PEIM will change one PMFW dispatch configuration word:

```text
PMFW runtime address 0x75a0
old value: 0x00000201
new value: 0x00000001
```

This change removes prerequisite `0x02` from message `0x27`. It keeps the
dispatcher class value `0x01`.

Queues 3 and 4 use the same dispatch table. Thus, this change makes message
`0x27` available on both queues.

The PEIM will not change these entries:

```text
message 0x28: set a PMFW-local write pointer
message 0x29: write through the PMFW-local pointer
messages 0x2a through 0x2f: direct or structured memory operations
```

## Verified prerequisite behavior

The PMFW dispatcher is function `0x0ebc`. It recalculates prerequisite bit
`0x02` for each message.

The dispatcher uses these values:

| Item | Address or value |
|---|---:|
| Dynamic prerequisite bitmap | PMFW runtime `0x7ad0` |
| Gate-state word | PMFW runtime `0x7b3c` |
| Special SMN state register | `0x03210064` |
| Special comparison value | `0x80000000` |

The effective logic is:

```c
gate_state = *(uint32_t *)0x7b3c;

available = *(uint32_t *)0x7ad0;
available &= ~0x02;

if (gate_state == 0 ||
    SMN32(0x03210064) == 0x80000000)
    available |= 0x02;
```

PMFW initialization later writes the gate-state word:

```c
*(uint32_t *)0x7b3c =
    (SMN32(0x012101c0) & 0x00080000) >> 19;
```

The value at `0x7b3c` is initially zero. The normal runtime value on the tested
BC-250 is probably one. A live message `0x27` request returned response `0xfd`.
This response means that prerequisite `0x02` was not available.

The useful access period has these conditions:

```text
PMFW accepts mailbox commands.
The value at 0x7b3c is still zero.
Messages 0x27, 0x28, and 0x29 are accepted.
PMFW initialization writes 1 to 0x7b3c.
The protected messages then return 0xfd.
```

Do not call this transition a scheduler transition. Static analysis proves the
assignment to `0x7b3c`. It does not prove the name or the complete purpose of
this state.

Do not try to create the special SMN state at `0x03210064`. Its hardware purpose
is not known. An artificial exception state can make PMFW unstable.

## Relevant protected messages

All entries from message `0x27` through message `0x2f` have configuration
`0x00000201`.

| Message | Entry | Handler | Operation |
|---:|---:|---:|---|
| `0x27` | `0x759c` | `0x27c94` | Guarded PMFW-local 32-bit read |
| `0x28` | `0x75a4` | `0x27cc0` | Set PMFW-local write pointer |
| `0x29` | `0x75ac` | `0x27cd8` | Write through the local pointer |
| `0x2a` | `0x75b4` | `0x27cf8` | Direct SMN read |
| `0x2b` | `0x75bc` | `0x27d1c` | Set direct SMN write address |
| `0x2c` | `0x75c4` | `0x27d34` | Direct SMN write |
| `0x2d` | `0x75cc` | `0x27d54` | Structured local or MMIO read |
| `0x2e` | `0x75d4` | `0x27df4` | Set structured write selector |
| `0x2f` | `0x75dc` | `0x27e18` | Structured write |

Message `0x27` uses a local fault guard. It returns response `0xff` when its
guard detects an access failure.

Messages `0x28` and `0x29` do not validate the target address. They use a global
pointer that queues 3 and 4 share. These messages are safe only for one known
aligned write during the early protected period.

## PEI boot structure

The active PEI firmware volume starts at ROM offset `0xe02000`. Its size is
`0x1fe000` bytes.

The PEI phase uses IA32 images. A custom PEIM must use machine type `0x14c` and
EFI subsystem `11`.

The relevant firmware files are:

| Module | GUID | ROM offset |
|---|---|---:|
| PEI Core | `52c05b14-0b98-496c-bc3b-04b50211d680` | `0xe02f88` |
| `AmdNbioSmuV10Pei` | `7307bd0f-8b7a-4ba5-9af6-3997d1e32786` | `0xe890f0` |
| `AmdPspPeiV2` | `0c556bff-b16a-439d-a3ec-1164378e2c2a` | `0xe9f3d8` |
| SEC core | `1ba0062e-c779-4582-8566-336ae8f78f09` | `0xffeae8` |

The PEI firmware volume has a large PAD file from `0xef8b20` through
`0xffeae8`. A custom FFS file can use part of this space without moving the SEC
core or the reset vector.

Physical file order does not by itself specify PEIM execution order. PEI
dependency expressions do not support the `BEFORE` opcode. The ROM integration
must replace the PEI Apriori file. It must put the larger replacement in the PAD
region and mark the original Apriori file deleted. The replacement must keep
the original GUID order and append the custom PEIM GUID.

## Earliest practical hook

`AmdNbioSmuV10Pei` installs an SMU-services PPI with this GUID:

```text
ea335e48-7275-4d2b-8276-55ba5531d7d7
```

The module installs this PPI before it calls `AmdNbioSmuEarlyInit`.

The custom PEIM will register a synchronous notification callback for this PPI.
It will use `EFI_PEI_PPI_DESCRIPTOR_NOTIFY_CALLBACK`. It will not use deferred
dispatch notification.

The callback runs during the `InstallPpi` operation. This point is earlier than
a PEIM that has a normal dependency on the SMU-services PPI.

PPI installation does not prove that prerequisite `0x02` is available. The
first PEIM must measure this condition with a read-only command.

The custom PEIM will use this dependency expression:

```text
TRUE
```

The PEIM entry point will only register the notification callback. It will not
wait for PMFW and it will not access a mailbox. The PEI Apriori list must run
this entry point before `AmdNbioSmuV10Pei` installs the SMU-services PPI.

## Planned source layout

Use this project layout:

```text
bc250-pmfw-pei/
  Bc250Pkg.dec
  Bc250Pkg.dsc
  Bc250Pkg.fdf
  Bc250EarlyProbePeim.inf
  Bc250EarlyProbePeim.c
  Bc250PeiResult.h
  Bc250PeiReportEfi.c
  verify-bc250-pei-rom.py
```

The PEIM will use these EDK2 library classes:

```text
PeimEntryPoint
PeiServicesLib
BaseLib
IoLib
BaseMemoryLib
HobLib
```

The PEIM will use raw PCI configuration and SMN access. It will not require
proprietary AMD libraries.

## Mailbox registers

Use queue 4 for the early operation.

| Register | Host SMN address |
|---|---:|
| Command | `0x03b10a24` |
| Response | `0x03b10a84` |
| Argument | `0x03b10a8c` |

Queues 3 and 4 share the protected write pointer. No other client can use
either queue during the `0x28` and `0x29` sequence.

## Mailbox transaction rules

Each mailbox transaction must use this sequence:

1. Read the current response.
2. Require a known terminal response before a new command.
3. Write zero to the response register.
4. Write the command argument.
5. Apply the required I/O ordering barrier.
6. Write the command register last.
7. Poll the response with a strict timeout.
8. Read the returned argument only after response `0x01`.
9. Stop all mailbox work after a timeout or an unknown response.

Do not retry a failed or unfinished command in the same boot.

Use these response meanings:

| Response | Meaning |
|---:|---|
| `0x01` | Handler success |
| `0xff` | Handler validation or access failure |
| `0xfe` | Unknown message or null handler |
| `0xfd` | Required prerequisite is not available |
| `0xfc` | Asynchronous dispatcher is busy |
| `0x00` | Command is unfinished |

## Phase 1: read-only timing probe

The first PEIM must not contain the PMFW write sequence.

The notification callback will send one command:

```text
queue = 4
command = 0x27
argument = 0x000075a0
```

The required success result is:

```text
response = 0x01
argument = 0x00000201
```

Use this result table:

| Result | Meaning | Action |
|---|---|---|
| `0x01`, argument `0x00000201` | The protected period is open | Record success |
| `0xfd` | The callback is too late | Record a closed gate |
| `0xfc` | The async dispatcher is busy | Stop for this boot |
| `0xfe` | The firmware or dispatch table is not expected | Stop permanently |
| `0xff` | The local read failed | Stop permanently |
| Timeout or other response | PMFW state is not known | Do not send more commands |

The callback must have a one-run guard in PEI memory. A second notification must
return without mailbox access.

## Result reporting

The PEIM will create a GUID HOB. The HOB will contain the probe result.

Use a versioned structure such as:

```c
struct bc250_pei_result {
    uint32_t magic;
    uint16_t version;
    uint16_t stage;
    uint32_t response;
    uint32_t argument;
    uint32_t q4_command;
    uint32_t q4_response;
    uint32_t q4_argument;
    uint32_t flags;
};
```

An X64 EFI application on the ESP will read the HOB list from the UEFI
configuration table. It will write the result to a file on the ESP.

Test HOB availability with OVMF before use on the BC-250. If an EFI application
cannot read the HOB list, use a small DXE HOB reporter. Do not change the main
DXE firmware volume until this fallback is necessary.

## Phase 2: read unlock

Build the write-enabled PEIM only after phase 1 proves that the protected period
is open.

The callback will use this exact sequence:

```text
0x27 argument 0x000075a0
require response 0x01 and argument 0x00000201

0x28 argument 0x000075a0
require response 0x01

0x29 argument 0x00000001
require response 0x01

0x27 argument 0x000075a0
require response 0x01 and argument 0x00000001
```

If message `0x28` succeeds but message `0x29` returns `0xfd`, no dispatch word
was changed. The staged pointer remains at `0x75a0`, but message `0x29` is still
protected. Stop for this boot.

If message `0x29` times out, the write result is not known. Do not send a
readback command. Do not send a rollback command.

## Mandatory integrity reads

After a successful write and readback, use message `0x27` to verify these words:

| Address | Required value |
|---:|---:|
| `0x759c` | `0x00027c94` |
| `0x75a0` | `0x00000001` |
| `0x75a4` | `0x00027cc0` |
| `0x75a8` | `0x00000201` |
| `0x75ac` | `0x00027cd8` |
| `0x75b0` | `0x00000201` |

Stop all SMU use if a value does not match.

The change at `0x75a0` is a data change. It is not an instruction change.
Message `0x29` uses `memw()` before it posts response `0x01`. A code patch would
need separate data-cache and instruction-cache maintenance. This design does
not patch code.

## Runtime Linux policy

Linux must not expose message `0x27` as an arbitrary memory reader.

The driver will permit only fixed, aligned addresses for Cyan Skillfish version
`0x00580600`.

The source-record base is `0xfac4`. Each core record has size `0x178`.

| Value | Address |
|---|---|
| Source-record base pointer | `0x176dc` |
| Core power | `0xfac4 + core * 0x178 + 0x10` |
| Core temperature | `0xfac4 + core * 0x178 + 0x1c` |
| Core frequency | `0xfac4 + core * 0x178 + 0x140` |
| Core C0 ratio | `0xfac4 + core * 0x178 + 0x14c` |

The Linux driver will use these rules:

1. Require PMFW version `0x00580600`.
2. Require all eight cores to be present.
3. Serialize the complete mailbox session.
4. Permit only addresses from the fixed list.
5. Stop after the first unexpected response.
6. Aggregate instantaneous values in the host driver.
7. Do not request table 3 with message `0x22`.
8. Do not use messages `0x28` or `0x29` at runtime.

## Offline ROM insertion

Insert the custom FFS file only into the original PEI PAD region. Reduce the PAD
size by the exact size of the new aligned FFS file.

Do not rebuild or rebase existing PEIMs.

The ROM verifier must enforce these requirements:

1. Input ROM SHA-256 is
   `48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5`.
2. Output size is exactly `0x1000000` bytes.
3. Existing non-PAD FFS offsets do not change.
4. PMFW bytes at `0x8ff000` do not change.
5. PSP and BIOS directory bytes do not change.
6. The main DXE firmware volume does not change.
7. The SEC core stays at `0xffeae8`.
8. The reset vector does not change.
9. Differences are limited to the original PEI PAD range and the state byte of
   the original PEI Apriori FFS file.
10. The new PEIM is IA32 and uses EFI subsystem `11`.
11. The new PEIM has a `TRUE` dependency.
12. The replacement PEI Apriori list keeps all original GUIDs in their original
    order and appends the new file GUID.
13. All firmware-volume and FFS checksums are valid.

Generic firmware-volume tools can move existing files. Reject an output image
if any existing non-PAD file moves.

## Build and test stages

Use this implementation order:

1. Create the EDK2 package and IA32 probe-only PEIM.
2. Create a fake SMN backend for host unit tests.
3. Test all terminal responses and timeout paths.
4. Create the GUID HOB result structure.
5. Create the X64 EFI HOB reporter.
6. Test PEIM notification and HOB reporting with OVMF.
7. Create the byte-preserving ROM insertion tool.
8. Add exact ROM-layout and hash tests.
9. Generate a modified ROM only as an offline artifact.
10. Investigate the RAM-loaded AMI recovery path.
11. Stop before hardware deployment if recovery is not verified.
12. Add the `0x28` and `0x29` sequence only after the timing probe succeeds.

## Hardware deployment gate

Do not flash the probe-only PEIM or the write-enabled PEIM until one of these
conditions is true:

1. An external SPI programmer produces two identical full-chip backups.
2. The external programmer completes a tested erase, write, verify, and restore
   procedure on the correct voltage and chip type.
3. A RAM-loaded recovery firmware volume is proven to dispatch the custom PEIM
   without a change to SPI flash.

The ROM contains recovery components and references file `A2736300.rom`. The
required trigger, image format, and signature policy are not known. Do not treat
this filename as a verified recovery method.

## Stop conditions

Stop the experiment when one of these conditions occurs:

- The ROM hash is not the expected value.
- The live dispatch word is not `0x00000201`.
- A mailbox has an unfinished command.
- A command returns an unknown response.
- A command times out.
- A neighbor integrity word does not match.
- Another queue client can run during the write sequence.
- The HOB result cannot be recovered after boot.
- The ROM tool moves an existing FFS file.
- A safe firmware recovery method is not available for hardware deployment.

## Evidence

Use these files as the primary evidence:

- `CYAN-SKILLFISH-PMFW-PATCH-AND-TABLE3-ALTERNATIVES.md`
- `CYAN-SKILLFISH-METRICS-ANALYSIS.md`
- `SMU-QUEUE3-QUEUE4-TABLE3-REFERENCE.md`
- `verify-cyan-skillfish-firmware.py`
- `probe-cyan-skillfish-metrics.py`
- `core-unlock/bc250-unlock-cores-efi.c`

The external aligned PMFW decompilation artifact is:

```text
smu-3.00-aligned-decompiled.c
```
