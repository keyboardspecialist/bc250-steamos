# BC250 Trainer

Native Qt 6 frontend for the BC-250 control service and toolkit. It renders the supplied retro artwork as a fixed-aspect frameless window, includes a native music library with six bundled MP3 tracks, and uses the system D-Bus service for live hardware controls.

The native build can also launch a fixed allowlist of install, build, repair, and removal actions from an existing toolkit checkout. A native PTY streams bounded plain-text output into the application and handles `sudo` authentication without logging password input. QML cannot supply executable paths, arguments, or shell fragments. Live hardware checks and authorization remain in `io.github.keyboardspecialist.BC250Control1`.

The Flatpak packages only this unprivileged frontend. Release installation kits
pair it with a host-side installer for the required BC-250 control service. The
Flatpak cannot launch host toolkit actions and reports that dashboard capability
as unavailable.

## Install

From a toolkit checkout or toolkit release artifact, download, verify, and
install the newest native Trainer release with:

```sh
./bc250-toolkit.sh trainer
```

The bootstrap supports `GH_TOKEN` or `GITHUB_TOKEN` for authenticated GitHub API
requests. To choose the Flatpak package or install a downloaded native artifact
manually, use the release instructions below.

Download one of the ZIP files from
[BC250 Trainer Releases](https://github.com/keyboardspecialist/bc250-steamos/releases?q=trainer-v&expanded=true).
Run these commands as your normal desktop user, not with `sudo`; the installer
requests administrator access only for the host service.

### Flatpak

```sh
unzip bc250-trainer-vX.Y.Z-flatpak-installer.zip
cd bc250-trainer-flatpak-installer
bash trainer/install-flatpak.sh install
```

Manage the installation from the same extracted directory:

```sh
bash trainer/install-flatpak.sh status
bash trainer/install-flatpak.sh uninstall
```

### Native Linux

```sh
unzip bc250-trainer-vX.Y.Z.zip
cd bc250-trainer
bash trainer/install.sh install
```

The native package uses `bash trainer/install.sh status` and
`bash trainer/install.sh uninstall` for management.

The Toolkit dashboard expects the full checkout at
`~/.local/share/bc250-fixes/bc250-steamos`. Set `BC250_TOOLKIT_DIR` when using a
different development checkout. The standalone Trainer archive intentionally
does not bundle or update the complete toolkit source tree.

## Features

- Status dashboard with one-second telemetry while the page is active, all available hwmon sensors, and explicit eight-core metrics compatibility status
- Native Toolkit task dashboard for component inventory, setup, driver builds, repairs, and per-component removal
- Automatic main-toolkit release checks with a checksum-verified, atomic in-app update and Trainer restart, backed by the same updater as the primary CLI
- Global DirectMesh setup and verified retired R2 cleanup; ordinary Proton replaces the retired private runner
- Native fixed CLI catalog for complete toolkit maintenance coverage (swap, storage, persistence, wireless backend, memory temperature, RADV, video codec, Proton, and more); the service opens the host user's terminal, never a root shell
- Service-discovered Steam game manager for FSR4, experimental HelixSR, and OptiScaler, including update/repair and verified rollback workflows; launch options remain manual
- HDMI CEC device status, television/receiver/source/volume controls, broadcast name, and automatic integration settings
- Live bounded console output with secure `sudo` prompting and protected process cancellation
- Adaptive, ranged, pinned, and maximum GPU clock modes
- GPU load target, thermal target, ramp/reset, and inline voltage-curve set/add/edit/remove/offset/reset with explicit risk confirmation
- RAM/VRAM split controls for CMOS UMA minimums and dynamic TTM limits
- Live WGP routing with an advanced interlock and per-write confirmation
- Mutually exclusive CPU core-unlock controls for the standard Linux boot method and the experimental EFI pre-boot alternative
- CPU overclock detection, apply, boot replay, stock, and helper update actions
- Explicit eight-core compatible metrics helper enable/uninstall actions, using service-reported blockers; telemetry sampling never installs or injects an SMU payload
- Asynchronous QtDBus operation tracking, protected-operation cancellation state, and service lifetime monitoring
- Collapsible music library with transport, natural track ordering, and folder watching
- Synchronized whole-track waveform and dedicated beat-energy visualizer
- Persisted music directory, current track, and volume via `QSettings`; mute is session-only
- `--mock` development mode that never contacts hardware

The installed service must include `GetCpuUnlockStatus()` and `CpuUnlockAction(string)` for core-unlock controls. The action allowlist is `test`, `enable`, `efi-enable`, `off`, `metrics-enable`, and `uninstall`; action availability and blockers come from the status response. Uninstall removes the entire managed core-unlock/metrics integration, not only the metrics service. Older services remain usable for their existing features; schema-v1 `linuxReplay` status remains supported. Missing extensions are shown as unavailable, never replaced with CLI hardware-control fallbacks or estimated metrics.

## Build

Ubuntu 24.04 is the compatibility baseline (Qt 6.4 or newer):

```sh
./build-distrobox.sh
```

The helper creates `bc250-trainer-ubuntu2404` when needed, but does not install packages automatically. If dependencies are missing, it prints the exact `apt` command to run inside the container. Output is written to `build-ubuntu2404/`.

For an already prepared environment:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

On macOS, install the required formulae and run the internal manual build and
verification harness:

```sh
brew install cmake ninja qt bash coreutils
./build-macos.sh
```

The script reports one `brew install` command when dependencies are missing and
never installs them automatically. Use `./build-macos.sh run` for an interactive
mock-mode launch after a successful build.

Set the application version at configure time when preparing a release:

```sh
cmake -S . -B build -G Ninja -DTRAINER_PROJECT_VERSION=1.0.0
```

Available convenience targets depend on installed tools:

```sh
cmake --build build --target qml-lint
cmake --build build --target qml-tests
cmake --build build --target smoke
```

### Flatpak

Build and install a local GUI-only Flatpak with the KDE 6.11 SDK and runtime from
Flathub:

```sh
flatpak remote-add --user --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
TRAINER_PROJECT_VERSION=1.0.0 \
  flatpak-builder --user --install-deps-from=flathub --force-clean --install \
  flatpak-build packaging/io.github.keyboardspecialist.bc250trainer.yml
flatpak run io.github.keyboardspecialist.bc250trainer
```

The sandbox can open Wayland or X11 windows, use GPU acceleration and audio,
and talk only to the BC-250 system D-Bus service. It has no general host
filesystem or host-command access. Folder selection is handled through the
desktop portal. Toolkit dashboard actions and CLI terminal handoff are therefore native-only. The bridge explicitly refuses handoff in Flatpak even if the host service advertises it; no `flatpak-spawn` or host-filesystem permission is added. D-Bus-backed game and CEC workflows remain available when supported by the host service.

Release users should use the complete `*-flatpak-installer.zip` artifact instead
of installing the raw bundle. After extracting it:

```sh
bash trainer/install-flatpak.sh install
```

That host-side script installs persistent storage and the privileged service,
then installs the bundled Flatpak for the current user. Its `status` and
`uninstall` commands manage both halves as one installation.

## Development

Run without service access or hardware writes:

```sh
./build/bc250-trainer --mock
```

Run the executable startup check:

```sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_MEDIA_BACKEND=mock \
  ./build/bc250-trainer --mock --smoke-test
```

Controls are `F1` Toolkit, `F2` Status, `F3` GPU, `F4` Compute Units, `F5` CPU,
`F6` Memory, `M` mute, `P` play/pause, `R` refresh, and `Escape` close. Drag the
noninteractive upper-left artwork to request a compositor-managed system move
under Wayland.

STATUS has Metrics/Audio and HDMI CEC subpages. GPU has Tuning and FSR4/HelixSR/OptiScaler subpages. The complete native CLI catalog is expandable from TOOLKIT. Artwork, six top-level tabs, and shortcuts are unchanged.

The media deck defaults to the bundled `tracks/` directory and scans only the
selected folder. It accepts OGA, OGG, Opus, MP3, FLAC, WAV, M4A, and AAC files.
An empty folder remains empty. Codec support is platform-dependent; playback,
waveform, and visualizer analysis failures do not disable hardware controls.

## Releases

BC250 Trainer releases use the independent `trainer-vMAJOR.MINOR.PATCH` tag
namespace and are published as GitHub prereleases. Main toolkit releases retain
the `vMAJOR.MINOR.PATCH` namespace. They include the native release bootstrap
and maintenance lifecycle scripts, but do not build, bundle, or publish Trainer
applications.

Cut a release from `master` with an annotated Trainer tag:

```sh
git switch master
git pull --ff-only
git tag -a trainer-v1.0.0 -m "BC250 Trainer v1.0.0"
git push origin trainer-v1.0.0
```

The **Build BC250 Trainer prerelease** workflow validates master ancestry, builds
and tests the native application and shared service, stages the standalone ZIP
and complete Flatpak installation kit, and publishes checksums with the prerelease.

The workflow enforces the publishing decision recorded in `ASSETS.md` before
building or publishing a release.

## D-Bus Contract

- Service and interface: `io.github.keyboardspecialist.BC250Control1`
- Object: `/io/github/keyboardspecialist/BC250Control1`
- Snapshot: every 10 seconds while visible
- Status telemetry: every second
- Active operation: approximately every 750 milliseconds

Normal polling pauses during mutations. Snapshot and telemetry calls are coalesced, and a full refresh follows every operation completion.

Optional extensions:

- `GetTelemetry()` adds `sensors: [{key,device,label,value,unit}]`; the four legacy scalar fields remain supported. Additional sensors fall back to `snapshot.power.sensors`. Missing values are shown as unavailable, not zero.
- `GetCpuUnlockStatus().metrics` supplies `state`, `message`, `service: {enabled,active}`, and nullable `revision`. `actions` supplies metrics action blockers.
- `GpuVoltageAction(siii)` takes `(action, frequency, voltage, new_frequency)`. Actions: `set`, `add`, `edit`, `remove`, `offset`, `reset`. Only the offset voltage may be signed (−350 to +350 mV); all unused numbers are zero. Frequency bounds are 350–2230 MHz, voltage bounds 700–1050 mV after any offset. The service validates whole-curve ordering, minimum point count, and saved clock limits. `ResetGpuRamp()` has no arguments.
- `GetFsr4Inventory()` drives `InstallFsr4Dll(s)`, `UninstallFsr4Dll(s)`, `PrepareHelixsr()`, `InstallHelixsr(s)`, `UninstallHelixsr(s)`, `InstallOptiscaler(ss)`, and `UninstallOptiscaler(s)`. IDs must be 64 lowercase hex characters and present in the current service-discovered inventory. No arbitrary game paths are accepted.
- `CecAction(s)`, `SetCecToggle(sb)`, and `SetCecName(s)` use fixed action/key allowlists and a printable 1–14-byte UTF-8 broadcast name.
- Native-only `GetCliCatalog()` returns schema version 1, `available`, nullable `reason`, and fixed `sections: [{id,title,description,risk}]`. `OpenCliSection(s)` returns a tracked operation ID. Client and service both restrict section IDs; no commands or arguments are exposed. Operation completion means the terminal handoff completed, not that the external CLI task finished.

Game inventory is requested on opening the game subpage, on explicit refresh, and after mutations once loaded. Missing optional read methods produce local unavailable states. Mutations unsupported by service introspection are rejected before dispatch.

## Safety

CU routing, sustained GPU clocks, CPU overclock detection, and all CPU core-unlock operations require explicit confirmation. High-risk dialogs require an additional acknowledgement. Automatic CPU core unlock is unavailable unless the service reports exactly eight physical cores, and pending automatic reboot guards disable conflicting work.

Review `ASSETS.md` before redistribution. The media are embedded unchanged under the stable resource aliases documented in `PLAN.md`.
