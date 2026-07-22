# BC-250 Plasma Desktop Control

Plasma 6 system-tray and windowed hardware controls for the BC-250 SteamOS toolkit.

## Capabilities

| Area | Controls and status |
| --- | --- |
| Overview | CPU and GPU clocks, temperature history, CU availability, service health, and boot persistence |
| GPU | Adaptive frequency ranges, pinned clocks, load targets, voltage curves, and ramp timing |
| Compute units | Shader-row and WGP routing, factory-route indicators, live application, and saved masks |
| CPU | Active profile, bounded stability detection, immediate application, boot enablement, and stock settings |
| CEC | TV and receiver power, active source, volume, behavior toggles, and broadcast name |

## Requirements

| Requirement | Purpose |
| --- | --- |
| Plasma 6.4 or later | System-tray and `plasmawindowed` interface |
| systemd | Privileged service and repair integration |
| D-Bus and polkit | Service transport and authorization |
| BC-250 toolkit checkout | Installer, backend, service, and persistent-storage helpers |

## Install

Run as the logged-in desktop user:

```bash
bash desktop-control/install.sh install
```

The installer configures:

| Component | Location |
| --- | --- |
| Plasma applet | Current user's Plasma package directory |
| Service runtime | `/var/lib/bc250-control/desktop` |
| systemd services | `bc250-control.service`, `bc250-desktop-control-repair.service` |
| D-Bus policy | `/etc/dbus-1/system.d/io.github.keyboardspecialist.BC250Control1.conf` |
| polkit policy | `/usr/share/polkit-1/actions/io.github.keyboardspecialist.bc250-control.policy` |
| Atomic-update keep list | `/etc/atomic-update.conf.d/bc250-desktop.conf` |

System-tray entry: **System Tray Settings > Entries > BC-250 Control**.

## Interface

| Mode | Launch |
| --- | --- |
| System-tray popup | Select the BC-250 tray icon |
| Full window | Select **Open Full Controls** |
| Command line | `/usr/bin/plasmawindowed io.github.keyboardspecialist.bc250control` |

The compact icon uses a Plasma-themed hardware glyph and a health-status dot.
The popup uses top navigation. The full-window layout uses sidebar navigation.

## UI Reference

### Overview

![BC-250 overview popup and system-tray health icon](mockups/01-overview-tray.png)

### GPU

![BC-250 GPU frequency, load response, and ramp controls](mockups/02-gpu-controls.png)

### Compute Units and CPU

![BC-250 compute-unit routing and CPU profile controls](mockups/03-cu-cpu.png)

### CEC

![BC-250 CEC television and receiver controls](mockups/04-cec-controls.png)

Mockups use representative values from the bundled mock backend. Runtime colors
and control styling follow the active Plasma theme.

## Lifecycle

| Command | Action |
| --- | --- |
| `bash desktop-control/install.sh install` | Install or upgrade the applet and service |
| `bash desktop-control/install.sh status` | Report applet, service, D-Bus, polkit, storage, and persistence state |
| `bash desktop-control/install.sh uninstall` | Remove the applet and desktop service integration |
| `./bc250-maintenance.sh uninstall desktop` | Remove the desktop component through the toolkit lifecycle interface |
| `./bc250-maintenance.sh uninstall all` | Remove all toolkit components in dependency-safe order |

Desktop-component removal preserves shared hardware helpers, UMR, GPU tuning,
CPU profiles, CEC preferences, and persistent toolkit data.

## Architecture

| Layer | Implementation |
| --- | --- |
| Applet | Pure QML Plasma package, ID `io.github.keyboardspecialist.bc250control` |
| Service | Root-owned Python service, `io.github.keyboardspecialist.BC250Control1` |
| Backend | Private `bc250_control` runtime with vendored `tomli` and `dbus_next` |
| Hardware serialization | `/run/lock/bc250-control/backend.lock` |
| Persistent payload | `/var/lib/bc250-control/desktop` |
| Recovery | `bc250-desktop-control-repair.service` |
| Update retention | SteamOS atomic-update component keep list |

## Authorization

| Operation | Authorization path |
| --- | --- |
| Status and telemetry | Read methods on the system D-Bus service |
| GPU, CU, and CPU changes | Polkit-authorized service methods |
| CEC actions | Validated service methods |
| CEC broadcast name | Printable UTF-8 input with a 14-byte limit |

Service methods apply argument allowlists, integer bounds, operation-ID
validation, and serialized hardware mutation.

## Polling

| State | Interval |
| --- | --- |
| Visible interface | Snapshot every 10 seconds |
| Collapsed interface | Snapshot every 60 seconds |
| Visible Overview tab | Telemetry every second |
| Active mutation | Polling pause followed by immediate completion refresh |

## Development

QML package, test-fixture, and D-Bus API reference:
[`plasmoid/README.md`](plasmoid/README.md).
