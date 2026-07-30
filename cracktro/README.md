# BC-250 Cracktro

Native Qt 6 frontend for the BC-250 control service. It renders the supplied cracktro artwork as a fixed-aspect frameless window, loops the supplied OGA soundtrack, and communicates with the privileged toolkit exclusively over the system D-Bus.

The application does not invoke scripts, `sudo`, `busctl`, or any subprocess. Hardware checks and authorization remain in `io.github.keyboardspecialist.BC250Control1`.

## Features

- Status dashboard with one-second telemetry while the page is active
- Adaptive, ranged, pinned, and maximum GPU clock modes
- GPU load target and ramp controls with service-equivalent client bounds
- Live WGP routing with an advanced interlock and per-write confirmation
- CPU core-unlock status, one-time test, replay enable, and replay disable controls
- CPU overclock detection, apply, boot replay, and stock actions
- Asynchronous QtDBus operation tracking, protected-operation cancellation state, and service lifetime monitoring
- Persisted soundtrack mute and volume via `QSettings`
- `--mock` development mode that never contacts hardware

The installed service must include `GetCpuUnlockStatus()` and `CpuUnlockAction(string)` for core-unlock controls. Older services remain usable for status, GPU, CU, and CPU-overclock features; the UI reports the missing extension rather than falling back to command execution.

## Build

Ubuntu 24.04 is the compatibility baseline (Qt 6.4 or newer):

```sh
./build-distrobox.sh
```

The helper creates `bc250-cracktro-ubuntu2404` when needed, but does not install packages automatically. If dependencies are missing, it prints the exact `apt` command to run inside the container. Output is written to `build-ubuntu2404/`.

For an already prepared environment:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

Available convenience targets depend on installed tools:

```sh
cmake --build build --target qml-lint
cmake --build build --target qml-tests
cmake --build build --target smoke
```

## Development

Run without service access or hardware writes:

```sh
./build/bc250-cracktro --mock
```

Run the executable startup check:

```sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_MEDIA_BACKEND=mock \
  ./build/bc250-cracktro --mock --smoke-test
```

Controls are `F1` Status, `F2` GPU, `F3` Compute Units, `F4` CPU, `M` mute, `R` refresh, and `Escape` close. Drag any noninteractive part of the left artwork to request a compositor-managed system move under Wayland.

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
