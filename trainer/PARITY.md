# Trainer CLI parity audit

The six top-level tabs, artwork, media deck, and keyboard shortcuts are unchanged.

| Area | Trainer workflow | Authority / compatibility |
| --- | --- | --- |
| CEC | STATUS → HDMI CEC: adapter/daemon/integration status, TV/amp/source/volume, broadcast name, four automatic toggles | Existing D-Bus methods and snapshot; standby/integration confirmations; missing hardware/service disables controls |
| FSR4 | GPU → game manager: discovered game/target search, install/update, missing-file restore, orphan rollback | `GetFsr4Inventory`, `InstallFsr4Dll(s)`, `UninstallFsr4Dll(s)` |
| HelixSR | Explicit payload preparation, per-target install/update/restore, orphan rollback | `PrepareHelixsr()`, `InstallHelixsr(s)`, `UninstallHelixsr(s)`; payload, complete-scan, integrity and competing-injector blockers |
| OptiScaler | Discovered executable directories, seven fixed proxies, install/update/repair, rollback, orphan recovery, selectable launch-option text | `InstallOptiscaler(ss)`, `UninstallOptiscaler(s)`; integrity and FSR4/HelixSR ownership blockers |
| GPU curve | Inline set/add/edit/remove/offset/reset and risk acknowledgement | `GpuVoltageAction(siii)`; 350–2230 MHz, 700–1050 mV, signed offset −350…350; unused numeric fields zero |
| GPU ramp | Existing set plus confirmed reset | `ResetGpuRamp()` |
| Metrics | All available live hwmon sensors with snapshot fallback; four old scalar tiles retained | `GetTelemetry().sensors`, then `snapshot.power.sensors`; missing/null values stay unavailable |
| Eight-core compatibility | STATUS/CPU banners, decoder state, message, service state, revision, metrics enable and complete core-unlock/metrics removal with server blockers | `GetCpuUnlockStatus().metrics`, `CpuUnlockAction("metrics-enable"/"uninstall")`; removal is not limited to metrics and sampling never invokes mutations |
| CPU OC maintenance | Confirmed helper update | `CpuOcAction("update", 0, 0, 0)`; non-cancellable |
| Remaining CLI features | TOOLKIT → complete fixed CLI catalog, including swap, storage, persistence, wireless backend, memory temperature, RADV, codecs, Proton and manage | Native-only `GetCliCatalog()` / `OpenCliSection(s)`; host-user terminal, not a root shell; further prompts belong to the CLI |
| Flatpak | Same service-backed hardware/game workflows; native maintenance and terminal handoff unavailable | No manifest permissions changed; handoff rejected in the bridge even if the service advertises it |

## Contract deviations / additional client constraints

No D-Bus method or wire-signature deviations from the shared service contracts.
The native bridge additionally requires game IDs to be present in the most recent
service inventory (including orphan rollback records), and validates the visible
whole voltage curve before dispatch. The service still revalidates everything,
including saved clock caps and current file ownership. No arbitrary paths,
commands, CLI arguments, or SMU payloads are accepted by these workflows.

The CLI catalog IDs exactly match `backend/bc250_control/parity.py`. No new toolkit
machine-operation IDs or root CLI dispatch additions are required by Trainer.
Terminal operation completion means **handoff**, not completion of the external
CLI task; the confirmation warns against concurrent conflicting operations.

Older services report optional reads as unavailable. New mutation methods missing
from service introspection are refused locally; CPU tool updates additionally
require the installed backend's capability manifest. Metrics/removal actions use
service-reported availability. Legacy CLI checkouts expose only root/status
handoffs; current checkouts advertise 27 fixed sections. There is no CLI hardware
fallback. Missing hwmon/metrics fields are not replaced with mock measurements;
failed/malformed telemetry clears live values instead of silently freezing them.

## Verification

- `python3 -m unittest discover -s tests -p 'test_trainer*.py' -v`: **27 passed**, including ten new parity/resource/security/contract checks.
- `git diff --check -- trainer tests/test_trainer_parity.py`: clean.
- Added native bridge regression tests for game IDs/rollback, whole-curve bounds,
  ramp reset, CEC validation, read-only metrics sampling, and CLI injection rejection.
- Added QML regression tests for game/rollback/integrity blockers, OptiScaler
  conflicts/repair, sensor fallback/zero/null handling, UTF-8 CEC names, standby
  confirmation, CLI unavailability, and voltage confirmation/zero placeholders.
- **Native Release build passed** using the existing Ubuntu Trainer Distrobox,
  Qt **6.4.2**, GCC **13.3**, and isolated build directory
  `/tmp/opencode/frontend-parity-trainer-build`.
- **All five CTest targets passed:** bridge, media, toolkit controller, QML
  components, and offscreen startup. QML covers repeated rendered CEC page
  load/unload; its invisible test-parent teardown crash was fixed in the harness,
  without changing production layouts. Media tests use the installed normal
  multimedia backend, not the smoke-only `QT_MEDIA_BACKEND=mock` override.
- `qml-lint` target passed under the existing configuration. It emits informational
  import/type-resolution diagnostics; this is not a zero-diagnostics claim.
- Host binary `trainer/bc250-trainer` was preserved. Validation performed no application installation,
  hardware writes or package installs. Delivery uses toolkit `v0.36.0` and the
  independent `trainer-v0.2.0` release tag. Live
  D-Bus/polkit, terminal-session and hardware behavior still needs qualification.
