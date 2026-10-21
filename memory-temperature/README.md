# BC-250 memory-temperature integration

This directory contains the toolkit's guarded launcher for
[`pan-Rijovich/bc250-memory-temperature`](https://github.com/pan-Rijovich/bc250-memory-temperature).
The launcher is original toolkit integration code. Upstream source and its MIT
license are downloaded from the pinned commit by `bc250-memory-temperature.sh`.

The live SMU payload remains experimental and specific to the ASRock BC-250 P3.0
firmware layout. See the main README before using it.

## Reviewed payload and migration (2026-10-21)

The staged source now tracks commit
[`4a2221d1da387fa2e738bb9368b39594e242ba4b`](https://github.com/pan-Rijovich/bc250-memory-temperature/commit/4a2221d1da387fa2e738bb9368b39594e242ba4b),
four commits after the previous `b7e6bffcb5d592fc03edde375b7598ddc79aa846`.
The upstream transport, unlock implementation, linker layout, and license did
not change. This update adopts the bounded UMC polls, input checks, symbol-driven
handlers, and packed temperature reads, **not** upstream's force-overwrite mode.
It adds no automatic service or firmware flashing.

- Both the 764-byte binary and GNU `nm` symbol manifest are SHA-256 pinned.
  Handler symbols must be text entirely within the binary and reserved SRAM
  `0x3aa9c..0x3e000`; only handler words for Queue 3 messages 5, 6, and 7 are
  changed, never their neighboring flags.
- The manifest also covers 144 bytes of mutable `.bss`, including register dumps
  and polling counters, through `0x3ae28`. The complete **908-byte runtime
  footprint** is backed up and initialized, but live attestation compares only
  immutable binary bytes: normal polling must not invalidate the payload.
- Root and both exact PCI identity guards, explicit risk acknowledgement,
  governor pause/resume, operation lock, and PCI transaction lock are retained.
  The SMU version must additionally be `0.58.6.0` before unlock or payload access.
- New schema-2 backups contain all three original handler words plus the full
  overwritten runtime area, stored atomically and fsynced before the first
  payload write. Installation, rollback, and restore verify readbacks. Restore
  detaches and verifies handler pointers **before** overwriting executable code.
- A legacy schema-1 backup is still accepted **only for restore**, with the
  original commit, exact 176-byte extent, payload checksum, and original handler
  validated. It is never overwritten or silently promoted into a larger backup.
  Legacy live reads remain supported after exact 176-byte hash attestation.

If an old backup exists, run `restore --acknowledge-smu-risk` first, then
`prepare` and (only if wanted) `patch --acknowledge-smu-risk`. A fully verified
old stage remains usable for **restore only**, offline, with the new guarded
launcher and unchanged transport. If `prepare` was already run, the new stage
can also restore the old backup. Neither route needs the old binary to be
rebuilt, nor is a new download required when a verified stage is available.
After a cold power cycle, restore clears the old backup only after confirming the
recorded original handler and bytes. An active old/foreign payload without its
backup is refused; cold-power-cycle rather than forcing an overwrite. Keep the
state directory until restore succeeds. Staging preserves old source directories.

Packed message 6 returns UMCs 0/2/4/6 for parity 0 and 1/3/5/7 for parity 1.
Results retain sorted chip IDs and the existing JSON aggregate keys; `raw` is
the packed response word on new payloads (MR3 on legacy payloads). Timeout bytes
`0xff`/`0xfe`, malformed responses, or out-of-range temperature codes fail the
whole sample rather than emitting misleading averages. The message-7 diagnostic
handler is installed and restored, but this launcher does not clear/read dumps
automatically. Firmware polling bounds do not eliminate SMU crash or corruption
risk; no hardware validation or live firmware writes were performed for this
dependency review.
