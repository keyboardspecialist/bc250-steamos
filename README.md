# bc250-steamos

Management tools for SteamOS 3.8.x and 3.9.x.

## Install

```bash
mkdir -p ~/.local/share/bc250-fixes
git clone https://github.com/keyboardspecialist/bc250-steamos.git \
  ~/.local/share/bc250-fixes/bc250-steamos
cd ~/.local/share/bc250-fixes/bc250-steamos
```

## Tools

| Tool | Purpose |
|---|---|
| [`bc250-40cu.sh`](#compute-units) | Runtime 40 CU configuration and boot persistence |
| [`bc250-cu-status.sh`](#compute-units) | CU dispatch status |
| [`bc250-power.sh`](#power-management) | CPU power states, GPU governor, clock and voltage tuning, CPU overclocking |
| [`bc250-cec.sh`](#cec) | TV, receiver, input, and power control over HDMI-CEC |
| [`bc250-audio-fix/`](#display-clock) | DisplayPort video and audio clock correction |
| [`aic8800/`](#wifi-and-bluetooth) | AIC8800D80 USB WiFi and Bluetooth driver |

`bc250-40cu.sh`, `bc250-power.sh`, and `bc250-cec.sh` open an interactive menu when launched in a terminal. Each also provides a command interface through `<script> help`.

## Compute Units

Open the setup menu:

```bash
sudo ./bc250-40cu.sh
```

| Command | Action |
|---|---|
| `sudo ./bc250-40cu.sh check` | Show board, debugfs, UMR, and service state |
| `sudo ./bc250-40cu.sh prep` | Build and install UMR |
| `sudo ./bc250-40cu.sh manager` | Open the live CU manager |
| `sudo ./bc250-40cu.sh persist` | Install the boot-persistent manager |
| `sudo ./bc250-40cu.sh verify` | Verify registers and service state |
| `sudo ./bc250-40cu.sh revert` | Restore the 24 CU dispatch state at the next boot |

Review the harvest map in the live manager before selecting a dispatch layout. Prefer selective routing for scattered harvest patterns.

CU status:

```bash
sudo ./bc250-cu-status.sh
sudo ./bc250-cu-status.sh -q
```

## Power Management

Open the setup and tuning menu:

```bash
sudo ./bc250-power.sh
```

### Setup

| Command | Action |
|---|---|
| `sudo ./bc250-power.sh acpi` | Install CPU C-states and 800-3200 MHz P-states |
| `sudo ./bc250-power.sh governor` | Install and start the adaptive GPU governor |
| `sudo ./bc250-power.sh enable` | Enable the GPU governor and CPU frequency policy at boot |
| `sudo ./bc250-power.sh all` | Install the ACPI tables and GPU governor |
| `sudo ./bc250-power.sh status` | Show clocks, power states, temperatures, and services |

Reboot after installing the ACPI tables.

### GPU Tuning

```bash
sudo ./bc250-power.sh freq status
sudo ./bc250-power.sh freq 1800
sudo ./bc250-power.sh freq 0 2000
sudo ./bc250-power.sh freq auto

sudo ./bc250-power.sh gpu-volt show
sudo ./bc250-power.sh gpu-volt offset -25
sudo ./bc250-power.sh gpu-volt set 2000 985
sudo ./bc250-power.sh gpu-volt reset

sudo ./bc250-power.sh load-target eager
sudo ./bc250-power.sh load-target set 70 55
sudo ./bc250-power.sh load-target reset

sudo ./bc250-power.sh ramp set 500
sudo ./bc250-power.sh ramp reset
```

Frequency, voltage, load-target, and ramp settings persist across boots. GPU voltage points use a 700-1050 mV range.

### CPU Tuning

```bash
sudo ./bc250-power.sh cpu-oc detect 4000 1275
sudo ./bc250-power.sh cpu-oc enable
sudo ./bc250-power.sh cpu-oc status
sudo ./bc250-power.sh cpu-oc apply
sudo ./bc250-power.sh cpu-oc off
```

`cpu-oc detect` stress-tests each frequency step. Keep the VID limit at or below 1325 mV.

## CEC

Run CEC commands from the logged-in user session:

```bash
./bc250-cec.sh
./bc250-cec.sh setup
```

CEC requires a DP-to-HDMI adapter with CEC tunneling over AUX. Compatible designs include Club3D CAC-1080/CAC-1085 and Parade PS176/PS186 adapters.

| Command | Action |
|---|---|
| `./bc250-cec.sh status` | Show adapter, daemon, bus, TV, and service state |
| `./bc250-cec.sh scan` | Show the HDMI device tree and active source |
| `./bc250-cec.sh tv-on` | Wake the TV and select this input |
| `./bc250-cec.sh tv-off` | Put the TV in standby |
| `./bc250-cec.sh amp-on` | Wake the receiver and enable system audio |
| `./bc250-cec.sh amp-off` | Put the receiver in standby |
| `./bc250-cec.sh vol-up` | Raise receiver volume |
| `./bc250-cec.sh vol-down` | Lower receiver volume |
| `./bc250-cec.sh mute` | Toggle receiver mute |
| `./bc250-cec.sh active` | Show the active source |
| `./bc250-cec.sh handoff` | Select another CEC source |
| `./bc250-cec.sh release` | Release active-source ownership |
| `./bc250-cec.sh repair` | Re-register CEC after a link interruption |

Use `./bc250-cec.sh help` for boot, suspend, poweroff, receiver-follow, and behavior-toggle commands.

## AMDGPU Driver

Build and install the matching `amdgpu` module:

```bash
cd bc250-audio-fix
./patch-driver.sh
```

The patch restores the DisplayPort pixel and audio reference clock. Builds are matched to the running kernel and checked for vermagic and ABI compatibility before installation.

Rollback:

```bash
sudo ./rollback.sh
```

See [`bc250-audio-fix/README.md`](bc250-audio-fix/README.md) for kernel support, build controls, and clock-gating options.

## AIC8800 Class WiFi and Bluetooth Driver

Install the AIC8800D80 USB modules and firmware configuration:

```bash
sudo bash aic8800/steamdeck-setup.sh
```

Keep this checkout at `~/.local/share/bc250-fixes/bc250-steamos` so the module configuration can resolve its firmware path.

## SteamOS Updates

| Component | Update action |
|---|---|
| Compute-unit manager | Run `sudo ./bc250-40cu.sh verify` after a major SteamOS release |
| Power management | The installed services restore persistent configuration at boot |
| Display clock module | Run `bc250-audio-fix/patch-driver.sh` after each kernel update |
| AIC8800 modules | Run `sudo bash aic8800/steamdeck-setup.sh` after each kernel update |

Configuration and service files live under `/etc` and the user home directory.

## References

| Project | Resources | Used by |
|---|---|---|
| BC-250 CU Live Manager | [Repository](https://github.com/WinnieLV/bc250-cu-live-manager) · [Script](https://github.com/WinnieLV/bc250-cu-live-manager/blob/main/bc250-cu-live-manager.sh) | `bc250-40cu.sh` |
| UMR | [Repository](https://gitlab.freedesktop.org/tomstdenis/umr) | `bc250-40cu.sh`, `bc250-cu-status.sh` |
| BC-250 ACPI Fix | [Repository](https://github.com/bc250-collective/bc250-acpi-fix) · [SSDT-CST](https://github.com/bc250-collective/bc250-acpi-fix/blob/main/SSDT-CST.aml) · [SSDT-PST](https://github.com/bc250-collective/bc250-acpi-fix/blob/main/SSDT-PST.aml) | `bc250-power.sh` |
| Cyan Skillfish Governor | [Repository](https://github.com/filippor/cyan-skillfish-governor/tree/smu) · [Performance-mode script](https://github.com/filippor/cyan-skillfish-governor/blob/smu/scripts/cyan-skillfish-performance-mode) | `bc250-power.sh` |
| BC-250 SMU OC | [Repository](https://github.com/bc250-collective/bc250_smu_oc) | `bc250-power.sh` |
| Valve kernel mirror | [Repository](https://github.com/Evlav/linux-integration) | `bc250-audio-fix/fetch-sources.sh` |
| SteamOS package mirror | [Package index](https://steamdeck-packages.steamos.cloud/archlinux-mirror/) | Audio-driver and AIC8800 build scripts |
| AIC8800 | [Repository](https://github.com/radxa-pkg/aic8800) | `aic8800/steamdeck-setup.sh` |
