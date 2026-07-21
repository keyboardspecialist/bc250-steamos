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
kpackagetool6 --type Plasma/Applet --show-info desktop-control/plasmoid
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
| `GetTelemetry` | none | `{cpuClock,gpuClock,cpuTemp,gpuTemp}`, nullable numbers |
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
| `SetRamp` | `u` | climb milliseconds |
| `CpuOcAction` | `suuu` | action, MHz, mV, temperature Celsius |
| `CecAction` | `s` | allowlisted CEC action |
| `SetCecToggle` | `sb` | allowlisted setting, enabled |
| `SetCecName` | `s` | printable 1-14 UTF-8 byte name |

The CPU actions are `detect`, `apply`, `enable`, and `off`. GPU modes are
`adaptive`, `range`, `pin`, and `max`. CEC actions are `tv-on`, `tv-off`,
`amp-on`, `amp-off`, `switch`, `release`, `vol-up`, `vol-down`, and `mute`.
CEC toggle keys are `wake-tv`, `suspend-tv`, `allow-standby`, and `uinput`.

The snapshot schema is the same typed object consumed by the Decky interface:
top-level `toolkit`, `cu`, `power`, `gpu`, `cpu`, and `cec` objects. In
particular, the UI expects service states as `{enabled,active}`, CU `rows` and
`savedMasks`, GPU live/requested ranges and tuning values, CPU
`installed`/`staged` profiles, CEC state and behavior booleans, and power
temperatures. JSON/free-form service output is parsed only as data and is never
inserted into a command.

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
