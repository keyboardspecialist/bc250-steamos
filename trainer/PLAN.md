# BC250 Trainer Plan

## Goals

Build a classic trainer/keygen-style desktop frontend for the BC-250 toolkit.
The application will use the supplied artwork as a frameless window background,
play a bundled or user-selected music directory, and
expose the core hardware controls through the existing privileged service
boundary.

Version one will include:

- Dashboard and live telemetry
- Live compute-unit routing
- CPU core-unlock status and actions
- GPU frequency, load-target, and ramp controls
- CPU overclock detection, application, and boot enablement
- Collapsible music library, waveform, transport, volume, and mute controls

CEC, drivers, mesh shaders, and maintenance operations are deferred,
but the application structure should allow those pages to be added later.

## Application Architecture

Create a native Qt 6 application under `trainer/` using:

- Qt Quick and QML for the interface
- Qt Quick Controls 2 for input controls
- QtDBus for communication with the privileged service
- QtMultimedia for soundtrack playback
- CMake for builds

Build in an Ubuntu 24.04 distrobox against an older Qt 6 baseline. The SteamOS
host has the necessary Qt runtime, but its development headers are currently
stripped. Building against an older Qt 6 release also gives the resulting
binary a suitable compatibility baseline for the newer SteamOS Qt runtime.

Produce one `bc250-trainer` executable. Embed the QML and background image as
Qt resources with stable aliases, and package the default MP3 library beside
the executable under `tracks/`:

```text
qrc:/qml/Main.qml
qrc:/assets/background.png
```

The application remains unprivileged. Live hardware controls use the typed
system D-Bus service. Native toolkit management uses a dedicated C++ PTY
controller with a fixed operation allowlist; QML must never construct script
paths, arguments, shell fragments, `sudo`, or `busctl` calls. Flatpak remains a
D-Bus-only client without host command access.

## Proposed Layout

```text
trainer/
|-- CMakeLists.txt
|-- README.md
|-- ASSETS.md
|-- install.sh
|-- resources.qrc
|-- src/
|   |-- main.cpp
|   |-- Bc250Bridge.h
|   `-- Bc250Bridge.cpp
|-- qml/
|   |-- Main.qml
|   |-- components/
|   `-- pages/
|-- packaging/
|   |-- io.github.keyboardspecialist.bc250trainer.desktop.in
|   `-- io.github.keyboardspecialist.bc250trainer.svg
|-- tests/
|-- ChatGPT Image Jul 29, 2026, 08_44_21 PM.png
`-- tracks/
```

## Window And Visual Design

- Use a frameless rectangular Qt Quick window.
- Preserve the background image's aspect ratio.
- Default to approximately `1200x676` and reduce the size when necessary to fit
  the available screen.
- Do not expose normal resize handles in version one.
- Use `startSystemMove()` from noninteractive background regions so dragging
  works correctly under Wayland.
- Provide custom minimize, close, and refresh controls.
- Keep the primary hardware controls in the darker right side of the image and
  reserve the lower-left artwork for a collapsible translucent media deck.
- Use cyan and magenta neon borders, restrained glow, scanlines, fixed-pitch
  typography, compact status lights, and a scrolling status ticker.
- Use the system fixed-pitch font initially rather than adding an unverified
  third-party font dependency.
- Include keyboard shortcuts: `F1` through `F4` for primary pages, `M` for
  mute, `P` for play/pause, `R` for refresh, and `Escape` for close.

## Soundtrack

Use a dedicated native QtMultimedia controller:

- Start playback when the application opens.
- Scan a selected directory non-recursively for supported audio files.
- Advance and wrap through the naturally sorted track list.
- Default to the packaged `tracks/` directory and show an empty state when a
  selected directory has no playable files.
- Provide transport, track list, synchronized waveform, dedicated beat-energy
  visualizer, mute, and volume controls in the lower-left media deck.
- Persist volume and mute state with `QSettings`.
- Persist the selected directory and current track.
- Display a nonfatal status message if audio playback fails.

Direct XM/MOD playback is deferred. The installed multimedia stack supports
Vorbis, but no tracker-module decoder is currently available.

## Pages

### Status

- GPU and CPU clocks
- GPU and CPU temperatures
- Active physical cores and logical threads
- Active and maximum compute units
- Governor, replay, and service health
- Current operation and reboot or power-cycle notices

### GPU

- Adaptive frequency mode
- Minimum and maximum frequency range
- Pinned frequency mode
- Maximum frequency mode
- Eager, reset, and custom load targets
- Ramp timing
- Read-only voltage-curve display

GPU voltage mutation is not part of the existing service API and is deferred
until it can receive equivalent validation and rollback coverage.

### Compute Units

- Factory WGP map
- Live WGP routing state
- Active CU total
- Saved-mask and boot-replay indicators
- Per-WGP live enablement for supported harvested routes
- Confirmation before every live hardware change

### CPU

- Physical core and logical-thread topology
- CCX grouping where the kernel exposes it
- Core-unlock helper, service, guard, and replay state
- One-time core-unlock test
- Persistent replay enablement after successful testing
- Replay disablement
- CPU overclock detect, apply, enable, and off actions
- Active CPU overclock profile and service state

### Setup

- Manual refresh
- Service availability and version
- Toolkit path and capability diagnostics
- Advanced-control warning state

## Native D-Bus Bridge

Implement `Bc250Bridge` in C++ with:

- `QDBusConnection::systemBus()`
- `QDBusInterface`
- Asynchronous D-Bus calls and `QDBusPendingCallWatcher`
- `QDBusServiceWatcher` for service appearance and disappearance
- `QJsonDocument` parsing into QML-friendly maps
- Coalesced snapshot and telemetry requests
- Operation polling and ownership-safe cancellation
- Sanitized plain-text service errors

Connect to:

```text
Service:   io.github.keyboardspecialist.BC250Control1
Path:      /io/github/keyboardspecialist/BC250Control1
Interface: io.github.keyboardspecialist.BC250Control1
```

Retain the established polling behavior:

- Snapshot every 10 seconds while visible
- Telemetry every second on the status page
- Immediate refresh after an operation completes
- Pause normal polling during a mutation
- Poll operation state approximately every 750 milliseconds

The bridge should expose service availability, snapshot, telemetry, CPU-unlock
status, operation state, busy state, notices, and errors as QML properties.
Mutation entry points must apply the same bounds as the service for immediate
feedback, while the privileged service remains authoritative.

## CPU Core-Unlock Service Extension

Add these methods to the existing desktop system service:

```text
GetCpuUnlockStatus() -> JSON string
CpuUnlockAction(action string) -> operation ID
```

`CpuUnlockAction` must accept only:

- `test`
- `enable`
- `efi-enable`
- `off`

Do not expose arbitrary command arguments, raw SMU operations, internal helper
modes, or uninstall through this method.

Structured status should include:

- Schema version
- BC-250 device detection
- Physical core and logical-thread counts
- Locked, unlocked, unexpected, or unavailable topology state
- CCX/core grouping derived directly from sysfs
- Helper and unit installation state
- Current mutually exclusive mode (`none`, `temporary`, `linux-replay`, `efi`,
  `conflict`, or `partial`)
- Linux replay service active and enabled state
- EFI image and firmware boot-entry state
- Update-persistence state
- Manual or automatic reboot-guard state
- Advisory action availability and blocker codes
- Warm-reboot and full-power-off semantics

Collect structured topology and guard state directly in Python. Do not parse
human-readable output from `bc250-power.sh status` or `topology.sh`.

Run mutations through a trusted root-owned helper bundle in the transactional
service payload. Include and validate:

```text
bc250-power.sh
bc250-storage.sh
bc250-update-persistence.sh
core-unlock/bc250-unlock-cores.py
core-unlock/LICENSE
```

Invoke only the fixed command form:

```text
/usr/bin/bash <trusted-payload>/bc250-power.sh cpu-unlock <allowed-action>
```

Use the existing `cpu` polkit authorization category and the shared backend
hardware lock. Validate every helper and ancestor as root-owned, nonsymlinked,
and not group- or world-writable before execution.

Core-unlock operations must be non-cancellable during the critical operation.
Extend operation JSON with a `cancellable` field and make cancellation return
false for protected operations.

Operation completion should identify the required next step:

| Result | Next step |
| --- | --- |
| Successful six-core test | Warm reboot |
| Test while already at eight cores | None |
| Persistent replay enabled | None immediately |
| Replay disabled while eight cores remain active | Full power-off |
| Replay disabled while already at six cores | None |

## Safety Requirements

- Require explicit confirmation before CU writes, pinned clocks, CPU detection,
  and CPU core-unlock operations.
- Explain that harvested CUs and disabled CPU cores may be physically defective.
- Explain that CPU overclock detection can crash or restart the machine.
- Explain that a core-unlock test changes the mask immediately but requires a
  warm reboot before Linux can enumerate the additional cores.
- Do not offer persistent replay until exactly eight physical cores are active.
- Explain that disabling replay does not relock the current boot and requires a
  complete power-off to return to six cores.
- Show when an automatic guarded reboot is pending and block conflicting work.
- Disable controls according to service-provided capability flags and blockers.
- Keep all existing script-level checks as the final authority to avoid
  time-of-check/time-of-use safety gaps.

## Standalone Installation

The Trainer package must work without installing the Plasma applet.

Install user-owned application files under:

```text
~/.local/libexec/bc250-trainer/bc250-trainer
~/.local/share/applications/io.github.keyboardspecialist.bc250trainer.desktop
~/.local/share/icons/hicolor/scalable/apps/io.github.keyboardspecialist.bc250trainer.svg
```

The desktop launcher should use:

```ini
Type=Application
Name=BC250 Trainer
Icon=io.github.keyboardspecialist.bc250trainer
Categories=Utility;System;
Terminal=false
DBusActivatable=false
```

Factor the existing privileged service installation so both Plasma and the
Trainer can install or update the same root service payload. Track frontend
clients with root-owned registration markers so uninstalling one frontend does
not remove a service still required by the other.

The Trainer installer should support:

- `install`
- `status`
- `uninstall`

Application uninstall should remove only Trainer-owned user files and release
its service-client registration. Shared tuning state, helpers, profiles, and a
service still used by another frontend must be preserved.

## Build Environment

Create or use an Ubuntu 24.04 distrobox containing:

- CMake
- Ninja or Make
- GCC/G++
- Qt 6 base development files
- Qt 6 declarative development files
- Qt 6 multimedia development files
- Qt 6 tools and test modules

Add a repository build helper that enters or creates the named distrobox and
performs an out-of-tree release build. It must detect missing tools and provide
a clear setup command rather than modifying the SteamOS root automatically.

Verify the resulting dynamically linked binary against the host with `ldd` and
an offscreen startup test before installation.

## Testing

### Service And Backend

- Six-core, eight-core, unexpected, and unavailable topology
- Logical-thread grouping and missing CCX metadata
- Manual and automatic guard states
- Malformed, oversized, symlinked, or writable state files
- Trusted helper-bundle validation
- Exact subprocess argument and environment construction
- Rejection of every unsupported action before authorization or execution
- Core-unlock result and next-step semantics
- Non-cancellable operation behavior
- D-Bus signatures, sender propagation, and operation ownership

### Native Application

- JSON parsing and error propagation with QtTest
- Fixed toolkit action allowlist and exact launcher arguments
- PTY output streaming, UTF-8 decoding, ANSI filtering, and bounded retention
- Secure sudo-prompt detection and process-group cancellation
- Toolkit dashboard state, action interlocks, and console behavior
- Service appearance and disappearance
- Poll coalescing and operation completion
- Argument bounds and operation-ID validation
- QML lint
- Offscreen QML component tests
- Mock-service mode for development without hardware writes
- Offscreen executable startup

### Manual SteamOS Verification

- Borderless rendering under Wayland
- Correct compositor-managed window dragging
- Scaling on 1280x800 and larger displays
- Keyboard shortcuts and focus behavior
- Bundled and external directory playback, navigation, waveform, visualizer,
  volume persistence, and unmuted startup
- Polkit prompts associated with the application D-Bus sender
- Read-only status before any hardware mutation
- Conservative GPU control verification
- CU and CPU core-unlock verification only with explicit hardware-test approval

## Release Integration

Add a deterministic release staging script and test for a new artifact:

```text
bc250-trainer-<tag>.zip
bc250-trainer-<tag>.zip.sha256
```

Extend the tag-triggered release workflow to:

- Install Qt 6 build dependencies
- Configure and build the release executable
- Run C++ and QML tests
- Run an offscreen startup smoke test
- Stage the standalone application and shared service resources
- Generate a deterministic ZIP and SHA-256 file
- Upload both to the GitHub release

Include `trainer/` in the full toolkit archive if the source project should be
distributed there as well.

Document asset provenance and redistribution status in `ASSETS.md`, including
the generated artwork, soundtrack, and AMD branding, before publishing the
assets in a release.

## Implementation Order

1. Add the distrobox build scaffold and minimal native Qt window.
2. Embed and render the background image at the fixed aspect ratio.
3. Add OGA playback, custom window controls, shortcuts, and settings.
4. Implement mock data and the complete visual page structure.
5. Implement the native QtDBus bridge for the existing service API.
6. Add structured CPU core-unlock status to the backend and service.
7. Add protected CPU core-unlock operations and operation semantics.
8. Wire the CPU-unlock page to the new service API.
9. Factor shared service installation and add the standalone Trainer installer.
10. Add automated tests, CI build, deterministic packaging, and documentation.
11. Perform read-only and conservative hardware verification before testing
    irreversible or crash-prone controls.
