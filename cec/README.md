# bc250-cec.sh — HDMI-CEC / TV control

TV control from the BC-250 over HDMI-CEC: wake the TV, switch its input,
put it in standby with the console, volume on a soundbar/AVR, and use the
TV remote as an input device.

## TL;DR — most of it already works

This turned out to be far less greenfield than expected. On SteamOS 3.8
with the valve 6.16 kernel:

- **Kernel**: `CONFIG_DRM_DISPLAY_DP_AUX_CEC=y` (the modern rename of
  `CONFIG_DRM_DP_CEC`) is already enabled, so amdgpu exposes `/dev/cec0`
  on the DP AUX channel. amdgpu has had DP CEC-tunneling support since
  kernel 4.20. No kernel or module work needed.
- **Adapter**: CEC over DisplayPort only works if the active DP→HDMI
  adapter implements *CEC-Tunneling-over-AUX* — **most don't** (known
  good: Club3D CAC-1080/1085 and other Parade PS176/PS186 designs). If
  `/dev/cec0` never appears with the adapter plugged in, the adapter is
  the problem. Ours tunnels it.
- **Daemon**: Valve ships **cecd** in the OS image (user service, D-Bus
  `com.steampowered.CecDaemon1`, CLI `cectool`). Out of the box it:
  wakes the TV on resume (`wake_tv`), suspends the console when the TV
  turns off (`allow_standby`), and relays the TV remote as a uinput
  input device (`uinput`) that drives gamescope directly.

## What the script adds

| Gap | Fix |
|---|---|
| TV device list says "steamdeck" | `osd-name` → "BC-250" |
| No TV standby when console *suspends* | `toggle suspend-tv on` (cecd has it, default off) |
| Nothing at all on *poweroff* | `shutdown-standby install` — system unit, fires only on poweroff (not reboot/suspend) |
| Nothing at *cold boot* | `boot-wake install` — user unit, wakes TV + grabs input at session start |
| No visibility/tooling | `status`, `test`, `monitor`, `remote`, and one-shot verbs (`tv-on`, `tv-off`, `switch`, `vol-up/down`, `mute`) |

Run `./bc250-cec.sh` in a terminal for the guided menu, or
`./bc250-cec.sh setup` for the recommended one-shot. Run **as deck, not
root** — cecd lives on the user D-Bus session; only the poweroff unit
install escalates via sudo by itself.

## Config ownership (important)

cecd merges TOML fragments from `~/.config/cecd/config.d/` in filename
order, later files winning per key:

- `99-steamos-manager.toml` — written **and periodically rewritten** by
  Steam's own UI. Never edit it.
- `50-bc250.toml` (ours) — `osd_name` only.
- `99-zz-bc250.toml` (ours) — behavior overrides; sorts after Steam's
  file so it wins (verified live). While a key is overridden here, the
  Steam UI toggle for it has no effect — `clear-overrides` hands control
  back.

## Update resilience

User config + user unit live in `$HOME`, the system unit in `/etc`
(writable overlay) — all survive SteamOS updates. Nothing is installed
to `/usr` or `/boot`; cecd itself is part of the OS image.

## Debug notes (hard-won details)

- TV power status over D-Bus: `SendReceiveRawMessage ayyyq 1 143 0 144 1000`
  — reply *includes* the opcode (`ay 2 144 0`), the status is the **last**
  byte: 0=on 1=standby 2=standby→on 3=on→standby.
- `busctl` needs `--` before negative args: `SetActiveSource i -- -1`.
- `cectool monitor` needs CAP_NET_ADMIN (sudo); rootless alternative:
  `busctl --user monitor com.steampowered.CecDaemon1`.
- cecd's `-e` (exclusive) does **not** block other transmitters: a root
  `cec-ctl -s -d /dev/cec0 --to 0 --standby` works alongside it — that's
  what the poweroff unit uses, with zero user-session coupling.
- cecd's user unit shows `disabled` in `is-enabled` but is statically
  wanted by `graphical-session.target` — that's normal, not a problem.
