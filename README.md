# Yet Another SteamOS Toolkit

BC-250 system management tools for SteamOS.

## Contents

- [Install](#install)
- [Update](#update)
- [Start](#start)
- [Toolkit commands](#toolkit-commands)
- [Core system](#core-system)
- [Power and thermals](#power-and-thermals)
- [Hardware unlocks](#hardware-unlocks)
- [Graphics and gaming](#graphics-and-gaming)
- [Devices and connectivity](#devices-and-connectivity)
- [Control interfaces](#control-interfaces)
- [SteamOS update recovery](#steamos-update-recovery)
- [Remove components](#remove-components)
- [Development](#development)
- [Upstream projects](#upstream-projects)

## Install

Run toolkit commands as the logged-in desktop user. The toolkit requests
administrator authorization for privileged tasks.

### Release package

Download these files from the
[latest release](https://github.com/keyboardspecialist/bc250-steamos/releases/latest):

- `bc250-steamos-toolkit-vX.Y.Z.zip`
- `bc250-steamos-toolkit-vX.Y.Z.zip.sha256`

Verify and extract the package:

```bash
sha256sum -c bc250-steamos-toolkit-vX.Y.Z.zip.sha256
unzip bc250-steamos-toolkit-vX.Y.Z.zip
mkdir -p ~/.local/share/bc250-fixes
mv bc250-steamos ~/.local/share/bc250-fixes/
cd ~/.local/share/bc250-fixes/bc250-steamos
./bc250-toolkit.sh
```

### Source checkout

```bash
mkdir -p ~/.local/share/bc250-fixes
git clone https://github.com/keyboardspecialist/bc250-steamos.git \
  ~/.local/share/bc250-fixes/bc250-steamos
cd ~/.local/share/bc250-fixes/bc250-steamos
./bc250-toolkit.sh
```

## Update

The interactive menu checks for a stable toolkit release at startup. The menu
title shows the installed version and the available version.

Select **Toolkit Update** or run:

```bash
./bc250-toolkit.sh toolkit-update
```

The updater completes these tasks:

1. Read the stable GitHub release metadata.
2. Download the toolkit ZIP and SHA-256 file.
3. Verify the asset URL, size, digest, archive layout, and version.
4. Stage the release in the toolkit parent directory.
5. Replace the current toolkit directory as one transaction.
6. Remove the staging data and the previous directory.
7. Restart the toolkit.

Print update status as JSON:

```bash
./bc250-toolkit.sh toolkit-update-check
```

## Start

Open the main menu:

```bash
./bc250-toolkit.sh
```

For a new system, select **Auto Base Toolkit Installation**. Run the same
action after each requested reboot.

The base workflow completes these stages:

1. Install persistent storage, the power foundation, the memory helper, and
   the AMDGPU kernel fixes.
2. Reboot.
3. Install the Mesa and RADV async-compute runtime.
4. Reboot.
5. Verify the active driver stack and system health.

Configure hardware unlocks, memory allocation, swap, tuning, device drivers,
and control interfaces after the base workflow.

Check the system:

```bash
./bc250-toolkit.sh status
```

## Toolkit commands

| Command | Result |
|---|---|
| `./bc250-toolkit.sh` | Open the main menu |
| `./bc250-toolkit.sh toolkit-update` | Install the latest stable toolkit release |
| `./bc250-toolkit.sh toolkit-update-check` | Print toolkit update status as JSON |
| `./bc250-toolkit.sh setup` | Open the guided setup menu |
| `./bc250-toolkit.sh auto-base-installation` | Install or resume the base workflow |
| `./bc250-toolkit.sh graphics-setup` | Install or resume AMDGPU and RADV setup |
| `./bc250-toolkit.sh status` | Show system health |
| `./bc250-toolkit.sh drivers` | Open driver setup |
| `./bc250-toolkit.sh unlocks` | Open GPU and CPU unlock setup |
| `./bc250-toolkit.sh power` | Open power and thermal controls |
| `./bc250-toolkit.sh ram` | Open RAM and VRAM controls |
| `./bc250-toolkit.sh swap` | Open compressed-swap controls |
| `./bc250-toolkit.sh proton` | Open BC-250 GE-Proton controls |
| `./bc250-toolkit.sh video-codec` | Open VA-API video codec controls |
| `./bc250-toolkit.sh audio-output` | Open HDMI audio controls |
| `./bc250-toolkit.sh memory-temperature` | Open GDDR6 temperature controls |
| `./bc250-toolkit.sh interfaces` | Open frontend installation controls |
| `./bc250-toolkit.sh manage` | Open component removal controls |
| `./bc250-toolkit.sh inventory-json` | Print component state as JSON |
| `./bc250-toolkit.sh help` | Show all commands and operation IDs |

## Core system

### Persistent storage

Toolkit installers create persistent storage when a component requires it.
The root-owned data path is `/var/lib/bc250-control`. SteamOS stores its backing
data under `/home/.steamos/offload/var/lib/bc250-control`.

| Command | Result |
|---|---|
| `./bc250-storage.sh` | Open the storage menu |
| `sudo ./bc250-storage.sh status` | Verify the mount and recovery service |
| `sudo ./bc250-storage.sh repair` | Repair storage and boot recovery |

Use a separate backup for factory-reset and reimage recovery.

### RAM and VRAM

Open the menu:

```bash
./bc250-toolkit.sh ram
```

| Setting | Function |
|---|---|
| `UMA_SIZE` | Set the minimum VRAM reservation in CMOS |
| `ttm.pages_limit` | Set the dynamic system-memory GPU allocation limit |

Supported UMA values use 16 MiB increments from 256 MiB through 12 GiB.
A reboot activates a new UMA value. Use a CMOS clear to restore the firmware
default.

**CAUTION:** The 2048 MiB UMA value can prevent Linux startup on a BC-250.

| Command | Result |
|---|---|
| `sudo ./bc250-ram-split.sh install` | Install the verified memory utility |
| `sudo ./bc250-ram-split.sh show` | Read the CMOS memory configuration |
| `sudo ./bc250-ram-split.sh set 512 --yes` | Set 512 MiB minimum VRAM |
| `sudo ./bc250-ram-split.sh ttm-set 3014656 --yes` | Set the 11.50 GiB dynamic limit preset |
| `./bc250-ram-split.sh status` | Show UMA and TTM state |

### Compressed swap

Open the menu:

```bash
./bc250-toolkit.sh swap
```

| Profile | Configuration |
|---|---|
| Zram | Half of physical RAM, Zstandard compression, priority 100 |
| Zswap and disk | LZ4 cache, 25% RAM pool, persistent disk swap, priority 10 |

| Command | Result |
|---|---|
| `sudo ./bc250-swap.sh install zram` | Install the zram profile |
| `sudo ./bc250-swap.sh install zswap` | Install a 16 GiB disk-swap profile |
| `sudo ./bc250-swap.sh install zswap 32` | Install a 32 GiB disk-swap profile |
| `./bc250-swap.sh status` | Show the active profile |
| `sudo ./bc250-swap.sh uninstall` | Remove the toolkit profile |

A profile transition can require one reboot and a second run of the command.

## Power and thermals

Open the menu:

```bash
./bc250-toolkit.sh power
```

### Power foundation

| Command | Result |
|---|---|
| `sudo ./bc250-power.sh acpi` | Install CPU C-state and P-state tables |
| `sudo ./bc250-power.sh governor` | Install and start the GPU governor |
| `sudo ./bc250-power.sh enable` | Enable power services at startup |
| `sudo ./bc250-power.sh all` | Install ACPI tables and the GPU governor |
| `sudo ./bc250-power.sh status` | Show power, clock, and thermal state |

Reboot after ACPI installation. Test GPU workloads before you enable the
governor at startup.

### GPU tuning

| Command | Result |
|---|---|
| `sudo ./bc250-power.sh freq 1800` | Set a fixed 1800 MHz clock |
| `sudo ./bc250-power.sh freq 0 2000` | Set a 350-2000 MHz adaptive range |
| `sudo ./bc250-power.sh freq auto` | Restore automatic frequency control |
| `sudo ./bc250-power.sh gpu-volt show` | Show the voltage curve |
| `sudo ./bc250-power.sh gpu-volt offset -25` | Apply a -25 mV curve offset |
| `sudo ./bc250-power.sh load-target set 70 55` | Set upper and lower load targets |
| `sudo ./bc250-power.sh temperature set 80` | Set the thermal target to 80 °C |
| `sudo ./bc250-power.sh ramp set 500` | Set the frequency ramp step |

The toolkit saves frequency, voltage, load, thermal, and ramp settings. The
voltage range is 700-1050 mV. Keep the voltage curve monotonic.

### CPU tuning

| Command | Result |
|---|---|
| `sudo ./bc250-power.sh cpu-oc detect 4000 1275` | Test CPU frequency steps up to 4 GHz and 1275 mV |
| `sudo ./bc250-power.sh cpu-oc enable` | Enable the saved CPU profile at startup |
| `sudo ./bc250-power.sh cpu-oc status` | Show CPU tuning state |
| `sudo ./bc250-power.sh cpu-oc off` | Restore stock CPU settings |
| `sudo ./bc250-power.sh cpu-mitigations disable` | Set `mitigations=off` |
| `sudo ./bc250-power.sh cpu-mitigations enable` | Restore the kernel mitigation policy |

**CAUTION:** CPU detection stress-tests each frequency step. Use a VID limit of
1325 mV or less.

### Fan control

Install the NCT6687 driver:

```bash
./bc250-toolkit.sh fan-driver
```

Supported controllers include NCT6683, NCT6686D, and NCT6687-family devices.
The driver provides fan tachometers and `pwmN` controls.

Set `pwmN_enable` to `2` to select firmware automatic control.

**WARNING:** A PWM value of zero can stop a fan. Use temperature safeguards in
each fan-control application.

Install CoolerControl after the NCT6687 driver:

```bash
./bc250-toolkit.sh coolercontrol
```

Open the local interface at <http://localhost:11987>.

## Hardware unlocks

### GPU compute units

Open the menu:

```bash
./bc250-toolkit.sh unlocks
```

| Command | Result |
|---|---|
| `sudo ./bc250-40cu.sh check` | Show board, debugfs, UMR, and service state |
| `sudo ./bc250-40cu.sh prep` | Build and install UMR |
| `sudo ./bc250-40cu.sh manager` | Open the live CU manager |
| `sudo ./bc250-40cu.sh persist` | Save the selected route for startup |
| `sudo ./bc250-40cu.sh verify` | Verify registers and service state |
| `sudo ./bc250-40cu.sh revert` | Restore 24-CU dispatch at the next startup |
| `sudo ./bc250-cu-status.sh` | Show CU dispatch status |

Review the harvest map before you select a route. Use selective routing for a
scattered harvest pattern. Stress-test the selected route before persistence.

### CPU cores

Install the AMDGPU kernel fixes before the CPU unlock test. Then run:

```bash
sudo ./bc250-power.sh cpu-unlock test
sudo reboot
sudo ./bc250-power.sh cpu-unlock status
```

Stress-test all eight cores. Check `dmesg` for hardware errors. Then select one
startup method:

| Command | Result |
|---|---|
| `sudo ./bc250-power.sh cpu-unlock enable` | Enable the Linux startup method |
| `sudo ./bc250-power.sh cpu-unlock efi-enable` | Enable the EFI startup method |
| `sudo ./bc250-power.sh cpu-unlock metrics-enable` | Enable the eight-core SMU metrics table |
| `sudo ./bc250-power.sh cpu-unlock off` | Stop the active startup method |
| `sudo ./bc250-power.sh cpu-unlock uninstall` | Remove CPU unlock integration |

Use one startup method. A cold power cycle restores the factory six-core mask.

**WARNING:** Disabled cores can have physical defects. An unstable core can
cause a crash, data corruption, or startup failure.

See [`core-unlock/README.md`](core-unlock/README.md) for the Linux and EFI
lifecycles.

## Graphics and gaming

### AMDGPU kernel fixes

Install the module and reboot:

```bash
./bc250-toolkit.sh amdgpu
```

The module supplies GFX1013 compute-queue repair, GPU telemetry, Cyan Skillfish
metrics support, and kernel-specific display and audio corrections.

The installer matches the running kernel. It verifies the module ABI and
`vermagic` before installation.

See [`bc250-audio-fix/README.md`](bc250-audio-fix/README.md) for kernel support,
build controls, and rollback.

### Mesa and RADV async compute

Install the complete graphics stack:

```bash
./bc250-toolkit.sh graphics-setup
```

The workflow uses these checkpoints:

1. Install the AMDGPU kernel fixes.
2. Reboot.
3. Build and install the GFX1013 Mesa and RADV runtime.
4. Configure `amdgpu.sched_policy=2`.
5. Reboot.
6. Verify the active ICD and kernel module.

Open the expert menu:

```bash
./bc250-mesh-shader.sh
```

| Command | Result |
|---|---|
| `./bc250-mesh-shader.sh setup` | Install the global async-compute runtime |
| `./bc250-mesh-shader.sh status` | Verify the global runtime |
| `./bc250-mesh-shader.sh uninstall` | Remove the global runtime |

The global runtime uses the patched 64-bit RADV ICD. SteamOS supplies the
32-bit RADV path.

### VA-API video codec

Install the pinned 64-bit H.264 and HEVC codec release:

```bash
./bc250-toolkit.sh video-codec-install
```

The toolkit downloads the pinned `simpmix/bc250-encoding-decoding-fix`
`v0.5.1` source, verifies it, and builds it against the active SteamOS image.
The runtime provides Vulkan-compute encoding and CPU-backed decoding through
VA-API. The build disables the optional libx264 backend to avoid coupling the
driver to another distribution's libx264 ABI.

Check or remove the runtime:

```bash
./bc250-toolkit.sh video-codec-status
./bc250-toolkit.sh video-codec-remove
```

Sign out or reboot after installation or removal. The toolkit uses persistent
storage and a managed environment file. It does not replace the stock
`radeonsi` driver or enable the upstream Sunshine boot redirect.

See [`video-codec/README.md`](video-codec/README.md) for paths, scope, and
license information.

### BC250 RADV R2

The R2 profile combines its RADV driver, patched vkd3d core, and a private copy
of Proton 11.0-2c.

Install Proton 11.0-2c through Steam. Then run:

```bash
./bc250-mesh-shader.sh setup --native-mesh
```

Restart Steam. Select **BC250 R2 (experimental)** for the game. Add this launch
option:

```text
~/.local/share/bc250-mesh-shader/native-mesh/bc250-r2 %command%
```

Remove the profile:

```bash
./bc250-mesh-shader.sh uninstall --native-mesh
```

**WARNING:** R2 is an experimental profile. Qualify each game before regular
use. A queue-sensitive failure can cause GPU context loss or a system hang.

### Portable FSR4 RC9

Use the portable FSR4 path with a compatible game or OptiScaler target:

```bash
./bc250-mesh-shader.sh setup --fsr4 \
  "/path/to/amd_fidelityfx_upscaler_dx12.dll"
```

Restore the recorded game DLL:

```bash
./bc250-mesh-shader.sh uninstall --fsr4 \
  "/path/to/amd_fidelityfx_upscaler_dx12.dll"
```

For an OptiScaler `winmm.dll` installation, use:

```text
PROTON_FSR4_UPGRADE=0 PROTON_USE_OPTISCALER=0 WINEDLLOVERRIDES="winmm=n,b;amdxcffx64=" %command%
```

Close the game before each file operation. Use FSR4 injection with offline
games. Anti-cheat software can take action against injected DLLs.

### BC-250 GE-Proton

Activate the global FSR4 RADV profile first. Then install BC-250 GE-Proton:

```bash
./bc250-toolkit.sh proton-install
```

Restart Steam. Select **BC-250 GE-Proton** in the game compatibility settings.

| Command | Result |
|---|---|
| `./bc250-toolkit.sh proton-status` | Verify the compatibility tool |
| `./bc250-toolkit.sh proton-update` | Update or repair the compatibility tool |
| `./bc250-toolkit.sh proton-uninstall` | Remove the compatibility tool |

## Devices and connectivity

### HDMI AC-3 audio

Use an AC-3-capable receiver or soundbar. Open **Devices and Connectivity >
HDMI Audio**, or run:

```bash
./hdmi-ac3/hdmi-ac3.sh install
./hdmi-ac3/hdmi-ac3.sh status
./hdmi-ac3/hdmi-ac3.sh revert
```

The installer configures real-time Dolby Digital 5.1 output through ALSA and
WirePlumber.

See [`hdmi-ac3/README.md`](hdmi-ac3/README.md) for the audio-device
requirements.

### HDMI-CEC

Use a DP-to-HDMI adapter that supports CEC tunneling over AUX. Compatible
designs include Club3D CAC-1080, Club3D CAC-1085, Parade PS176, and Parade
PS186.

```bash
./bc250-cec.sh setup
```

| Command | Result |
|---|---|
| `./bc250-cec.sh status` | Show adapter, daemon, bus, TV, and service state |
| `./bc250-cec.sh scan` | Show the CEC device tree |
| `./bc250-cec.sh tv-on` | Wake the TV and select the BC-250 input |
| `./bc250-cec.sh tv-off` | Put the TV in standby |
| `./bc250-cec.sh amp-on` | Wake the receiver and enable system audio |
| `./bc250-cec.sh amp-off` | Put the receiver in standby |
| `./bc250-cec.sh vol-up` | Increase receiver volume |
| `./bc250-cec.sh vol-down` | Decrease receiver volume |
| `./bc250-cec.sh mute` | Toggle receiver mute |
| `./bc250-cec.sh handoff` | Select another CEC source |
| `./bc250-cec.sh repair` | Restore CEC registration |

### AIC8800 WiFi and Bluetooth

Install the USB driver and firmware:

```bash
sudo bash ./aic8800/steamdeck-setup.sh
```

The package includes AIC and OEM USB IDs. The installer stages source,
firmware, and kernel modules in persistent storage.

### GDDR6 memory temperature

This experimental tool supports the ASRock BC-250 P3.0 firmware layout. It
loads a temporary SMU payload and reads the MR3 temperature value from eight
GDDR6 devices.

```bash
sudo ./bc250-memory-temperature.sh prepare
sudo ./bc250-memory-temperature.sh patch --acknowledge-smu-risk
sudo ./bc250-memory-temperature.sh read
sudo ./bc250-memory-temperature.sh restore --acknowledge-smu-risk
```

Restore the payload before you purge its saved state. A cold power cycle also
restores the firmware SMU state.

**DANGER:** An incompatible SMU payload can cause memory corruption, file
system damage, a crash, or startup failure. Confirm the P3.0 firmware layout
before each live write.

## Control interfaces

### Decky plugin

[`decky-plugin/`](decky-plugin/) provides Gaming Mode controls for system
status, GPU tuning, CPU tuning, compute units, HDMI audio, and CEC.

Install it from **Control Interfaces > Decky Plugin**.

See [`decky-plugin/README.md`](decky-plugin/README.md) for build and service
details.

### Plasma control

[`desktop-control/`](desktop-control/) provides a Plasma 6 system-tray applet
and a windowed control panel.

Install it from **Control Interfaces > Plasma Desktop Control**, or run:

```bash
bash ./desktop-control/install.sh install
```

See [`desktop-control/README.md`](desktop-control/README.md) for service and
repair commands.

### BC250 Trainer

[`trainer/`](trainer/) provides a native Qt 6 control application. It includes
system status, toolkit tasks, GPU tuning, CPU controls, compute-unit routing,
and media playback.

Install the latest Trainer release:

```bash
./bc250-toolkit.sh trainer
```

The Trainer checks for toolkit updates and uses the same verified updater as
the command-line toolkit.

See [`trainer/README.md`](trainer/README.md) for native and Flatpak packages.

## SteamOS update recovery

Toolkit installers register component files with the SteamOS atomic-update
keep list. Persistent data remains under `/home/.steamos/offload`.

Check storage and persistence:

```bash
sudo ./bc250-storage.sh status
./bc250-update-persistence.sh status
```

Repair storage infrastructure:

```bash
sudo ./bc250-storage.sh repair
```

| Component | Action after a SteamOS or kernel update |
|---|---|
| GPU compute units | Run `sudo ./bc250-40cu.sh verify` |
| Power and ACPI | Run `sudo ./bc250-power.sh status` |
| AMDGPU module | Run `./bc250-toolkit.sh amdgpu`, then reboot |
| Mesa and RADV | Run `./bc250-toolkit.sh graphics-setup`, then complete its checkpoints |
| NCT6687 module | Run `./bc250-toolkit.sh fan-driver` for a new kernel |
| AIC8800 modules | Run `sudo bash ./aic8800/steamdeck-setup.sh` for a new kernel |
| BC-250 GE-Proton | Run `./bc250-toolkit.sh proton-status` |

Recover configuration from a SteamOS snapshot:

```bash
sudo ./bc250-update-persistence.sh recover compute
sudo ./bc250-update-persistence.sh recover power
sudo ./bc250-update-persistence.sh recover all
```

Run the applicable setup command after recovery. This action regenerates the
service files for the active SteamOS image.

## Remove components

Open **Maintenance and Recovery > Manage Installed Components**, or run:

```bash
./bc250-maintenance.sh status
./bc250-maintenance.sh plan all
./bc250-maintenance.sh uninstall desktop
./bc250-maintenance.sh uninstall trainer
./bc250-maintenance.sh uninstall all
```

The uninstall process restores stock behavior in dependency order. It keeps
profiles, preferences, source caches, and persistent data for later use.

Delete retained toolkit data after component removal:

```bash
./bc250-maintenance.sh purge
```

Some kernel, swap, and boot changes require a reboot. Run the requested removal
command again after that reboot.

## Development

Menu definitions use Mermaid graphs in [`menus/`](menus/).

Regenerate and check all menus:

```bash
python3 scripts/generate-menus.py --write
python3 scripts/generate-menus.py --check
python3 scripts/analyze-menu-graph.py --check --depth-budget 3
```

Run the Python test suite:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

See these documents for component development:

- [`MENU-GRAPH.md`](MENU-GRAPH.md)
- [`bc250-audio-fix/README.md`](bc250-audio-fix/README.md)
- [`core-unlock/README.md`](core-unlock/README.md)
- [`decky-plugin/README.md`](decky-plugin/README.md)
- [`desktop-control/README.md`](desktop-control/README.md)
- [`trainer/README.md`](trainer/README.md)

## Upstream projects

| Project | Resource |
|---|---|
| BC-250 40 CU Unlock | [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock) |
| BC-250 CU Live Manager | [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager) |
| UMR | [tomstdenis/umr](https://gitlab.freedesktop.org/tomstdenis/umr) |
| BC-250 ACPI Fix | [bc250-collective/bc250-acpi-fix](https://github.com/bc250-collective/bc250-acpi-fix) |
| Cyan Skillfish Governor | [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor/tree/smu) |
| BC-250 SMU OC | [bc250-collective/bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc) |
| BC-250 CPU Core Unlock | [rw-r-r-0644/bc250-core-unlock](https://github.com/rw-r-r-0644/bc250-core-unlock) |
| EFI Core Unlock | [Hexxeh/bc250-efi-core-unlock](https://github.com/Hexxeh/bc250-efi-core-unlock) |
| BC-250 Memory Config | [fanoush/bc250_memcfg](https://github.com/fanoush/bc250_memcfg) |
| BC-250 GDDR6 Memory Temperature | [pan-Rijovich/bc250-memory-temperature](https://github.com/pan-Rijovich/bc250-memory-temperature) · [integrated commit `b7e6bff`](https://github.com/pan-Rijovich/bc250-memory-temperature/commit/b7e6bffcb5d592fc03edde375b7598ddc79aa846) |
| GFX1013 Fix | [DryhoppedIPA/bc250-gfx1013-fix](https://github.com/DryhoppedIPA/bc250-gfx1013-fix) |
| BC250 RADV R2 | [luckiskind/bc250-radv-r2](https://github.com/luckiskind/bc250-radv-r2) |
| OptiScaler | [optiscaler/OptiScaler](https://github.com/optiscaler/OptiScaler) |
| BC-250 FSR4 RC9 | [daniel-h-0/bc250-fsr4-fork](https://github.com/daniel-h-0/bc250-fsr4-fork) |
| BC-250 GE-Proton and RADV | [MastaG/linux-cachyos-bc250](https://github.com/MastaG/linux-cachyos-bc250) |
| AIC8800 | [shenmintao/aic8800d80](https://github.com/shenmintao/aic8800d80) |
| NCT6687D | [Fred78290/nct6687d](https://github.com/Fred78290/nct6687d) |
| BC-250 VA-API video codec | [simpmix/bc250-encoding-decoding-fix](https://github.com/simpmix/bc250-encoding-decoding-fix) · [integrated release `v0.5.1`](https://github.com/simpmix/bc250-encoding-decoding-fix/releases/tag/v0.5.1) |

See [`LICENSE.md`](LICENSE.md) and the component license files for license
terms and attribution.
