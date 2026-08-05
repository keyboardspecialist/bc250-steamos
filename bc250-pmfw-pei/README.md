# BC-250 Cyan Skillfish early PMFW probe

This directory contains the first implementation stage from
`bc250-audio-fix/CYAN-SKILLFISH-PEIM-MAILBOX-UNLOCK-PLAN.md`.

The IA32 PEIM registers a synchronous callback for the SMU-services PPI. The
callback sends one queue 4 message `0x27`. It reads PMFW runtime address
`0x75a0`. It records the response and the returned value in a GUID HOB.

PEI dependency expressions do not support `BEFORE`. The PEIM uses a `TRUE`
dependency. A future ROM integration tool must replace the PEI Apriori file
with a larger copy in the PAD region. The replacement must include the probe
file GUID after the original Apriori entries. The tool must mark the original
Apriori file deleted without moving another firmware file.

This stage does not contain messages `0x28` or `0x29`. It cannot change PMFW
memory. It does not contain an FDF file or a ROM insertion tool.

## Native mailbox test

Run:

```bash
./scripts/check-peim-probe-build.sh --host-only
```

## EDK2 build check

Run:

```bash
./scripts/check-peim-probe-build.sh
```

The build check fetches the pinned `edk2-stable202505` source into a temporary
directory. It builds an IA32 PEIM and verifies the PE image type. It does not
create or modify a BC-250 ROM image.

## Hardware status

Do not install this PEIM on hardware. The current test system does not have a
verified external SPI recovery method.
