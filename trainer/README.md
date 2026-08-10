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

- Status dashboard with one-second telemetry while the page is active
- Native Toolkit task dashboard for component inventory, setup, driver builds, repairs, and per-component removal
- Live bounded console output with secure `sudo` prompting and protected process cancellation
- Adaptive, ranged, pinned, and maximum GPU clock modes
- GPU load target and ramp controls with service-equivalent client bounds
- RAM/VRAM split controls for CMOS UMA minimums and dynamic TTM limits
- Live WGP routing with an advanced interlock and per-write confirmation
- Mutually exclusive CPU core-unlock controls for recommended Linux replay and experimental EFI preboot
- CPU overclock detection, apply, boot replay, and stock actions
- Asynchronous QtDBus operation tracking, protected-operation cancellation state, and service lifetime monitoring
- Collapsible music library with transport, natural track ordering, and folder watching
- Synchronized whole-track waveform and dedicated beat-energy visualizer
- Persisted music directory, current track, and volume via `QSettings`; mute is session-only
- `--mock` development mode that never contacts hardware

The installed service must include `GetCpuUnlockStatus()` and `CpuUnlockAction(string)` for core-unlock controls. The action allowlist is `test`, `enable`, `efi-enable`, and `off`; action availability is always taken from the status response. Older services remain usable for status, GPU, CU, and CPU-overclock features; schema-v1 Linux replay status remains supported, and the UI reports a missing extension rather than using toolkit execution as a hardware-control fallback.

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

Build and install a local GUI-only Flatpak with the KDE 6.10 SDK and runtime from
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
desktop portal. Toolkit dashboard actions are therefore native-only.

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

## Safety

CU routing, sustained GPU clocks, CPU overclock detection, and all CPU core-unlock operations require explicit confirmation. High-risk dialogs require an additional acknowledgement. CPU replay enablement is unavailable unless the service reports exactly eight physical cores, and pending automatic reboot guards disable conflicting work.

Review `ASSETS.md` before redistribution. The media are embedded unchanged under the stable resource aliases documented in `PLAN.md`.
