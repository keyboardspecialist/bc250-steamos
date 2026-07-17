# BC-250 Control

Decky Loader interface for the BC-250 SteamOS toolkit.

## Interface

The Quick Access panel provides a live hardware summary, telemetry graphs, and
CEC quick controls. Select
**Open full controls** for the fullscreen, gamepad-navigable sections:

- CU routing and boot replay status
- Full system, ACPI, governor, and temperature health
- GPU frequency, load target, and ramp behavior
- CPU overclock detection, apply, boot replay, and stock restore controls
- HDMI-CEC controls

GPU voltage editing and manual WGP routing remain in the toolkit CLI.

## Requirements

- Decky Loader
- Toolkit checkout at `~/.local/share/bc250-fixes/bc250-steamos`
- Installed toolkit components for the controls being used

The plugin backend runs with Decky's `_root` flag. CEC commands are delegated to the logged-in Deck user session.

### Privileged operations

Decky starts `main.py` as root because `plugin.json` declares the `_root` flag.
Privileged operations use typed RPC methods, validated arguments, fixed command
paths, and argument allowlists. CEC operations use `runuser` with a clean user
session environment. Toolkit scripts must be regular, non-symlink files owned
by root or the Deck user. CPU tuning uses a separate root-owned helper and
state directory installed under `/var/lib/bc250-control/`.

## Install

```bash
cd decky-plugin
./install.sh
```

The script installs pnpm and Node.js to the update-proof home directory if
missing, builds the plugin, runs the tests, copies the runtime files to
`~/homebrew/plugins/BC-250 Control/`, and restarts Decky. Run it as the deck
user; the copy and restart use sudo. Re-run it after any code change.

## Build

```bash
cd decky-plugin
pnpm install
pnpm run typecheck
pnpm run build
PYTHONPATH=py_modules python3 -m unittest discover -s tests
```

The production bundle is written to `dist/index.js`.

## Backend

`main.py` exposes a typed RPC surface backed by `py_modules/bc250_control/`. Hardware mutations are serialized and validated. Privileged GPU changes use fixed D-Bus and configuration interfaces; only CEC commands invoke a toolkit script, after dropping to the logged-in Deck user.

`tomli` is vendored under `py_modules/` for the Python 3.8 runtime shipped by older SteamOS releases.
