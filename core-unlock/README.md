# BC-250 CPU Core Unlock Integration

This directory is derived from
[`rw-r-r-0644/bc250-core-unlock`](https://github.com/rw-r-r-0644/bc250-core-unlock),
commit [`87ec098`](https://github.com/rw-r-r-0644/bc250-core-unlock/commit/87ec09877df57d2e310a9b9961584a78b6d1c79d).
The original implementation and hardware research are copyright 2026
rw-r-r-0644 and licensed under the MIT license in [`LICENSE`](LICENSE).

## Toolkit Changes

The toolkit version keeps the fixed SMN target and the upstream `0x77` to
`0xff` safety check, with these integration changes:

- Holds an exclusive lock on the PCI configuration file for the complete SMU
  transaction so it cannot race another SMU client.
- Requires the BC-250's `1002:13fe` PCI identity and validates the complete
  `0x00000077` factory mask before issuing the fixed `0x000000ff` write.
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
