# BC-250 Control

Decky Loader interface for the BC-250 SteamOS toolkit.

## Interface

The Quick Access panel provides vertical sections for:

- CU routing and boot replay status
- ACPI and governor health
- GPU frequency, load target, and ramp behavior
- Saved CPU tuning status
- HDMI-CEC controls

GPU voltage editing, CPU tuning changes, and manual WGP routing remain in the toolkit CLI.

## Requirements

- Decky Loader
- Toolkit checkout at `~/.local/share/bc250-fixes/bc250-steamos`
- Installed toolkit components for the controls being used

The plugin backend runs with Decky's `root` flag. CEC commands are delegated to the logged-in Deck user session.

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
