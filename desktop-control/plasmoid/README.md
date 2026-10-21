# BC-250 Control Plasma Plasmoid

Pure-QML Plasma 6.4 system-tray controls for the BC-250 SteamOS toolkit. The
package ID is `io.github.keyboardspecialist.bc250control`; it contains no
compiled plugin and executes only fixed `busctl` and `plasmawindowed` commands.

## Install

Install for the current user, then restart Plasma Shell or log out and in:

```bash
kpackagetool6 --type Plasma/Applet --install desktop-control/plasmoid
kquitapp6 plasmashell && kstart plasmashell
```

Upgrade an existing installation with:

```bash
kpackagetool6 --type Plasma/Applet --upgrade desktop-control/plasmoid
```

Add **BC-250 Control** to the system tray through **Configure System Tray >
Entries**. The applet metadata declares `X-Plasma-NotificationArea=true`.

Run the installed applet in its full-window form with:

```bash
/usr/bin/plasmawindowed io.github.keyboardspecialist.bc250control
```

## Test

Validate package metadata and QML where the Plasma 6 development tools are
installed:

```bash
python3 -m json.tool desktop-control/plasmoid/metadata.json >/dev/null
qmllint desktop-control/plasmoid/contents/ui/*.qml \
  desktop-control/plasmoid/contents/ui/components/*.qml \
  desktop-control/plasmoid/contents/ui/tabs/*.qml
```

The mock fixture renders all tabs without the service or BC-250 hardware:

```bash
qml6 -I desktop-control/plasmoid/contents/ui \
  desktop-control/plasmoid/contents/ui/tests/MockHarness.qml
```

If the distribution provides `qmlscene6` rather than `qml6`, use it with the
same arguments. Resize the fixture below and above 760 pixels to exercise tray
popup and `plasmawindowed` layouts.

Mock-only regression tests (Node.js for production JavaScript bodies; Qt 6/KDE
modules for an optional offscreen, all-tab construction test):

```bash
python3 -m unittest discover -s tests -p test_plasma_parity.py -v
node desktop-control/plasmoid/contents/ui/tests/test_parity.cjs
QT_QPA_PLATFORM=offscreen qml6 -I desktop-control/plasmoid/contents/ui \
  desktop-control/plasmoid/contents/ui/tests/SmokeHarness.qml
```

These tests never instantiate the real backend or mutate hardware. They validate
curve bounds/ordering and signed offsets, fixed command/section allowlists,
operation cancellation guards, live-vs-snapshot freshness, zero/null readings,
read-failure handling, sensor display, and construction of all eight tabs.

## System D-Bus API

The applet calls the system bus service, object, and interface below using
`/usr/bin/busctl --system --json=short call`:

```text
service:   io.github.keyboardspecialist.BC250Control1
object:    /io/github/keyboardspecialist/BC250Control1
interface: io.github.keyboardspecialist.BC250Control1
```

Read methods return a single D-Bus string (`s`) containing JSON:

| Method | Input | JSON result |
| --- | --- | --- |
| `GetSnapshot` | none | The complete `Snapshot` object described below |
| `GetTelemetry` | none | `{cpuClock,gpuClock,cpuTemp,gpuTemp}`, nullable numbers, plus additive `sensors` array |
| `GetCpuUnlockStatus` | none | CPU topology, unlock integrity/actions, and `metrics:{state,message,service:{enabled,active},revision}` (nullable revision) |
| `GetCliCatalog` | none | `{schemaVersion:1,available,reason,sections:[{id,title,description,risk}]}`; reason is nullable, risk is `read-only`, `advanced` or `maintenance` |
| `GetMeshStatus` | none | Patched-kernel, scheduler, RADV, global activation, and FSR4 state |
| `GetFsr4Inventory` | none | Installed Steam games and validated game-local DLL targets |
| `GetOperation` | `s operationId` | `{operationId,method,status,...,error?}` |

Mutation methods return a single string containing an operation ID matching
`[A-Za-z0-9_-]{1,64}`. `GetOperation` reports `queued`, `running`, `succeeded`,
`failed`, or `cancelled` in its `status` field; operations remain queryable
through their terminal state. The applet serializes executable calls and polls
active operations every 750 ms. `CancelOperation` accepts an operation ID and
returns `b` to support cancelling long-running work.

| Method | Signature | Arguments |
| --- | --- | --- |
| `SetCuWgp` | `yyyb` | SE, SH, WGP index, enabled |
| `SetGpuFrequency` | `suu` | allowlisted mode, minimum MHz, maximum MHz |
| `SetLoadTarget` | `s` | `eager` or `reset` |
| `SetCustomLoadTarget` | `yy` | lower and upper percent |
| `SetTemperatureTarget` | `y` | GPU throttle temperature Celsius |
| `SetRamp` | `u` | climb milliseconds |
| `ResetGpuRamp` | none | restore CLI ramp/timing defaults |
| `GpuVoltageAction` | `siii` | action, frequency MHz, voltage mV, new frequency MHz; unused numbers must be zero |
| `OpenCliSection` | `s` | fixed catalog section ID; returns a launch-operation ID, not terminal workflow completion |
| `InstallFsr4Dll` | `s` | opaque 64-character target ID from `GetFsr4Inventory` |
| `UninstallFsr4Dll` | `s` | opaque 64-character target ID from `GetFsr4Inventory` |
| `CpuOcAction` | `suuu` | action, MHz, mV, temperature Celsius |
| `CpuUnlockAction` | `s` | `test`, `enable`, `efi-enable`, `off`, `metrics-enable`, or `uninstall`; controls require service-reported action availability |
| `SetCpuMitigations` | `b` | configured kernel mitigation state |
| `SetCpuSmtDisabled` | `b` | disable SMT at boot |
| `SetUmaSize` | `u` | CMOS minimum VRAM in aligned MiB |
| `SetTtmPages` | `u` | dynamic TTM limit in 4 KiB pages |
| `RemoveTtmOverride` | none | remove the toolkit-owned TTM GRUB drop-in |
| `SetHdmiSurround` | `b` | managed Dolby Digital 5.1 HDMI output state |
| `CecAction` | `s` | allowlisted CEC action |
| `SetCecToggle` | `sb` | allowlisted setting, enabled |
| `SetCecName` | `s` | printable 1-14 UTF-8 byte name |

The CPU OC actions are `detect`, `apply`, `enable`, `update`, and `off`. GPU modes are
`adaptive`, `range`, `pin`, and `max`. CEC actions are `tv-on`, `tv-off`,
`amp-on`, `amp-off`, `switch`, `release`, `vol-up`, `vol-down`, and `mute`.
CEC toggle keys are `wake-tv`, `suspend-tv`, `allow-standby`, and `uinput`.

GPU voltage actions are `set`, `add`, `edit`, `remove`, `offset`, and `reset`.
For `edit`, frequency is the existing point and new frequency is the replacement;
for `offset`, only voltage contains the signed delta; for `reset`, all numeric
arguments are zero. The editor previews the candidate curve and requires at
least two unique sorted points at 350–2230 MHz, nondecreasing 700–1050 mV voltages,
and coverage of saved range/pin settings. The service and CLI revalidate current
state atomically, including rollback. GPU custom load thresholds follow the CLI
5–99% bounds and lower < upper order.

Both telemetry and optional `snapshot.power.sensors` use
`[{key,device,label,value,unit}]`; keys identify sensors and values are numbers
(unknown values are displayed as unavailable). Units are displayed as supplied,
including mV, W, RPM, A, and °C. Only kernel-exposed readings are available. Legacy
temperature arrays remain supported; zero is never interpreted as missing.

The CLI tab provides terminal handoff, not native inline feature implementations,
for `menu`, `status`, `power`, `ram`, `swap`, `compute`, `cpu-unlock`, `cec`,
`storage`, `persistence`, `wifi-backend`, `memory-temperature`, `radv`,
`video-codec`, `proton`, `manage`, `setup`, `toolkit-update`, `core`, `graphics`,
`devices`, `maintenance`, `amdgpu-boot`, `drivers`, `unlocks`, `storage-updates`,
and `interfaces` (27 fixed sections). The backend launches a fixed allowlisted
route as the logged-in user. Availability reasons stay visible when a terminal,
toolkit, or desktop-session prerequisite is missing. Anything not explicitly
read-only requires confirmation before launch; authorization and final prompts
remain in the terminal. Terminal workflow results are not tracked by Plasma.

The CLI tab reports the checkout version separately from the installed service.
Legacy checkouts without the capability probe expose only root/status handoffs.
New curve writes, ramp reset and CPU helper updates require their installed
service capability; updating source alone cannot update a running backend.

The snapshot schema is the same typed object consumed by the Decky interface:
top-level `toolkit`, `cu`, `power`, `gpu`, `cpu`, `cec`, `ram`, and `audio` objects. CPU core-unlock and Mesa/RADV/FSR4 state use their dedicated reads. In
particular, the UI expects service states as `{enabled,active}`, CU `rows` and
`savedMasks`, GPU live/requested ranges and tuning values, CPU
`installed`/`staged` profiles, CEC state and behavior booleans, and power
temperatures, plus CMOS/TTM configured and active memory limits. JSON/free-form service output is parsed only as data and is never
inserted into a command. FSR4 mutation methods accept only opaque target IDs;
the service rediscovers each target from Steam metadata before invoking the
transactional DLL helper.

## Safety And Polling

Command arguments are integer/range checked or selected from strict
allowlists. The only user-entered text, the CEC name, is validated against the
service rules and passed through a dedicated POSIX single-word quoting helper;
embedded single quotes are escaped with the standard close/quoted-quote/reopen
sequence. Service operation IDs are strictly validated before polling.

Snapshot polling runs every 10 seconds while the UI is visible and every 60
seconds while collapsed. One-second telemetry polling runs only while a visible
Overview tab requests it. Polling pauses during hardware mutations; a completed
operation triggers an immediate snapshot refresh.

Overview labels and charts both use live telemetry. Failed/unknown live readings
are not replaced with old values; a failed sample adds a chart gap. Live samples
expire after five seconds. Snapshot-only values expire after 30 seconds visible
or 90 seconds collapsed. Failure/freshness affects tray health independently of
successful unrelated reads. CPU-unlock/mesh/game read failures clear their cached
data rather than leaving actionable stale state. Curve/ramp reset, terminal
launch, CPU-unlock integration, and CPU-helper updates are noncancellable; other
operations also respect the service's cancellation flag.
