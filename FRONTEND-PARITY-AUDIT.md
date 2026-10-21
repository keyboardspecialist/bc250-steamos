# Frontend parity audit

## Scope and provenance

- **Baseline:** `a751f302d7ff3f4e4fb3d0225fb74c82a658d7c8` (`a751f30`), toolkit **`v0.35.0`**; audit date 2026-10-21.
- **Release source audit:** implementation below is prepared for toolkit **`v0.36.0`** and separately built Trainer **`trainer-v0.2.0`**. The detailed baseline inventory remains historical evidence against that revision, not a description of the updated interfaces. This is workflow coverage through native controls plus explicit CLI handoffs, **not full-native parity** or attestation of installed binaries.
- Existing unrelated untracked files, local binaries, nested checkouts and research payloads were preserved and are not treated as shipped capabilities.
- CLI authority: all ten `menus/*.mmd` graphs, `menus/targets.json`, `MENU-GRAPH.md`, and standalone scripts' help/dispatch/implementation. Graphs describe navigation; handwritten adapters retain prompts, authorization, validation, and recovery. Help/code also expose routines not represented by individual menu nodes.
- Frontend evidence: `trainer/qml/pages/`, `trainer/src/{Bc250Bridge,ToolkitController}.{h,cpp}`, `desktop-control/plasmoid/contents/ui/{Backend.qml,tabs/}`, `decky-plugin/{main.py,src/api.ts,src/types.ts,src/tabs/}`, shared backend/service, installers, staging scripts, and release workflows.
- Validation did not install applications, change host services, write live hardware, run live stress tests, or access firmware. Release commits/tags are a subsequent explicitly requested delivery step. A separate passive sysfs observation is identified below; it is not evidence that every supported BC-250 exposes those sensors.

### Classification

| Mark | Meaning |
| --- | --- |
| **N** | Present, purpose-built native UI/control/status. May use a typed service operation implemented by a canonical helper; this does not mean independent reimplementation. |
| **H** | Present CLI handoff/action wrapper: user explicitly enters a canonical CLI workflow, including Trainer's fixed-action PTY cards. **Not native control parity.** |
| **U** | No corresponding frontend capability at baseline. A written instruction to use a terminal is not a working handoff. |
| **P** | Historical planned remediation in the baseline tables; see the completed implementation matrix below for its final classification. |

Trainer native and Trainer Flatpak must be distinguished. Baseline Flatpak can use the installed system control service but cannot access/execute the host toolkit; PTY/toolkit-install/update cards are unavailable there. Do not enable a host-command escape or broaden Flatpak permissions to erase that deliberate boundary.

## Executive findings

1. **Baseline native parity is incomplete on all three frontends.** Shared everyday GPU/CPU/CU/RAM controls exist, but advanced tuning, metrics readiness, diagnostics, persistence/recovery, and lifecycle coverage differ substantially. Trainer notably lacks native CEC and per-game upscaler management already present in Plasma and Decky.
2. **Telemetry has four baseline scalar fields only:** CPU/GPU clocks and temperatures. CPU/GPU voltage and power, general sensors, and eight-core metrics compatibility are not in that fast telemetry response. Configuration mV is not live voltage; an AMDGPU PPT channel is not proven GPU-only power.
3. **A bounded CLI catalog is the appropriate completion mechanism for advanced workflows**, not arbitrary commands or root execution of a user checkout. Full workflow reachability through a root menu is a valid handoff, but must not be advertised as full native parity or a complete set of direct section routes.
4. **Trainer delivery is independently versioned.** Main `v*` toolkit tags do not build Trainer. Updating toolkit source and restarting Trainer does not replace its compiled executable. New Trainer UI requires a separate tested build/install or authorized `trainer-v*` release; do not publish unasked.
5. **Missing-checkout bootstrap remains an explicit limitation.** Source and installed-service capability negotiation now exist independently; neither attests installed driver state or the compiled UI. Trainer release kits still do not create a complete toolkit checkout.

## Implemented working-tree coverage

| Capability | Trainer native | Plasma | Decky | Trainer Flatpak |
| --- | --- | --- | --- | --- |
| Existing GPU clocks/load/thermal/ramp, CPU OC/security/SMT/unlock, WGP routing, RAM/TTM, audio | **N** | **N** | **N** | **N**, installed service required |
| Voltage-curve set/add/edit/remove/offset/reset; exact ramp reset | **N** | **N** | **N** | **N** |
| CPU tool update; eight-core decoder/service/revision status; guarded metrics enable and full unlock/metrics uninstall | **N** | **N** | **N** | **N** |
| Four live clock/temperature scalars plus labeled hwmon temperatures, mV, W, RPM, A | **N** | **N** | **N** | **N**, sensors actually present only |
| CEC everyday controls and FSR4/HelixSR/OptiScaler inventory/install/repair/restore/orphan recovery | **N**, newly added | **N** | **N** | **N** |
| Guided setup, driver/kernel/graphics/boot policies, swap, networking, storage, persistence/recovery, interfaces, toolkit update/removal | **H**, fixed catalog plus existing PTY cards | **H**, fixed catalog | **H**, desktop terminal required | **U**, intentionally no host-command access |
| Direct SMU CPU-voltage, actual CMOS reads, advanced CU management, experimental GDDR6 payload workflows | **H** through canonical domain menus, no new raw RPC | **H** | **H** | **U** as embedded workflows |
| Arbitrary commands/paths, raw SMU writes, firmware flashing, root execution of a user checkout | **U** | **U** | **U** | **U** |

Handoffs retain canonical CLI validation, sudo prompts, reboot checkpoints and
recovery behavior. They are not inline controls or evidence that every standalone
CLI flag has a dedicated UI button. Generic hwmon sampling never activates an
SMU payload; package PPT and `vddnb` keep their actual labels. Fan RPM is not a
fan-curve editor; fan policy remains in CoolerControl.

## Baseline capability inventory

CLI routes below are instructions for an explicit terminal workflow, not commands executed by this audit. Unless shown otherwise, the prefix is `bash ./bc250-toolkit.sh`. The existing CLI requests its own privileges and confirmations. Baseline **U** entries can become **H**, not **N**, after a tested fixed-section launcher lands.

### GPU, power foundation, and CPU

| Capability / canonical CLI | Trainer native at baseline | Plasma at baseline | Decky at baseline | Gap / safe disposition |
| --- | --- | --- | --- | --- |
| ACPI override, CPU schedutil, GPU governor test-start, enable after load testing; `power foundation` | **H partial:** power-install card runs `action power-install` / power `all` | **N status**, **U setup** | **N status**, **U setup** | Power `all` installs ACPI + test-starts governor, **not** boot-enable. Guided foundation handoff must retain reboot/load-test/enable sequence and helper repair. |
| GPU adaptive/default, cap (`range` with floor 0), min/max range, pin, maximum curve clock; `power frequency` | **N** | **N** | **N** | Typed modes are `adaptive`, `range`, `pin`, `max`; allowed clocks 350–2230 MHz. Preserve requested/live/saved replay distinctions. |
| GPU safe-point display; power `gpu-volt` | **N read-only** | **N read-only** | **N read-only** | All baseline frontends show configured MHz/mV points, not live voltage. |
| GPU curve `set/add/edit/remove/offset/reset`; `power frequency` advanced curve child | **U writes** | **U writes** | **U writes** | **P:** typed GPU voltage action using the canonical transaction. Retain 350–2230 MHz, 700–1050 mV, unique sorted frequencies, nondecreasing voltage, at least two points, atomic rollback/reload/replay and explicit risk confirmation. |
| GPU live voltage; power `gpu-volt` display / hwmon `vddgfx` | **U** | **U** | **U** | **P telemetry**, only when a positively identified actual sensor exists. Never substitute configured curve voltage. |
| GPU load eager 40/10%, tuned default 80/65%, custom upper/lower; `power load` | **N** | **N** | **N** | UI minimum/maximum arguments differ from CLI `set UPPER LOWER` ordering; preserve adapter mapping and fractions-vs-percent conversion. |
| GPU thermal target and automatic 10 °C hysteresis; power temperature workflow | **N set** | **N set** | **N set** | CLI also has explicit reset to 85/75 °C. Equivalent values can be set natively; do not imply a separate reset button exists. |
| GPU derived ramp/climb time 200–5000 ms; `power ramp` | **N custom time** | **N custom time** | **N custom time** | CLI responsive/relaxed presets are expressible as 500/1000 ms; derived timing is not the same as installation defaults. |
| GPU ramp reset (200 MHz/200 ms, 1 s downhold) | **U** | **U** | **U** | **P:** separate ramp-reset action; setting a similar climb time is not an exact reset. |
| CPU OC detect/apply/enable/off; `power cpu` | **N** | **N** | **N** | Existing detection is a stress-stepped hardware-writing operation, can crash, and pauses governor for shared SMU access. UI must preserve safety bounds, serialization, staged vs enabled profile, and noncancellable transaction semantics. |
| CPU installed/staged measured OC verdict | **N** | **N** | **N** | Saved detection result is historical; configured VID safety limit is neither measured result nor current Vcore. |
| CPU **live** SMU voltage (`cpu-oc status`, `oc_live_mv`, Q3 `0x36`) | **U** | **U** | **U** | CLI can read it when root + trusted staged OC tool are available. New generic hwmon scalar support does **not** replicate this SMU path. Keep explicit advanced CLI handoff unless a separately secured bounded read is provided. |
| CPU tool-source update (`cpu-oc update`) | **U** | **U** | **U** | **P:** typed CPU update action. Canonical helper refetches pinned upstream sources plus toolkit patches; not an arbitrary checkout update. |
| Security mitigations configured/current boot/reboot/protection; `power cpu` | **N** | **N** | **N** | Disabling weakens security; preserve confirmation and next-boot/current-boot distinction. |
| SMT live + persistent disable/enable; `power cpu` | **N** | **N** | **N** | Distinguish configured state, actual live sysfs state, foreign drop-ins, and unsupported threading control. |
| CPU physical/logical topology, CCX grouping, one-time 6c→8c test, Linux replay, EFI alternative, off; `cpu-unlock` | **N** | **N** | **N** | Exactly eight physical cores gate persistence. Linux and EFI methods are mutually exclusive. Warm reboot enumerates cores; full power-off restores stock mask. UI topology is not eight-core metrics attestation. |
| Eight-core SMU metrics compatibility/service, `metrics-enable`, full unlock `uninstall`; `cpu-unlock` | **U** | **U** | **U** | **P:** `cpuUnlockStatus.metrics`, actions `metrics-enable` and `uninstall`. Existing baseline actions are only test/enable/efi-enable/off. Off retains files and is not full uninstall. |

Evidence: `menus/power.mmd`; baseline `backend/bc250_control/backend.py` (`get_gpu_status`, `get_cpu_status`, `get_cpu_unlock_status`, mutations); `bc250-power.sh` help and `oc_live_mv`; the three GPU/CPU pages/tabs. Baseline `get_cpu_unlock_status` at lines 1642–1710 has no `metrics` object; `get_cpu_status` at 2463–2582 has no live-voltage field.

### Compute units, memory allocation, swap, and experimental memory telemetry

| Capability / canonical CLI | Trainer native | Plasma | Decky | Gap / safe disposition |
| --- | --- | --- | --- | --- |
| CU live/factory/saved masks, counts, boot/protection status | **N** | **N** | **N** | Saved routing must not be passed off as a verified live register map. Hardware granularity is WGP pairs (two CUs), not individual CUs. |
| Live nonfactory WGP toggles with advanced arming/confirmation | **N** | **N** | **N** | Backend deliberately locks factory-enabled WGPs; CLI manager permits broader operations. Do not weaken native safeguards for superficial parity. |
| Build UMR/check/verify full harvest map; `compute` | **H build only** | **U** | **U** | Trainer compute-build is prerequisites only. Detailed map validation/manager remains CLI. |
| Save current CU table, install/replay/uninstall service, persist across updates, stock-dispatch restore; `compute` live manager | **U** (component removal **H**) | **U**, manual CLI guidance | **U**, manual CLI guidance | Keep independent live-change/stability-test/save/boot-persistence steps. Use canonical manager `write-service-table`, `install-service`, `apply-service`, `uninstall-service`, `stock-dispatch`; `bc250-40cu.sh persist/revert` have separate lifecycle semantics. |
| RAM helper install/update; `ram` | **H** | **U** | **U** | Canonical installer verifies upstream release. Existing trusted helper availability gates native controls. |
| CMOS UMA minimum write 256–12288 MiB, 16 MiB alignment, 2048 MiB blocked | **N** | **N** | **N** | Decky has an editable 16 MiB-step slider; Trainer also provides quick presets. CMOS persists across OS/uninstall; recovery can require physically clearing CMOS. |
| Actual CMOS configuration read (`bc250-ram-split.sh show`, `ram` → read configuration) | **U** | **U** | **U** | Baseline `umaLastRequestedMiB` is a recorded request, **not** attested current CMOS. All three baseline RAM summary labels omit that distinction. Keep CLI read or add a dedicated trusted read, not an inferred value. |
| TTM configured/boot/live raw pages; set/remove override | **N custom/presets** | **N custom** | **N editable slider** | 4 KiB pages; `pages × 4096 / 2^30` GiB. Guide preset 3014656 is 11.50 GiB dynamic, not exactly 12 GiB. Decky has editable values with 65536-page slider increments; exact widget-entry behavior should be tested. |
| Swap zram/zswap selection/remove; `swap` | **H partial:** zstd zram, lz4 zswap, removal | **U** | **U** | Native Trainer cards are explicit CLI operations, not a structured swap settings/status UI. |
| Swap alternative compressors (lz4 zram / zstd zswap), custom disk size, verify, configured/active/pending state | **U** | **U** | **U** | CLI menu has four profiles; standalone help additionally accepts zswap size. Root swap handoff preserves mutually exclusive profiles, reboot transitions, priority 100 vs 10, 10% pool and no live swapoff. Card description mentioning alternatives is not access to them. |
| GDDR6 source/backup status, verified prepare, live patch, attested eight-chip read, restore; `memory-temperature` | **U** | **U** | **U** | Appropriate **P handoff**, not passive telemetry autoactivation. P3.0-only experimental SMU payload, explicit risk acknowledgement, exact backups, shared transport lock, firmware/payload attestation. |
| GDDR6 chip/average/hotspot °C in fast frontend telemetry | **U** | **U** | **U** | Generic sensors cannot conjure these: CLI `read --json` uses an already-attested live SMU payload, not hwmon. Do not label AMDGPU edge or motherboard temperature as GDDR6. |

Evidence: `menus/{compute,ram-split,swap,toolkit}.mmd`; `bc250-cu-live-manager.sh` help at 67–119 and save/apply paths; baseline backend `set_cu_wgp`, `get_ram_status` at 2667–2716; RAM/CU UI; `bc250-swap.sh` help; `bc250-memory-temperature.sh`; `memory-temperature/bc250-memory-temperature.py` at 353–392. The latter reports `chips[{chip,raw,code,temperatureC}]`, `averageC`, `hotspotC`, `hotspotChip`; codes convert as `code * 2 - 40`, and timeouts/invalid responses fail without inventing temperatures.

### Fan control, graphics, CEC/audio, and wireless

| Capability / canonical CLI | Trainer native | Plasma | Decky | Gap / safe disposition |
| --- | --- | --- | --- | --- |
| NCT6687 fan driver install/remove; root menu → Power/Devices | **H** | **U** | **U** | Sensor availability depends on installed driver and physical wiring. Driver controls are not a full fan-curve UI. |
| CoolerControl install/remove, profiles/curves/monitoring; `interfaces` | **H installer/removal** | **U integrated control** | **U integrated control** | Fan curves remain in CoolerControl's own UI. A CLI/install handoff is sufficient; do not duplicate its policy engine or claim fan control from RPM display alone. |
| AMDGPU kernel fixes, clean build output, scheduler policy vs KFD runlist; root → Graphics / `drivers` | **H build/remove**, **U clean/options** | **N readiness only** | **N readiness only** | Scheduler/KFD options are mutually exclusive. Kernel changes require build integrity and reboot. Planned section handoff must reach these, not only RADV. |
| Global DirectMesh + FSR4 RADV setup/resume and runtime status | **N status / H setup-remove** | **N status and typed setup** | **N status and typed setup** | Prerequisites, reboot, ownership, and integrity checks remain authoritative. DirectMesh defaults on globally; per-game opt-out is `RADV_DIRECTMESH=0 %command%`. |
| Retired R2 removal (not installation) | **N status / H cleanup** | **N** | **N** | Preserve global RADV, original Proton, prefixes/saves. Recognized private R2 Proton copy is removed; preserve personal additions first and manually remove obsolete Steam launch options. |
| Legacy per-game launch-option/record cleanup; `radv` | **U** | **U** | **U** | Keep explicit migration CLI workflow, not a generic unchecked Steam launch-option editor. |
| Portable FSR4 target scan/install/update/restore, orphan rollback recovery | **N count only / U manager** | **N manager** | **N manager** | **P Trainer:** native inventory + typed target-ID operations. Backend already has guarded scan and restore APIs; no arbitrary DLL path/root file replacement needed. |
| Pinned HelixSR payload prepare/install/update/restore, orphan rollback recovery | **U manager** | **N** | **N** | **P Trainer.** Latest opt-in / local DLSS input remains advanced CLI where unsupported by typed API. Do not imply pinned/native preparation tracks latest. Anti-cheat warning required. |
| OptiScaler candidate/proxy install/update/repair/restore | **U** | **N** | **N** | **P Trainer.** API validates candidate IDs, proxy allowlist, target ownership and rollback state. Standalone CLI has direct advanced routines not represented as a separate toolkit menu. No anti-cheat/online claims of safety. |
| GE-Proton verify/install/update/repair/remove preserving prefixes/saves; `proton` | **H** | **U** | **U** | Do not confuse global RADV, retired private R2 Proton, and managed BC-250 GE-Proton. |
| VA-API codec status/test/install optional 32-bit companion/remove; `video-codec` | **U** | **U** | **U** | CLI machine action exists but baseline Trainer operation table/card does not expose it. Native video-codec handoff should retain with/without-32-bit distinction and testing. |
| CEC everyday TV/receiver/input/volume, OSD name, four behavior toggles | **U** | **N** | **N** | **P Trainer:** use existing CEC APIs, not a new broad command runner. Requires actual CEC device/daemon. |
| CEC guided setup, poweroff/session boot wake, polite/grab, receiver follows/hook, handoff-to-other-device, overrides reset, scan/test/repair/remote/monitor | **U** | **U advanced workflows** | **U advanced workflows** | CLI `cec` handoff retains nuanced session/root behavior and confirmations. `test` is graph-labeled read-only but can send wake/input/audio and optional standby: read-only label does not guarantee no external effects. |
| HDMI Dolby Digital AC-3/stereo and real active profile | **N toggle / H install-remove** | **N** | **N** | Keep actual active profile vs installed config and update-protection state distinct. |
| AIC8800 WiFi/Bluetooth build/remove; root → Devices | **H** | **U** | **U** | Hardware-specific, not a universal networking prerequisite. |
| iwd/wpa_supplicant select, lock/unlock, status/persistence; `wifi-backend` | **U** | **U** | **U** | **P handoff.** Backend choice/lock is independent of AIC8800 driver support. Changing it can disrupt connectivity; keep effective choice/service/Steam preference/protection distinctions. |

Evidence: `menus/{toolkit,mesh-shader,cec}.mmd`; `trainer/src/ToolkitController.cpp` operation table at baseline 60–129; `GpuPage.qml`, `StatusPage.qml`; Plasma `GpuTab.qml` and `CecTab.qml`; Decky `MeshTab.tsx` and `CecTab.tsx`; `bc250-{mesh-shader,fsr4,helixsr,optiscaler,proton,wifi-backend}.sh`; `video-codec/bc250-video-codec.sh`; `coolercontrol/install.sh`.

### Storage, updates, persistence, recovery, and uninstall

| Capability / canonical CLI | Trainer native | Plasma | Decky | Gap / safe disposition |
| --- | --- | --- | --- | --- |
| Persistent privileged storage install/repair/remove | **H** | **U** | **U** | Removal is dependency-gated. Do not equate toolkit checkout ownership with trusted root-installed payload ownership. |
| Storage mount source/recovery/keep-list status; `storage` | **N inventory state only**, detailed **U** | **U** | **U** | CLI reports infrastructure details beyond installed/partial component inventory. |
| Per-component/all update protection, remove keep lists; `persistence` | **U** | **N selected status only** | **N selected status only** | Existing installers may install protection internally; this does not expose management parity. CLI includes compute/power/RAM/swap/CEC/AIC/WiFi/fan/CoolerControl/desktop/AMDGPU; direct help additionally includes AC-3. |
| Recover compute/power/all from atomic-update snapshot; `persistence` | **U** | **U** | **U** | Keep canonical newest-snapshot inspection and restoration. Never silently overwrite current tuning through a status poll. |
| Component inventory/install/build/repair/remove | **H many cards**, **N inventory** | **U general lifecycle** | **U general lifecycle** | Trainer's explicit operation allowlist is narrower than CLI machine action IDs and narrower again than full toolkit menu coverage. |
| Full uninstall with dependency order and preserved data; `manage` | **U** | **U** | **U** | Typed “remove component” cards are not uninstall-all. Canonical CLI reviews a plan and preserves data; shared service registrations of other clients must survive individual frontend removal. |
| Post-uninstall purge of preserved data/cache; `manage` | **U** | **U** | **U** | Permanently destructive. CLI requires all components removed, checks rollback/ownership, retains checkout and shared pnpm. Link explicitly; never auto-run on normal uninstall. Memory-temperature has its own guarded purge/backup rule. |
| Main toolkit latest-version check/verified atomic update/notes | **N native UI** (existing checkout required) | **U** | **U** | Trainer invokes embedded updater as user; CLI `toolkit-update[-check]` uses same updater. This updates source tree, **not Trainer binary or every installed component**. |
| Trainer binary latest-version check/update or missing-toolkit bootstrap | **U in app** | **U** | **U** | CLI `trainer` downloads newest independently tagged release. It is not the same as toolkit update and does not prove latest UI/service capabilities. |

Evidence: `menus/{storage,update-persistence,maintenance}.mmd`; `bc250-{storage,update-persistence,maintenance,toolkit}.sh`; `trainer/src/ToolkitController.cpp` update logic; `scripts/toolkit-update.py`; installers and service client registration.

## Metrics: units, provenance, and availability

### Baseline implemented sources

| Value | Source / units / interpretation |
| --- | --- |
| `cpuClock` | Maximum current `cpu MHz` reported by `/proc/cpuinfo`, rounded MHz; fallback maximum cpufreq `scaling_cur_freq` in kHz divided by 1000. Not an all-core average, sustained boost guarantee, or per-CCX metric. |
| `gpuClock` | Active `*` entry from DRM `pp_dpm_sclk`, MHz. Baseline scans `card*`, rather than a fully attested target GPU identity. |
| `cpuTemp` / `gpuTemp` | Baseline generic first matching hwmon device/label from `_temperatures`; raw integer millidegrees Celsius divided by 1000 and rounded to one decimal. Regex selection is not sensor provenance; package/Tctl, edge, junction and board CPU temperatures are not interchangeable. |
| `power.temperatures[]` | Baseline snapshot contains `{device,label,celsius}` for readable hwmon temperature inputs. Fast `GetTelemetry` does not return this array and the regular overview does not display the full inventory. |
| GPU safe-point `voltage` / OC config | mV settings/historical detection data. Never fill a live-voltage scalar from these. |
| Voltage sensors | Linux hwmon `in*_input` is normally mV; report with explicit V or mV conversion and source path/label. `vddgfx` is graphics voltage; `vddnb` is not automatically CPU Vcore. |
| Power sensors | Linux hwmon `power*_input` / `power*_average` is µW; divide by 1,000,000 for W, and distinguish input vs average. AMDGPU `PPT` must retain its package/APU/PPT provenance; it is not proven discrete GPU-only consumption. |
| Fan sensors | `fan*_input` is RPM. Zero can mean stopped, disconnected, or unwired; not evidence of a usable fan-control channel. |
| Eight-core metrics readiness | `core-unlock/smu-metrics` is a separately opt-in production payload for SMU `0.58.6.0`, eight active physical cores, BC-250 identity, and decoder revision `smu-8core-metrics-r1`. Installed marker/service status alone must not be described as freshly attested live firmware activation. |

Baseline code: `backend/bc250_control/backend.py` 1886–1980, 2463–2582. Baseline overview pages plot/show only clocks and CPU/GPU temperature. **P:** four additional nullable telemetry scalars (CPU/GPU voltage and power) plus `sensors[]`, with honest units, labels, provenance, and unsupported values. Exact final names/schema and all frontend implementations are **TBD** by the owning agents.

Required interpretation rules:

- Missing, unreadable, unrecognized, stale, or untrusted sensors are **unavailable/null**, never fabricated zero or a configuration fallback. A zero raw value can still be shown in an explicitly labeled raw inventory without promoting it to a reliable primary metric.
- Prefer positively identified sensor labels/devices. Do not blindly promote first `in*`/`power*`, motherboard CPU labels, or plausible-looking numbers to CPU/GPU primary readings.
- Separate **decoder installed/compatible**, **service enabled**, **service outcome**, and **runtime decoder selection**. Eight-core topology alone says none of these. Do not patch firmware, enable metrics, or start privileged helper reads from a passive telemetry poll.
- Generic hwmon inventory and the experimental eight-chip GDDR6 payload are different capabilities. Firmware “read” commands still involve active SMU mailbox transactions; passive file reads are not equivalent.
- Display source identity (device, label, path/channel, unit), and clear stale last-success values when the source disappears or becomes incompatible. Histories should have gaps, not zero-valued invented samples.

### Passive observation of this audit host (2026-10-21)

Read-only `/sys/class/hwmon` and DRM file sampling, kernel `7.2.7-valve1-1-neptune-72-gc8730d37f9c6`; **one transient sample, not a shipped support guarantee**:

| Observed source | Raw sample | Honest interpretation |
| --- | --- | --- |
| `hwmon1 k10temp/temp1`, label `Tctl` | 45875 | 45.875 °C CPU Tctl; rounded display may differ. |
| `hwmon2 amdgpu/temp1`, label `edge` | 43000 | 43 °C GPU edge, **not** GDDR6 or junction. |
| `hwmon2 amdgpu/in0`, `vddgfx` | 699 | 699 mV / 0.699 V graphics rail. |
| `hwmon2 amdgpu/in1`, `vddnb` | 1137 | 1137 mV northbridge/SoC-labeled rail; **not attested CPU Vcore**. |
| `hwmon2 amdgpu/power1_input` / `_average`, label `PPT` | 34981000 / 36305000 | 34.981 W input / 36.305 W average **PPT**, not proven GPU-only or CPU-only power. |
| `hwmon3 nct6686/temp1–3`, `CPU/System/VRM MOS` | 45000 / 40000 / 39500 | Three board temperature channels; labels retain their provenance. Several other channels returned zero. |
| `hwmon3 nct6686/in4`, `CPU Vcore` | 0 | Not a trustworthy live CPU voltage measurement on this sample. Most board voltage channels also returned zero. |
| `hwmon3 nct6686/fan2`, `Pump Fan` | 1666 | One readable 1666 RPM channel; other fan channels were zero. |
| `hwmon0 nvme/temp1`, `Composite` | 37850 | 37.85 °C storage temperature, suitable for generic inventory, not CPU/GPU primary temperature. |
| DRM `card0/device/pp_dpm_sclk` | `350Mhz *`, 1500, 2230 | Active 350 MHz at observation, distinct from curve maximum/cap. |

No trustworthy CPU power or CPU Vcore source was established by this passive scan. No live SMU CPU-voltage query, GDDR6 attested read, metrics injection, or service activation was attempted. `hwmonN` indices are runtime-local and must not be hard-coded.

## Implemented transport, telemetry and catalog contracts

- `GetTelemetry` retains the original four scalar fields and adds
  `sensors[{key,device,label,value,unit}]`; snapshots add `power.sensors`. No new
  invented voltage/power scalars or implicit SMU activation were added. Polling
  does not take the mutation flock. Zero/null and sensor-role regressions are tested.
- `cpuUnlockStatus.metrics` reports installed decoder compatibility, service and
  revision, **not freshly attested live firmware activation**. Typed actions add
  `metrics-enable`, full `uninstall`, and CPU OC `update`. GPU curve arguments are
  `GpuVoltageAction(siii)`; offset uses the signed voltage argument, unused
  integer placeholders are zero. `ResetGpuRamp()` restores the exact CLI defaults.
- Trusted helper checks, polkit, operation ownership, bounded inputs and
  rollback are retained. GPU CLI transactions take their own common flock rather
  than deadlocking under a nested backend flock. Helper bundles now include the
  full production `core-unlock/smu-metrics` payload, not untracked research files.
- `GetCliCatalog` / `OpenCliSection(s)` accept only fixed section IDs. Terminals
  are fixed `/usr/bin/konsole` or `/usr/bin/xterm`, launched through the requesting
  non-root user's systemd session. Launch success means handoff, not completion.
- The catalog has **27 fixed sections**: `menu`, `status`, `setup`,
  `toolkit-update`, `core`, `graphics`, `devices`, `maintenance`, `amdgpu-boot`,
  `drivers`, `unlocks`, `storage-updates`, `interfaces`, `power`, `ram`, `swap`,
  `compute`, `cpu-unlock`, `cec`, `storage`, `persistence`, `wifi-backend`,
  `memory-temperature`, `radv`, `video-codec`, `proton`, `manage`.
- Public dispatch/help now expose `core`, `graphics`, `devices`, `maintenance`
  and `amdgpu-boot`. Removal/purge (`manage`) is labeled separately from toolkit
  update. The global graphics plan explicitly warns about retired R2 cleanup.
- The read-only CLI `frontend-capabilities-json` probe supplies source version
  and supported sections; malformed/legacy probes offer only `menu`/`status`.
  Unknown future well-formed sections are ignored, not executed.
- Installed API support is independently advertised by
  `snapshot.toolkit.controlApiVersion` and `controlCapabilities`; Trainer also
  introspects optional D-Bus methods. New controls disable on older services.
  Source version does not certify the UI binary or installed hardware state.
- Load-target bounds now agree at 5–99% across the CLI and all three interfaces.
  CMOS summaries explicitly identify the last requested value, not a verified
  current readback. The metrics checksum worker uses the existing Python 3.8-
  compatible executor API rather than the newer `asyncio.to_thread`.
- Trainer Flatpak handoffs remain blocked in the native bridge and its manifest
  permissions are unchanged. No unchecked root or host-command fallback exists.

## Trainer lifecycle, bootstrap, and installed capability gaps

### P1: main toolkit version is not Trainer binary version

- `.github/workflows/release-artifacts.yml` triggers on `v*`, packages toolkit/Decky/Plasma, and copies only Trainer installer/bootstrap scripts into the main toolkit artifact. It has no Trainer CMake build/package step.
- `.github/workflows/trainer-release.yml` triggers only on annotated `trainer-vMAJOR.MINOR.PATCH` tags on master ancestry; it builds/tests native and Flatpak artifacts and publishes a separate prerelease.
- `trainer/install-release.py` selects the highest semantic `trainer-v*` release (including prereleases), validates expected asset URLs/sizes/checksums, and installs that artifact. “Latest Trainer” therefore need not contain changes in the latest `v*` toolkit.
- `ToolkitController::installUpdate` invokes embedded `scripts/toolkit-update.py` for the **toolkit directory**. `restartApplication` uses `QCoreApplication::applicationFilePath()`; it restarts the same installed binary. It does not compile/install the new QML/C++ UI or automatically refresh every installed root service payload.
- `trainer/install.sh::find_binary` prioritizes `trainer/bc250-trainer`, then build directories, but does not attest source revision/capabilities. A stale local executable can be reinstalled even with a newer checkout. This audit did not assert the version/capabilities of the pre-existing untracked executable or the user's installed binary.

**Parent action:** keep toolkit/UI/service versions separate in status and release notes; test the new Trainer build and installer. A separate Trainer release or explicit local build/install is required to deliver its new features. Source edits alone are not remediation of a stale installed executable. Publishing/tagging needs separate user authorization.

### P1: missing-toolkit bootstrap is not supplied by native release installation

- `scripts/stage-trainer-runtime.py::copy_host_runtime` stages selected trusted service/helpers, not the complete toolkit launcher/CEC/maintenance/menus/source tree. The installer installs the user app and shared service; it does not populate the canonical full checkout.
- `ToolkitController::validateToolkit` requires an existing user-owned regular `bc250-toolkit.sh`; inventory requires working `inventory-json`. Missing-checkout state disables the dashboard. `checkForUpdates` also requires `m_available`; updater `read_current_version` requires an existing safe directory, launcher and `VERSION`.
- Consequently “install latest toolkit” cannot bootstrap a missing checkout through that existing update path. Native CEC still depends on a discoverable user-side CEC helper; installing a service payload does not automatically make all CLI sections available.
- Any future bootstrap must be a **separate explicit user-level verified download/install action**, honor safe destination ownership/atomicity, and avoid root execution of a user checkout. This audit does not add it. Flatpak restrictions remain unchanged.

### Cross-version negotiation implemented; lifecycle limits remain

- `snapshot.toolkit.available` checks a small subset of script presence; `ToolkitController` validation checks launcher ownership, inventory schema 1, and a syntactically valid `VERSION`, not that every allowlisted action/section exists.
- A newer UI with an older checkout can show a card whose action is unknown; a newer checkout with an old UI can omit supported features. “Latest toolkit” only describes the independently selected main release, not all installed component binaries/payloads.
- The new CLI catalog negotiates supported source routes, and the installed backend has a separate versioned API manifest. Trainer additionally introspects optional D-Bus methods; new action strings require service-reported availability or a capability gate. Missing sensors remain unavailable rather than fabricated. These resolve the new-controls negotiation gap, not binary delivery or every pre-existing Trainer PTY card's compatibility with historical checkouts.

## Validation ledger

| Validation | Working-tree result |
| --- | --- |
| Baseline commit and `VERSION` | **PASS:** HEAD at audit start was `a751f30`; committed `VERSION` was `v0.35.0`. |
| Canonical graph regeneration check | **PASS:** `PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate-menus.py --check`, exit 0. No generated writes. |
| Graph structural/depth check | **PASS:** `PYTHONDONTWRITEBYTECODE=1 python3 scripts/analyze-menu-graph.py --check --depth-budget 3`, exit 0; 10 targets, 43 menus, 235 selectable nodes, 253 navigation links, 9 dependency links; no cycles/depth violations. Explicit compatibility entries are intentionally not all reachable from their component root. |
| Passive sensor/source observation | **DONE:** direct sysfs reads only; observations and limitations recorded above. |
| Full integration regression suite | **PASS: 640 tests run, 2 skipped**, no failures, after final Python-compatibility and CMOS-label fixes (`python3 -m unittest discover -s tests -p 'test_*.py'`). Hardware-looking output comes from mocked transports and temporary fixtures, not live firmware writes. |
| Release metadata/workflow follow-up | **PASS: 83 focused tests** after the `v0.36.0` version bump and release-workflow updates; Decky parity checks also rerun (19 passed). The toolkit artifact now includes this audit, and both release workflows run the Decky parity checks. |
| Backend API/sensors/transactions/payloads | **PASS: 162 tests**, including missing/zero/nonfinite readings, primary device roles, lock-free polling, flock/cancellation, helper trust, metrics decoder and orphan-uninstall readiness, capability negotiation and staged Decky imports. |
| Service API/schema/authorization | **PASS: 58 tests**, including exact wire signatures, polkit and operation contracts. |
| Trainer native C++/QML | **PASS: all 5 CTest targets** after Release rebuild under Qt 6.4.2 in the existing Ubuntu Distrobox; bridge/media/toolkit/QML/startup. QML lint target exits 0 with informational type/import diagnostics under existing configuration, not diagnostic-free. |
| Plasma | **PASS: 5 tests**, including production JS, method validation, confirmation/source checks and offscreen wide/narrow all-tab mock smoke on host Qt 6. No live Plasma/service qualification. |
| Decky | **PASS: 19 JS tests**, isolated TypeScript check and Rollup build; missing/partial installed manifests tested. No live Steam/controller qualification. |
| Cross-frontend transport/removal/catalog contracts | **PASS: 8 tests**; source catalog and both native allowlists match all 27 public routes; full-removal scope and CMOS request labels checked. |
| CLI exact domain routes/source capability probe | **PASS: 3 tests**, including extra-argument rejection. Backend tests reject malicious IDs and root/invalid users; real desktop session, terminal focus and sudo/polkit interaction remain **NOT RUN**. |
| Old service / old CLI / missing sensors / missing helpers | **PASS in mocked/source regressions**: optional APIs disable, legacy CLI uses menu/status only, unknown sections never execute, missing/null readings are not invented. Not an installed historical-release compatibility matrix. |
| Packaging/lifecycle | **PASS: 14 release tests** plus backend Decky reproducibility/import/bootstrap/payload tests. Fresh isolated archives were also staged from the newly compiled Trainer binary and Decky bundle; backend/bootstrap imports, every required helper payload and staged Trainer mock startup passed. Native/Plasma archives contain `parity.py` and metrics helpers; GUI-only Flatpak permissions unchanged. No actual Flatpak bundle build or installation performed. |
| Real hardware writes, OC/unlock, metrics activation, GDDR6 payload reads/restore, fan/network/CEC effects | **NOT RUN**, requires separately authorized hardware validation. |
| Published release versions / installed binary freshness | **NOT CHECKED online**; lifecycle conclusions are source-derived, not a claim about current GitHub assets or a specific installed executable. |

The implementation matrix above supersedes historical **P** items. These results
describe the release source against the stated baseline, not qualification of an
installed artifact. A CLI handoff closes access gaps; it does not make all CLI
capabilities native UI controls. New Trainer UI still needs a separate build/
installation or authorized Trainer release, and service changes need an updated
frontend/service installation.
