# bc250-steamos

Scripts and drivers for running SteamOS 3.8.x on the ASRock BC-250 board.

Everything installs to update-proof locations (`/etc` and the real user's
`~/.local/share/bc250-fixes/bc250-steamos` toolkit directory) where
possible — SteamOS updates wipe `/usr` (including `/usr/local` and pacman
packages) but leave those alone.

Both setup scripts open a **guided interactive menu** when run with no
arguments in a terminal (pure bash — arrow keys, live per-step state badges,
color output; `q` backs out). Every menu action maps to a plain CLI command,
so scripting/SSH use is unchanged.

## Contents

### `bc250-40cu.sh`
All-in-one 40 CU unlock via the runtime UMR route. Installs the umr binary,
ASIC database, and a manager script under the hidden toolkit directory, plus
a systemd unit and boot table config in `/etc`.
Existing `/var/lib/bc250-40cu` data is migrated automatically; a tiny
compatibility symlink preserves old Steam launch options without retaining
artifacts on the `/var` partition.

### `bc250-cu-status.sh`
Read-only CU dispatch report (e.g. `38/40`). No writes, safe to run any time.
`-q` prints just the total.

### `bc250-power.sh`
Complete power-management setup:
- **ACPI fix** (SSDT-CST/SSDT-PST early-initrd override) — the BC-250 BIOS
  ships no CPU power tables, so without this the cores never idle and cpufreq
  scaling (800–3200 MHz) doesn't exist.
- **GPU governor** (cyan-skillfish-governor, SMU variant) — dynamic
  freq/voltage; without it the GPU is locked at 1500 MHz and idles hot.
- **GPU freq persistence** — `freq` settings (pin/range/max) are saved and
  replayed at boot by a `bc250-gpu-freq-restore` service; `freq auto` clears.
- **GPU voltage control** (`gpu-volt`) — show/offset/set/reset the governor's
  safe-points voltage curve with enforced 700–1050 mV bounds; restarts the
  governor and reapplies the saved freq setting.
- **GPU load targets** (`load-target`) — the busy% band that decides when the
  governor clocks up/down. `eager` preset (0.60/0.45) for light or frame-capped
  games that never generate enough load to leave idle clocks; saved to
  config.toml and applied live over D-Bus without a restart.
- **GPU ramp tuning** (`ramp`) — takes one number (idle-to-max climb time in
  ms) and derives step size, control interval, and down-events from the
  no-hunting formula (a step above `f_min × (upper−lower)/upper` can oscillate
  at steady load); requested climb time is auto-extended if it can't be met
  smoothly at the current load-target band.
- **CPU overclock/undervolt** (`cpu-oc`, wraps
  [bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc)) — max
  boost clock + vid-curve scaling via SMU. Sources are fetched at a pinned
  upstream commit with local patches overlaid from `smu-oc-patches/` (no
  clone, pip, or git needed); the boot unit is ordered before the GPU
  governor because both share the SMU indirect window.

### `smu-oc-patches/`
Overlay files + diffs applied on top of the pinned `bc250_smu_oc` fetch:
transaction-level flock (SMU window race vs the running GPU governor) and a
Python-native stress fallback (stock SteamOS ships no `stress`). See its
README for the pin-bump procedure.

### `bc250-audio-fix/`
Patched `amdgpu.ko` fixing DisplayPort output running at ~82% speed — video
and audio both, since every DP DTO (pixel and audio clock) was skewed.
The BC-250's DCN 2.0.1 display block gets handed the dcn3 clock manager with a
wrong hardcoded 730 MHz DP reference clock (real: 600 MHz), so the whole DP
output ran at 600/730 of the requested rate.
Two-hunk kernel patch, prebuilt module, and an installer with
vermagic + real ABI guards. See `bc250-audio-fix/README.md` — including the
build-environment trap (missing pahole silently breaking kernel ABI) that
matters for anyone rebuilding kernel modules for SteamOS.

Kernel-release-specific: rebuild after each SteamOS update (instructions in
the subdirectory README).

### `bc250-cec.sh`
HDMI-CEC / TV control through a CEC-tunneling DP→HDMI adapter. Far less
greenfield than expected: the kernel already ships `DRM_DISPLAY_DP_AUX_CEC`
(so amdgpu exposes `/dev/cec0` on the DP AUX channel) and Valve's `cecd`
daemon (D-Bus `com.steampowered.CecDaemon1`, CLI `cectool`) already wakes
the TV on resume, suspends the console when the TV turns off, and relays
the TV remote as an input device. The script configures cecd and fills its
gaps:
- **OSD name** — "BC-250" instead of "steamdeck" in the TV's device list.
- **Behavior toggles** (TV standby on suspend, etc.) written to
  `~/.config/cecd/config.d/99-zz-bc250.toml`, which sorts after — and
  therefore outranks — Steam UI's `99-steamos-manager.toml` (verified;
  `clear-overrides` hands control back).
- **TV + receiver standby on poweroff** — system unit, ExecStop gated on
  the poweroff/halt goal target so reboot and suspend are excluded; uses
  root `cec-ctl`, no user-session coupling.
- **TV wake at cold boot** — user unit calling cecd's D-Bus `Wake` with
  retries, then claiming active source.
- **Receiver power** — `amp-on` sends `<System Audio Mode Request>`, the
  CEC-standard "amplifier, wake up and take the audio" command (verified
  against a Yamaha RX-V381); `amp-off` sends it standby.
- **Receiver follows the console** — `amp-follow {boot|poweroff|suspend|
  resume}` toggles make the receiver's power track the console (poweroff
  is on by default, the rest opt-in). Flags live in
  `~/.config/bc250-cec.conf` and are read by the generated helpers at
  runtime, so flipping never needs a unit reinstall; suspend/resume need
  the one-time `amp-sleep install` hook (`/etc/systemd/system-sleep/`,
  resume side retries in the background while the DP link renegotiates).
- **Multi-device etiquette** — for setups where several sources share one
  receiver and fight over the input (all verified live against an Apple TV
  behind the same RX-V381):
  - `active` — ask the bus who holds the input before touching anything;
  - `handoff <dev>` — route the TV/receiver to another device (wakes it
    first: devices ignore `<Set Stream Path>` while in standby);
  - `release` — `<Inactive Source>`, give up the input and let the TV pick;
  - both installed units are **polite by default**: boot-wake won't steal
    the input if another device is actively showing (`install grab`
    restores the old behavior), and poweroff-standby leaves the TV +
    receiver on when someone else holds the input.
- `status`/`test`/`scan`/`monitor`/`remote` tooling and one-shot verbs
  (`tv-on`, `tv-off [hard]`, `amp-on`, `amp-off`, `switch`,
  `vol-up`/`vol-down`/`mute`). `scan` renders the HDMI tree from physical
  addresses — who's plugged into which receiver input — with vendor, power
  state, and the active source marked.
- **`repair`** — for "CEC stopped responding", typically after suspend:
  some DP→HDMI adapters silently lose their CEC registration across sleep
  (a failure mode reported in the field on TCL Roku + DP-adapter setups),
  and a receiver's standby-passthrough drops `/dev/cec0` for ~20 s. Health
  check, then a cecd restart to re-claim the logical address — the
  cecd-safe equivalent of `cec-ctl --clear` + `--playback`, which repair
  only uses raw when cecd is off (clearing a live cecd's address would
  break it). `tv-off hard` sends the remote's discrete power-off key for
  TVs that bounce back out of `<Standby>` (TCL Roku class).

Runs as **deck, not root** (cecd lives on the user D-Bus session); only the
poweroff unit install sudos, by itself. Adapter caveat: CEC over DP only
works if the adapter implements CEC-Tunneling-over-AUX — most don't (known
good: Club3D CAC-1080/1085 and other Parade PS176/PS186 designs). Debug
notes (power-status reply parsing, `busctl -- -1`, monitor needs sudo) are
in the script header and `help`.

### `aic8800/`
Working driver for AIC8800D80-based USB WiFi/BT dongles (the ones that boot
as a fake `1111:1111` mass-storage device). Based on radxa-pkg/aic8800 with
local SteamOS fixes. WiFi and Bluetooth both work.

Setup / rebuild after a SteamOS update:

```
sudo bash aic8800/steamdeck-setup.sh
```

The script unlocks the rootfs, installs build tools, fetches matching kernel
headers into the repo, builds and installs the modules, writes the
usb_modeswitch/udev/modprobe configs to `/etc`, relocks the rootfs, and
switches the dongle into WiFi mode. The `/etc` configs survive updates; the
build/install steps must be re-run after each SteamOS update.

Note: firmware is loaded at module-load time straight from this checkout
(`aic8800/src/USB/driver_fw/fw/aic8800D80`), so keep the repo where
`/etc/modprobe.d/aic8800.conf` points.
