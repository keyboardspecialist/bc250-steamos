# BC-250 CPU Core Unlock Integration

The Linux helper in this directory is derived from
[`rw-r-r-0644/bc250-core-unlock`](https://github.com/rw-r-r-0644/bc250-core-unlock),
commit [`87ec098`](https://github.com/rw-r-r-0644/bc250-core-unlock/commit/87ec09877df57d2e310a9b9961584a78b6d1c79d).
The original implementation and hardware research are copyright 2026
rw-r-r-0644 and licensed under the MIT license in [`LICENSE`](LICENSE).

## Toolkit Changes

The toolkit version keeps the fixed SMN target and writes the full `0xff` mask,
with these integration changes:

- Holds an exclusive lock on the PCI configuration file for the complete SMU
  transaction so it cannot race another SMU client.
- Requires the BC-250's `1002:13fe` PCI identity, skips an already-complete
  `0x000000ff` mask, and verifies the full mask after issuing the fixed write.
- Aborts if the queue is still busy after the initial timeout instead of
  issuing a command into a busy mailbox.
- Adds one-time apply, boot replay, status, and read-only persistence-gating
  modes plus physical-core topology checks.
- Serializes boot/manual operations and writes a persistent pending marker
  before touching the SMU. This permits at most one automatic attempt and warm
  reboot after a cold boot, preventing failed writes or unlocks from looping.
- Installs through `bc250-power.sh` into root-owned persistent storage and runs
  before CPU overclocking and the GPU governor.

`cpu-unlock test` performs only the one-time volatile write. It does not create
or enable the boot service. After a manual reboot and stability testing,
`cpu-unlock enable` refuses to install persistence unless the current boot
already exposes exactly eight physical cores.
If testing exposes instability, a full power-off restores the factory mask;
the one-time test leaves no boot service that can reapply it.

AGESA consumes the core mask before Linux starts, so initramfs is already too
late. After a full power-off resets the mask, the boot service writes it and
requests one warm reboot. AGESA then sees `0xff` and enumerates all eight cores.

## Experimental EFI Mode

`bc250-unlock-cores-efi.c` is adapted and hardened from
[`Hexxeh/bc250-efi-core-unlock`](https://github.com/Hexxeh/bc250-efi-core-unlock)
commit [`3e45131`](https://github.com/Hexxeh/bc250-efi-core-unlock/commit/3e45131678b111c50e5c285834869ecd3c487a2e),
copyright Liam McLoughlin and licensed under the MIT notice in
[`EFI-LICENSE`](EFI-LICENSE). It builds against headers fetched only from
[`yoppeh/efi`](https://github.com/yoppeh/efi) commit
[`761b114`](https://github.com/yoppeh/efi/commit/761b114e3b186adb82516d5fa8e7a4c559f56ba5),
copyright Warren Mann and licensed under
[`EFI-HEADERS-LICENSE`](EFI-HEADERS-LICENSE). The toolkit ships no fetched header
or EFI binary.

The hardened application adds the following protections:

- Verifies the complete PCI configuration ID `0x13fe1002` before any SMN/SMU
  access, skips an already-complete `0x000000ff` mask, and verifies the result.
- Retains the proven queue 3 message `0x98` and SMN address `0x0115A870`, with
  bounded mailbox waits and high-bit-encoded EFI error returns.
- Persists a one-attempt UEFI guard before the SMU write. Any locked mask with
  an existing guard refuses another reset; a verified `0xff` mask clears the guard
  and returns high-bit `EFI_ABORTED` so firmware continues to the next
  `BootOrder` entry without entering the interactive-success exception path.
- Uses the toolkit-specific UEFI vendor GUID
  `4f6f6f13-1ec2-4f26-a250-bc250c0e77ff` and variable name
  `BC250CoreUnlockAttempt`.

`cpu-unlock efi-enable` requires exactly eight active physical cores and Secure
Boot disabled or unsupported by the firmware. It compiles the local source with
clang/lld, verifies an x86-64 PE EFI application, and stores a master image and
ownership state under `/var/lib/bc250-control/core-unlock`. It installs the
namespaced loader at `/efi/EFI/bc250/bc250-core-unlock.efi`, then creates and
verifies its recorded `Boot####` entry. The mounted path must be a writable FAT
filesystem on a standard GPT ESP or the active SteamOS EFI slot; its canonical
source, parent disk, partition number, and PARTUUID are recorded. Completeness
additionally requires an active entry first in `BootOrder`. Rollback and removal
delete only an entry whose exact label, loader, partition number, and PARTUUID
match; uncertainty retains the loader and ownership/recovery state for manual
review.

EFI mode eliminates the extra Linux boot used to replay the mask, but firmware
still performs one warm reset after each cold power-on. It is unsigned,
incompatible with Secure Boot, and experimental. Linux/systemd replay remains
the safest recommended default.
