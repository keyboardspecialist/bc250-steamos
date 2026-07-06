# bc250-steamos

Scripts and drivers for running SteamOS 3.8.x on the ASRock BC-250 board.

Everything installs to update-proof locations (`/etc`, `/var`, `/home`) where
possible — SteamOS updates wipe `/usr` (including `/usr/local` and pacman
packages) but leave those alone.

## Contents

### `bc250-40cu-steamos-v2.sh`
All-in-one 40 CU unlock via the runtime UMR route. Installs the umr binary,
ASIC database, and a manager script to `/var/lib/bc250-40cu`, plus a systemd
unit and boot table config in `/etc`.

### `bc250-cu-status.sh`
Read-only CU dispatch report (e.g. `38/40`). No writes, safe to run any time.
`-q` prints just the total.

### `bc250-power-steamos-v3.sh`
Complete power-management setup:
- **ACPI fix** (SSDT-CST/SSDT-PST early-initrd override) — the BC-250 BIOS
  ships no CPU power tables, so without this the cores never idle and cpufreq
  scaling (800–3200 MHz) doesn't exist.
- **GPU governor** (cyan-skillfish-governor, SMU variant) — dynamic
  freq/voltage; without it the GPU is locked at 1500 MHz and idles hot.

### `bc250-audio-fix/`
Patched `amdgpu.ko` fixing DisplayPort audio speed/pitch (and A/V sync drift).
The BC-250's DCN 2.0.1 display block gets handed the dcn3 clock manager with a
wrong hardcoded 730 MHz DP reference clock (real: 600 MHz), so audio ran at
~82% speed. Two-hunk kernel patch, prebuilt module, and an installer with
vermagic + real ABI guards. See `bc250-audio-fix/README.md` — including the
build-environment trap (missing pahole silently breaking kernel ABI) that
matters for anyone rebuilding kernel modules for SteamOS.

Kernel-release-specific: rebuild after each SteamOS update (instructions in
the subdirectory README).

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
