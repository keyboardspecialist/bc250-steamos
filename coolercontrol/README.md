# CoolerControl

`install.sh` installs the official CoolerControl daemon AppImage and exposes its
Web UI at <http://localhost:11987>. The release is pinned to 5.0.0 and verified
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
