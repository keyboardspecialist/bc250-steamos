# BC-250 Plasma Desktop Control

Native Plasma 6 system-tray controls for the BC-250 SteamOS toolkit. The
desktop package has its own root service and private backend copy. It does not
require Decky Loader or the BC-250 Decky plugin.

## Install

Run from the toolkit checkout as the logged-in desktop user:

```bash
bash desktop-control/install.sh install
```

The installer requests `sudo` for the root-owned service, installs the
plasmoid for the current user, and preserves the integration across SteamOS
atomic updates. Add **BC-250 Control** under **Configure System Tray > Entries**
if Plasma does not display it immediately.

The tray popup includes Overview, GPU, CU, CPU, and CEC controls. Select
**Open Full Controls** to run the same responsive interface through
`plasmawindowed`.

## Commands

```bash
bash desktop-control/install.sh status
bash desktop-control/install.sh uninstall
```

Uninstalling the desktop control leaves Decky and shared toolkit helpers,
state, UMR, GPU tuning, CPU profiles, and CEC configuration intact.

## Runtime Isolation

The service runtime is installed under `/var/lib/bc250-control/desktop` with
private copies of `bc250_control`, `tomli`, and `dbus_next`. The Decky artifact
separately embeds `bc250_control` under its own `py_modules` directory. Neither
UI package imports from or invokes the other.

Both backends follow the same lock protocol at
`/run/lock/bc250-control/backend.lock` so independently installed versions do
not mutate hardware concurrently.

See `plasmoid/README.md` for the QML layout and D-Bus API details.
