# CoolerControl

`install.sh` installs the official CoolerControl daemon AppImage and exposes its
Web UI at <http://localhost:11987>. The release is pinned to 5.1.1 and verified
with its published GitLab package SHA-256 before installation.

The daemon, configuration, plugins, and profiles are stored under
`/var/lib/bc250-control/coolercontrol`, backed by the toolkit's persistent
SteamOS storage. The NCT6687 driver must be installed first.

```bash
bash coolercontrol/install.sh install
bash coolercontrol/install.sh status
bash coolercontrol/install.sh uninstall
```

Uninstall removes the daemon and desktop launcher but preserves saved profiles.

## Upgrading from 5.0.0

Run `install` again. The installer accepts only the verified toolkit-managed
5.0.0 or 5.1.1 payload; legacy 5.0.0 removal remains supported. Before replacing
an older daemon (or reusing saved settings), it stops the service and snapshots
the complete `config` and `data` directories under
`/var/lib/bc250-control/coolercontrol/backups/pre-5.1.1.*`. Backups are private
to root and retained on uninstall. A `.complete` file identifies finished
snapshots. User configuration is never replaced with release defaults: the
daemon handles custom settings, sensor sources, device UID and UI-label
migrations on startup. Check fan profiles and sensor assignments in the Web UI
after upgrading. Downgrading can orphan migrated device settings; restore a
complete pre-upgrade snapshot with the service stopped if rolling back.

In 5.1, REST **and gRPC** use port **11987** with the same authentication.
The old unauthenticated gRPC listener on **11988 is removed**. Update remote
clients and plugins; no firewall opening or authentication bypass is installed.
The existing persistent service paths, notify/watchdog behavior and ownership
checks are preserved. Custom bind addresses and credentials are left untouched.

Verified 5.1.1 AppImage SHA-256:
`89d35570b098c885673afda56d3f38f830286b42f61051e0194e864d21495130`.
