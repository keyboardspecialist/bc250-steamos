# bc250-steamos

Management tools for SteamOS 3.8.x and 3.9.x.

## Quick Navigation

| | |
|---|---|
| [Install](#install) | [Tools](#tools) |
| [Toolkit Menu](#toolkit-menu) | [GPU Compute-Unit Unlock](#gpu-compute-unit-unlock) |
| [RAM / VRAM Split](#ram--vram-split) | [Compressed Swap](#compressed-swap) |
| [Power Management](#power-management) | [Experimental CPU Core Unlock](#experimental-cpu-core-unlock) |
| [CEC](#cec) | [Big Picture Plugin](#big-picture-plugin) |
| [Plasma Desktop Control](#plasma-desktop-control) | [CoolerControl](#coolercontrol) |
| [BC250 Trainer](#bc250-trainer) | [HDMI AC-3 Surround Encoding](#hdmi-ac-3-surround-encoding-optional) |
| [AMDGPU Driver](#amdgpu-driver) | [FSR4 RADV and GE-Proton](#mesa--radv-async-compute-and-fsr4) |
| [GDDR6 Memory Temperature](#gddr6-memory-temperature-experimental) | [NCT6687D Fan-Control Driver](#nct6687d-fan-control-driver) |
| [AIC8800 WiFi and Bluetooth Driver](#aic8800-class-wifi-and-bluetooth-driver) | [SteamOS Updates](#steamos-updates) |
| [References](#references) | |

## Install

```bash
mkdir -p ~/.local/share/bc250-fixes
git clone https://github.com/keyboardspecialist/bc250-steamos.git \
  ~/.local/share/bc250-fixes/bc250-steamos
cd ~/.local/share/bc250-fixes/bc250-steamos
```

Open the unified toolkit menu as the logged-in Deck user:

```bash
./bc250-toolkit.sh
```

### New Users

| Component | Setup command |
|---|---|
| Auto Base Toolkit Installation | `./bc250-toolkit.sh auto-base-installation`; run the same command after each requested reboot |
| AMDGPU kernel fixes | `./bc250-toolkit.sh amdgpu`, then reboot |
| Mesa / RADV async compute (optional, highly recommended) | `./bc250-toolkit.sh graphics-setup`, then resume after reboot |
| BC-250 GE-Proton for integrated FSR4 | Activate FSR4 RADV first, then run `./bc250-toolkit.sh proton-install` |
| Power management | `sudo ./bc250-power.sh all`, then `sudo ./bc250-power.sh enable` |
| RAM / VRAM split | `./bc250-ram-split.sh` |
| Compressed swap (optional) | `sudo ./bc250-swap.sh`, then choose zram or zswap-backed disk swap |
| GPU compute-unit unlock | `sudo ./bc250-40cu.sh` |
| CEC | `./bc250-cec.sh setup` |
| HDMI Dolby Digital 5.1 (optional) | **Devices & Connectivity > HDMI Audio** or `./hdmi-ac3/hdmi-ac3.sh install` |
| NCT6687 fan-control driver | `./bc250-toolkit.sh fan-driver` |
| GDDR6 memory temperature (experimental) | `./bc250-toolkit.sh memory-temperature` |
| AIC8800 | `sudo bash ./aic8800/steamdeck-setup.sh` |
| Decky plugin | `bash ./decky-plugin/install.sh` |
| Plasma desktop control | `bash ./desktop-control/install.sh install` |
| BC250 Trainer | `./bc250-toolkit.sh trainer` |
| Compressed swap | `sudo ./bc250-swap.sh install zram` or `sudo ./bc250-swap.sh install zswap` |
| Persistent storage and recovery | Automatic with each setup workflow; `./bc250-storage.sh` opens its menu |
| System health | `./bc250-toolkit.sh status` |

### Existing Users

```bash
cd ~/.local/share/bc250-fixes/bc250-steamos
git pull
```

Older existing installations that predate persistent storage must run the
following command once after updating. It migrates existing toolkit data and
installs the storage recovery infrastructure; it does not need to be repeated
after later pulls.

```bash
sudo ./bc250-storage.sh install
```

| Installed feature | Refresh command |
|---|---|
| GPU governor | `sudo ./bc250-power.sh enable` |
| ACPI and CPU frequency | `sudo ./bc250-power.sh acpi` |
| GPU compute-unit unlock | `sudo ./bc250-40cu.sh persist` |
| CEC shutdown integration | `./bc250-cec.sh shutdown-standby install` |
| NCT6687 fan-control driver | `sudo bash ./nct6687d/steamdeck-setup.sh install` |
| AIC8800 | `sudo bash ./aic8800/steamdeck-setup.sh` |
| Plasma desktop control | `bash ./desktop-control/install.sh install` |
| BC250 Trainer | `./bc250-toolkit.sh trainer` |

```bash
sudo ./bc250-storage.sh status
sudo ./bc250-power.sh status
```

## Tools

| Tool | Purpose |
|---|---|
| [`bc250-toolkit.sh`](#toolkit-menu) | Unified menu, resumable Auto Base Toolkit Installation, and read-only system health |
| [`bc250-40cu.sh`](#gpu-compute-unit-unlock) | Runtime GPU CU/WGP configuration and boot persistence |
| [`bc250-cu-status.sh`](#gpu-compute-unit-unlock) | CU dispatch status |
| [`bc250-power.sh`](#power-management) | CPU power states, GPU governor, clock and voltage tuning, CPU overclocking |
| [`bc250-ram-split.sh`](#ram--vram-split) | CMOS minimum VRAM and dynamic TTM VRAM limit |
| [`bc250-swap.sh`](#compressed-swap) | Mutually exclusive zram and zswap-backed disk swap profiles |
| [`bc250-cec.sh`](#cec) | TV, receiver, input, and power control over HDMI-CEC |
| [`bc250-update-persistence.sh`](#steamos-updates) | Atomic-update allowlist and tuning recovery |
| `bc250-maintenance.sh` | Installed-component inventory, uninstall orchestration, and optional data purge |
| [`decky-plugin/`](#big-picture-plugin) | Quick Access interface for daily controls |
| [`desktop-control/`](#plasma-desktop-control) | Plasma system-tray and windowed controls |
| [`trainer/`](#bc250-trainer) | Standalone native Qt control application |
| [`bc250-audio-fix/`](#amdgpu-driver) | DisplayPort clock, GPU telemetry, and GFX1013 compute repair |
| [`hdmi-ac3/`](#hdmi-ac-3-surround-encoding-optional) | Real-time Dolby Digital 5.1 encoding over HDMI/DisplayPort |
| [`bc250-mesh-shader.sh`](#mesa--radv-async-compute-and-fsr4) | Mesa / RADV build with GFX1013 async compute and integrated BC-250 FSR4 patches |
| `bc250-proton.sh` | Transactional user-local installer for the checksum-pinned BC-250 GE-Proton build |
| [`bc250-memory-temperature.sh`](#gddr6-memory-temperature-experimental) | Guarded, checksum-pinned live SMU payload for reading all eight GDDR6 chip temperatures |
| [`nct6687d/`](#nct6687d-fan-control-driver) | Optional NCT6683/6686/6687 hwmon fan tachometer and PWM driver |
| [`aic8800/`](#wifi-and-bluetooth) | AIC8800 USB WiFi and Bluetooth driver |

The unified launcher and individual component scripts remain independently usable. Use the child scripts directly for command-line automation.

## Toolkit Menu

Run `./bc250-toolkit.sh` without `sudo`. The main menu groups Core System, Power
& Thermals, Graphics Stack, Hardware Unlocks, Devices & Connectivity, Control
Interfaces, and Maintenance & Recovery. Child menus return to the toolkit when
they exit. Installer and build entries require confirmation before starting
their longer setup workflows.
Each child requests administrator access only when needed.

The toolkit and standalone component menus are authored as Mermaid graphs under
[`menus/`](menus/), with targets declared in
[`menus/targets.json`](menus/targets.json). Regenerate all menu targets with
`python3 scripts/generate-menus.py --write` and audit them with
`python3 scripts/analyze-menu-graph.py`. See
[`MENU-GRAPH.md`](MENU-GRAPH.md) for syntax and validation details.

| Command | Action |
|---|---|
| `./bc250-toolkit.sh` | Open the unified interactive menu |
| `./bc250-toolkit.sh setup` | Open the status-aware guided setup checklist |
| `./bc250-toolkit.sh auto-base-installation` | Run Auto Base Toolkit Installation in dependency order |
| `./bc250-toolkit.sh graphics-setup` | Install or resume AMDGPU and Mesa / RADV in dependency order |
| `./bc250-toolkit.sh status` | Show read-only system health using the menu's component names |
| `./bc250-toolkit.sh inventory-json` | Emit versioned lifecycle state for the native Trainer dashboard |
| `./bc250-toolkit.sh action OPERATION_ID` | Run one fixed dashboard action without opening a TUI |
| `./bc250-toolkit.sh drivers` | Open AMDGPU, Mesa / RADV, NCT6687, and AIC8800 driver setup |
| `./bc250-toolkit.sh unlocks` | Open GPU compute-unit and CPU core unlock setup |
| `./bc250-toolkit.sh power [ENTRY]` | Open Power at root, foundation, frequency, load, ramp, or CPU tuning |
| `./bc250-toolkit.sh ram` | Open RAM / VRAM split settings |
| `./bc250-toolkit.sh swap` | Choose a compressed swap profile |
| `./bc250-toolkit.sh amdgpu` | Build the AMDGPU kernel fixes |
| `./bc250-toolkit.sh radv` | Open the global Mesa / RADV async-compute menu |
| `./bc250-toolkit.sh proton` | Open BC-250 GE-Proton status, installation, update, and removal |
| `./bc250-toolkit.sh proton-install` | Install the pinned GE-Proton build after FSR4 RADV is active |
| `./bc250-toolkit.sh audio-output` | Open HDMI AC-3 enable and stereo-revert options |
| `./bc250-toolkit.sh fan-driver` | Build and install NCT6687 hwmon fan/PWM support for the onboard controller |
| `./bc250-toolkit.sh memory-temperature` | Open the experimental GDDR6 temperature workflow |
| `./bc250-toolkit.sh coolercontrol` | Install CoolerControl for fan profiles, curves, and monitoring |
| `./bc250-toolkit.sh trainer` | Download, verify, and install the latest native BC250 Trainer release |
| `./bc250-toolkit.sh manage` | Review and remove installed components |
| `./bc250-toolkit.sh help` | List launcher commands and components |

`action` accepts only the operation IDs printed by `help`; it does not accept
arbitrary scripts or arguments. These machine-facing commands back the native
Trainer dashboard. Normal interactive use should continue through the toolkit
menu.

### Guided Setup

The top-level **Auto Base Toolkit Installation** action installs the safe foundation and
resumes from verified state after each restart boundary:

1. Install the ACPI and GPU-governor foundation, the verified memory helper,
   and the AMDGPU kernel fixes, then stop for the required reboot.
2. Run **Auto Base Toolkit Installation** again. It verifies the active AMDGPU module,
   installs signed RADV prerequisites and the Mesa / RADV runtime, configures
   `amdgpu.sched_policy=2`, then stops for the second reboot.
3. Run it once more to verify global activation and show **System health**.

The automatic path test-starts the GPU governor but does not enable it at boot;
load-test it first. It installs the memory helper but does not choose CMOS UMA
or TTM values. Hardware unlocks, tuning, swap profiles, device-specific drivers,
control interfaces, and FSR4 remain explicit choices under manual setup.

Persistent storage and boot recovery are infrastructure rather than a separate
setup prerequisite. Supported component installers create them automatically
when needed; their manual status and repair menu remains under Core System.

GPU-CU and CPU-core unlocks are discoverable from Guided Setup but remain
optional and outside the foundation path, so their stability tests and recovery
requirements are not mistaken for routine setup. The existing component
commands and expert menus remain available.

### Uninstall And Cleanup

Open **Manage installed components** in the toolkit, or run the maintenance
script directly:

```bash
./bc250-maintenance.sh status
./bc250-maintenance.sh plan all
./bc250-maintenance.sh uninstall desktop
./bc250-maintenance.sh uninstall trainer
./bc250-maintenance.sh uninstall all
```

Component uninstall restores stock behavior and removes services, drivers, and
desktop integrations in dependency-safe order. Saved tuning profiles, CEC
preferences, source/build caches, and persistent backing data are preserved by
default. RAM firmware reset uses a CMOS clear. ACPI, TTM, compute routing,
AMDGPU, and loaded AIC8800 rollback may require a reboot. The NCT6687
uninstaller refuses to continue unless it can unload the driver and restore
firmware fan control. After every
component is removed, permanently delete retained data with
`./bc250-maintenance.sh purge`. Active toolkit disk swap uses a two-stage
uninstall: reboot once to deactivate it, then rerun removal.

## GPU Compute-Unit Unlock

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

## RAM / VRAM Split

```bash
./bc250-ram-split.sh
```

| Utility | Configuration |
|---|---|
| Source | [`fanoush/bc250_memcfg`](https://github.com/fanoush/bc250_memcfg) latest stable release |
| Delivery | Explicit runtime download |
| Verification | GitHub SHA-256 digest and x86-64 ELF validation |
| Install path | `/var/lib/bc250-control/bin/bc250memcfg` |
| Exposed field | `UMA_SIZE` |
| Upstream license metadata | Unspecified |

| UMA property | Value |
|---|---|
| Meaning | Minimum reserved VRAM |
| Storage | Battery-backed CMOS |
| Activation | Reboot |
| Supported range | 256 MiB through 12 GiB, aligned to 16 MiB |
| Known Linux boot failure | 2048 MiB |
| Firmware-default recovery | Clear CMOS with the board jumper or battery |

| Command | Action |
|---|---|
| `sudo ./bc250-ram-split.sh install` | Install or update the verified utility |
| `sudo ./bc250-ram-split.sh show` | Read the current CMOS memory configuration |
| `sudo ./bc250-ram-split.sh set 512 --yes` | Set a 512 MiB minimum VRAM allocation |
| `sudo ./bc250-ram-split.sh ttm-set 3014656 --yes` | Apply the BC-250 guide TTM preset |
| `./bc250-ram-split.sh status` | Show utility, UMA profile, and TTM status |

| TTM property | Value |
|---|---|
| Parameter | `ttm.pages_limit` |
| Purpose | Dynamic system-memory-backed GPU allocation cap |
| Configuration | `/etc/default/grub.d/bc250-ttm.cfg` |
| Guide preset | `3014656` pages: 11.50 GiB dynamic, approximately 12 GB total with 512 MiB UMA |
| Exact 12 GiB dynamic | `3145728` pages |
| Status states | Active, reboot needed, default, or foreign configuration |

## Compressed Swap

Open the profile menu:

```bash
./bc250-toolkit.sh swap
```

The two profiles are mutually exclusive:

| Profile | Configuration |
|---|---|
| Zram | Valve-style compressed RAM swap sized to half of physical RAM, `zstd`, priority 100 |
| Zswap + disk | Global kernel zswap cache using `lz4` and a 25% RAM pool, backed by a 16 GiB toolkit-owned disk swapfile at priority 10 |

The disk swapfile lives under `/var/lib/bc250-control/swap`, which is backed by
SteamOS's shared `/home/.steamos/offload` storage. A local tmpfiles rule
configures zswap after local filesystems are available and takes precedence over
SteamOS's packaged zswap default. A late setup service applies only that rule
and must succeed before the disk swap starts. Swapfile size can be selected from
4 through 64 GiB with the direct CLI. Zswap applies to pages sent to every
active disk swap device, but the toolkit never disables or removes unrelated
swapfiles.

```bash
sudo ./bc250-swap.sh install zram
sudo ./bc250-swap.sh install zswap          # 16 GiB default
sudo ./bc250-swap.sh install zswap 32       # 32 GiB
./bc250-swap.sh status
sudo ./bc250-swap.sh uninstall
```

Profile transitions are reboot-gated and never perform a live `swapoff`.
Switching away from an active toolkit disk swap or uninstalling it requires one
reboot followed by rerunning the requested command. The second pass removes the
now-inactive swapfile and integration. Removing the toolkit profile restores
Valve's packaged zram defaults on the next boot.

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
The packaged universal tables cover every logical CPU in both the factory
6-core/12-thread and unlocked 8-core/16-thread topologies.
Run the `acpi` command once after upgrading an older toolkit installation; its
versioned payload cache will rebuild and request a reboot.

### GPU Tuning

```bash
sudo ./bc250-power.sh freq status
sudo ./bc250-power.sh freq 1800
sudo ./bc250-power.sh freq 0 2000
sudo ./bc250-power.sh freq auto

sudo ./bc250-power.sh gpu-volt show
sudo ./bc250-power.sh gpu-volt offset -25
sudo ./bc250-power.sh gpu-volt set 2000 985
sudo ./bc250-power.sh gpu-volt add 1200 850
sudo ./bc250-power.sh gpu-volt edit 1200 1250 875
sudo ./bc250-power.sh gpu-volt remove 1250
sudo ./bc250-power.sh gpu-volt reset

sudo ./bc250-power.sh load-target eager
sudo ./bc250-power.sh load-target set 70 55
sudo ./bc250-power.sh load-target reset

sudo ./bc250-power.sh temperature set 80
sudo ./bc250-power.sh temperature reset

sudo ./bc250-power.sh ramp set 500
sudo ./bc250-power.sh ramp reset
```

Frequency, voltage, load-target, thermal-target, and ramp settings persist
across boots. The thermal control uses a recovery threshold 10 C below the
selected throttle target and applies it live when the governor is running. The
default voltage curve spans 350-2230 MHz; points use a 700-1050 mV range and
must have increasing frequencies with nondecreasing voltages. Curve updates
are atomic and restore the prior config/runtime if governor reload or saved
frequency replay fails. The guided TUI can list, add, edit, and remove points.

`[frequency-range] min` keeps adaptive scaling at or above the toolkit's
350 MHz floor. `max` is the adaptive ceiling, not a fixed clock. The active
clock rises toward that ceiling only when GPU load exceeds the configured
upper load target. `freq 1800` pins 1800 MHz, while `freq 0 1800` keeps
adaptive scaling between 350 and 1800 MHz.

### CPU Tuning

```bash
sudo ./bc250-power.sh cpu-oc detect 4000 1275
sudo ./bc250-power.sh cpu-oc enable
sudo ./bc250-power.sh cpu-oc status
sudo ./bc250-power.sh cpu-oc apply
sudo ./bc250-power.sh cpu-oc off

sudo ./bc250-power.sh cpu-mitigations status
sudo ./bc250-power.sh cpu-mitigations disable
sudo ./bc250-power.sh cpu-mitigations enable
```

`cpu-oc detect` stress-tests each frequency step. Keep the VID limit at or below 1325 mV.

The CPU menu also exposes a security-mitigations toggle. Disabling writes
`mitigations=off` through a toolkit-owned GRUB drop-in and may improve
performance, but reduces protection against processor vulnerabilities.
Enabling removes that argument and returns to kernel defaults. Both changes
require a reboot; the configured state persists through SteamOS updates.

## Experimental CPU Core Unlock

[`rw-r-r-0644/bc250-core-unlock`](https://github.com/rw-r-r-0644/bc250-core-unlock)
discovered the SMU command that changes the BC-250 core-presence mask from
`0x77` to `0xff`, allowing AGESA to enumerate 8 cores and 16 threads.

Open **Hardware unlocks**, then **CPU core unlock** for the guided workflow:

```bash
./bc250-toolkit.sh unlocks
```

The same dedicated menu is available directly with
`sudo ./bc250-power.sh cpu-unlock menu`. The implementation shares its service
lifecycle with Power management, so removing the Power component also removes
CPU core-unlock boot persistence.

```bash
./bc250-toolkit.sh amdgpu
sudo ./bc250-power.sh cpu-unlock test
sudo reboot
sudo ./bc250-power.sh cpu-unlock status
# Stress-test the extra cores and inspect dmesg, then choose ONE method:
sudo ./bc250-power.sh cpu-unlock enable
# OR use the experimental EFI alternative (do not enable both):
# sudo ./bc250-power.sh cpu-unlock efi-enable
```

The mask survives warm reboots but resets after a full power-off. AGESA reads
it before Linux starts, so initramfs cannot apply it early enough. On a later
cold boot, the enabled service safely writes the mask and requests one warm
reboot. A persistent pending marker prevents a failed unlock from creating a
reboot loop.

The AMDGPU build carries both the stock six-core metrics decoder and the Robin
1/3 eight-core decoder. After eight cores are active, `cpu-unlock
metrics-enable` installs a boot service that injects the matching widened table
into the SMU and selects the widened decoder only after every write verifies.
The production injector is under `core-unlock/smu-metrics`; it contains no RPC
research payload or redistributed firmware image.

After validating all eight cores, choose exactly one automatic unlock method.
The standard Linux/systemd method and the EFI pre-boot method are mutually
exclusive and cannot be enabled together. The standard method applies the mask
after Linux boots. `efi-enable` is an alternative that installs an unsigned,
namespaced pre-boot application and removes the extra Linux boot from the
cold-start sequence. On the first firmware pass after cold power, the
application writes the mask and requests a warm reset. On the second pass, it
sees the completed mask and lets firmware continue to SteamOS. The EFI method
therefore avoids booting Linux once solely to apply the mask, but does not
eliminate the warm reset AGESA needs to enumerate eight cores.
Its installer requires `/efi` to be the writable FAT filesystem mounted from a
standard GPT ESP or the active SteamOS EFI slot and records that partition's
canonical source, partition number, and PARTUUID. The firmware entry must be
active, first in `BootOrder`, and match that device identity. Removal retains
the loader and all ownership evidence if the ESP, entry, or NVRAM query cannot
be verified. After the warm reset, the helper clears its guard and returns
high-bit `EFI_ABORTED`
so firmware advances to the next `BootOrder` entry.

`cpu-unlock status` reports whether the patched module is installed for the
running kernel.

| Command | Action |
|---|---|
| `./bc250-toolkit.sh unlocks` | Open the GPU and CPU hardware-unlock menu |
| `sudo ./bc250-power.sh cpu-unlock menu` | Open the dedicated guided CPU core-unlock menu |
| `./bc250-power.sh cpu-unlock topology` | Show active CPU cores grouped by CCX |
| `sudo ./bc250-power.sh cpu-unlock test` | Apply the volatile mask once without installing boot persistence; reboot manually |
| `sudo ./bc250-power.sh cpu-unlock enable` | Setup 2 standard choice: verify eight cores are active and enable automatic unlock from Linux |
| `sudo ./bc250-power.sh cpu-unlock efi-enable` | Setup 2 alternative choice: verify eight cores are active and enable automatic unlock from EFI; do not use with `enable` |
| `sudo ./bc250-power.sh cpu-unlock metrics-enable` | Install the boot-time SMU injection service for correct eight-core metrics |
| `sudo ./bc250-power.sh cpu-unlock status` | Show service, topology, and reboot-guard state |
| `sudo ./bc250-power.sh cpu-unlock off` | Disable/remove either automatic unlock method but retain the Linux helper |
| `sudo ./bc250-power.sh cpu-unlock uninstall` | Remove all systemd/EFI artifacts, helper, license copies, and pending state |

Use `off` when you only want to stop automatic unlock and may test or re-enable
the unlock later. Use `uninstall` to remove the complete core-unlock integration,
including the retained Linux helper and its support files.

`test` does not create a systemd unit, enablement symlink, or atomic-update
entry. If the extra cores are unstable, do not run `enable`; power the system
off fully to restore the factory six-core mask.

The SMU command has no known inverse; `off` and `uninstall` stop future
automatic unlock, but a full power-off is required to return to six cores. The
disabled cores may be defective. Upstream tested BIOS 3.0 with kernel 6.18.40;
BIOS 5 is untested. Stress-test all cores and inspect `dmesg` for hardware
errors before relying on them.

The vendored Linux helper is pinned to upstream commit
[`87ec098`](https://github.com/rw-r-r-0644/bc250-core-unlock/commit/87ec09877df57d2e310a9b9961584a78b6d1c79d)
under its MIT license. Toolkit changes are documented in
[`core-unlock/README.md`](core-unlock/README.md): whole-transaction locking,
strict mailbox timeout handling, topology checks, service modes, and the
guarded cold-boot reboot flow.

The hardened EFI source is adapted from
[`Hexxeh/bc250-efi-core-unlock@3e45131`](https://github.com/Hexxeh/bc250-efi-core-unlock/commit/3e45131678b111c50e5c285834869ecd3c487a2e)
under Liam McLoughlin's MIT license. Builds fetch only
[`yoppeh/efi@761b114`](https://github.com/yoppeh/efi/commit/761b114e3b186adb82516d5fa8e7a4c559f56ba5)
headers under Warren Mann's MIT license and verify the exact commit. The custom
guard variable, GUID, build flow, ownership checks, and both notices are
documented in [`core-unlock/README.md`](core-unlock/README.md).

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

## Big Picture Plugin

[`decky-plugin/`](decky-plugin/) provides a Decky Loader Quick Access interface
with vertical sections for CU status, power health, GPU tuning, saved CPU
tuning, HDMI surround/stereo selection, and CEC controls.

The plugin uses the toolkit checkout at `~/.local/share/bc250-fixes/bc250-steamos`. Build instructions are in [`decky-plugin/README.md`](decky-plugin/README.md).

## Plasma Desktop Control

[`desktop-control/`](desktop-control/) provides a Plasma 6 system-tray applet
and optional `plasmawindowed` view with Overview, GPU, CU, CPU, and CEC tabs.
It runs independently from Decky and requests polkit authorization only for
privileged hardware changes. Installation and troubleshooting instructions are
in [`desktop-control/README.md`](desktop-control/README.md).

## CoolerControl

[`coolercontrol/`](coolercontrol/) installs the pinned official CoolerControl
daemon AppImage and a desktop launcher for its local Web UI. Install the NCT6687
driver first, then select **CoolerControl** under **Power & Thermals** or run:

```bash
./bc250-toolkit.sh coolercontrol
```

The daemon and its configuration live in update-proof BC-250 storage. The
installer verifies the upstream SHA-256, enables the managed service, and opens
the interface at <http://localhost:11987>. Uninstall restores firmware automatic
fan mode and preserves CoolerControl profiles for later reuse.

## BC250 Trainer

[`trainer/`](trainer/) provides a standalone native Qt 6 frontend for status,
GPU tuning, compute-unit routing, CPU controls, the experimental core unlock,
and a folder-backed music deck with synchronized waveform and beat visualizer.
Install the prebuilt release artifact as the logged-in desktop user:

```bash
./bc250-toolkit.sh trainer
```

The toolkit selects the highest published `trainer-vMAJOR.MINOR.PATCH`
prerelease, downloads its native ZIP and SHA-256 file, validates the release
metadata and archive paths, and runs the packaged installer. To install a
downloaded artifact manually instead:

```bash
unzip bc250-trainer-vX.Y.Z.zip
cd bc250-trainer
bash trainer/install.sh install
```

The Trainer artifact is self-contained: it includes the executable, installer, backend,
shared service, persistence helpers, CPU core-unlock bundle, and topology helper.
`status` and `uninstall` use the same path. User files are installed below
`~/.local`; sudo is requested only for shared service registration.
The embedded artwork and soundtrack are released under the Unlicense; provenance
and trademark notes are recorded in [`trainer/ASSETS.md`](trainer/ASSETS.md).

Release tags also publish `bc250-trainer-*-flatpak-installer.zip`. This complete
kit includes the Flatpak, privileged host service, backend, and persistence
helpers. Extract it and run `bash trainer/install-flatpak.sh install`; the
installer requests sudo only for the host service and installs the GUI as a
per-user Flatpak.

The Plasma and BC250 Trainer frontends share one root-owned service payload. Each
installation records a root-owned `plasma.<uid>` or `trainer.<uid>` marker.
Removing a frontend releases only its marker, and the service is removed only
after the final registered frontend is gone. Tuning profiles and helper state
remain preserved.

## HDMI AC-3 Surround Encoding (Optional)

SteamOS ships an ALSA AC-3 profile for Valve hardware, but the BC-250's DMI
identity does not activate it. The toolkit can select that profile for the AMD
HDMI card and encode six-channel PCM to Dolby Digital with ALSA's `a52` plugin.
On 6.16 and 6.18, install the AMDGPU audio correction and reboot first. Valve
7.2 does not need the legacy audio patches. Then open **Devices & Connectivity
> HDMI Audio** and choose **Enable HDMI AC-3 5.1**.

The setup requires an AC-3-capable receiver or soundbar. It installs a
toolkit-owned udev rule, adds a user WirePlumber fragment, selects the encoded
sink, and retains the system rule across SteamOS updates. The same audio menu
has a separate **Revert HDMI AC-3 to stereo** option. Command-line equivalents:

```bash
./hdmi-ac3/hdmi-ac3.sh install
./hdmi-ac3/hdmi-ac3.sh status
./hdmi-ac3/hdmi-ac3.sh revert
```

See [`hdmi-ac3/README.md`](hdmi-ac3/README.md) for requirements, behavior, and
upstream attribution.

## AMDGPU Driver

Build and install the matching `amdgpu` module:

```bash
cd bc250-audio-fix
./patch-driver.sh
```

The normal build omits experimental DCN201 DSC and HDMI 2.1 PCON support on
kernel 7.2. To include it for 4K at 120 Hz, explicitly accept the display
instability risk:

```bash
./patch-driver.sh --acknowledge-dcn201-display-risk
```

The patches preserve the Cyan Skillfish firmware metrics layout, query GFX
frequency directly from the SMU, add GPU utilization reporting, and repair the
GFX1013 compute-queue lifecycle. On 6.16 and 6.18 they also apply the required
DisplayPort audio corrections; Valve 7.2 needs neither legacy audio patch.
The toolkit's interactive AMDGPU action asks separately whether to include the
7.2-only DSC/PCON pair. Declining that opt-in continues with the stable build.
Builds are matched to the running kernel and checked for vermagic and ABI compatibility
before installation. If Valve omitted the matching headers, the toolkit can
generate the required symbols with a complete exact-source kernel build.

The module also carries a disabled-by-default KFD HWS runlist TLB-flush
workaround for stale ROCm mappings. Enable it only from **Graphics Stack > Advanced
AMDGPU Boot Options > KFD Runlist Workaround**. It requires hardware scheduling and is mutually exclusive
with the RADV workflow's `amdgpu.sched_policy=2`; enabling RADV policy replaces
the workaround rather than combining both boot options.

Rollback:

```bash
sudo ./rollback.sh
```

See [`bc250-audio-fix/README.md`](bc250-audio-fix/README.md) for kernel support and build controls.

## Mesa / RADV Async Compute and FSR4

This optional but highly recommended patch builds the Mesa/RADV half of
[`DryhoppedIPA/bc250-gfx1013-fix`](https://github.com/DryhoppedIPA/bc250-gfx1013-fix)
as a separate Vulkan ICD to enable GFX1013 asynchronous compute. The matching
`bc250-audio-fix` AMDGPU kernel module must be built, installed, selected, and
active first. Driver readiness refuses to pass unless all installed module
markers, the selected `modinfo` path, and the loaded module composition
attestations agree. Use
**Auto Base Toolkit Installation** for the complete foundation, or choose **Graphics
Stack > Install or Resume Async Compute**. The toolkit installs AMDGPU
first, pauses for reboot, and resumes RADV when the same option is selected
again. The RADV build normally takes about 3-5 minutes.

The FSR4 profile also applies the BC-250 FSR4 series from
[`MastaG/linux-cachyos-bc250`](https://github.com/MastaG/linux-cachyos-bc250)
at pinned commit `db49878af40551b481f511053201fcf1e1bd5d90`. It uses Mesa
`mesa-26.2.2` at commit `3281a69a8bfd9f997e91c15ed0e6290cae12dd32` and applies
patches `0001` and `0005` through `0009` with zero fuzz. Unsafe mesh/task and
query patches `0002` through `0004` are not downloaded or applied. Build output
must contain the FSR4 feature markers and pass ELF, linkage, and
dependency checks before installation.

A separate, opt-in private profile adds LoneWolf's physical-GFX10 native-mesh
backend from commit `d67c00d4aad5797364abc3401d419e76afb04edd`. The toolkit
maintains a deterministic Mesa 26.2.2 rebase on top of the same `0001` and
`0005`-`0009` composition; this rebase is not represented as an upstream
LoneWolf release. Setup verifies the original and rebased patch hashes and
uses strict application without fuzz or 3-way fallback. LoneWolf's license and
known-limitations notices are retained in `bc250-mesa-patches/` and in the
installed private profile.

Open the menu as the logged-in user:

```bash
./bc250-mesh-shader.sh
```

Or use the CLI:

```bash
./bc250-mesh-shader.sh setup
./bc250-mesh-shader.sh setup --native-mesh
./bc250-mesh-shader.sh setup --fsr4 "/path/to/OptiScaler/amd_fidelityfx_upscaler_dx12.dll"
./bc250-mesh-shader.sh status
```

Step 1 does not enable `amdgpu.sched_policy=2`. RADV setup installs the patched
ICD first and only then writes that boot policy. It does not execute the
alternate ICD during this pre-policy installation. Reboot afterward so the
kernel policy and patched RADV activate together.

Setup installs a systemd user-environment generator that exports
`VK_DRIVER_FILES` and `VK_ICD_FILENAMES` for the complete user session. Sign
out and back in after later rebuilds when policy `2` is already active. The
generator exports nothing unless the installed module hashes, loaded module's
read-only GFX1013 repair attestation, and active scheduler policy all validate.

The global driver list is architecture-qualified. Native 64-bit processes use
the patched GFX1013 RADV ICD, while 32-bit processes fall back to SteamOS's
stock `radeon_icd.i686.json` and `lib32-vulkan-radeon`. Setup installs and
strictly verifies that signed SteamOS fallback package when needed. This also
supports games
that launch a mixture of 64-bit and 32-bit Vulkan processes.

The native-mesh profile has its own x86-64 driver, ICD, attested runner,
manifest, and transaction. It never references the global environment
generator and does not change Steam configuration. Its 32-bit fallback remains
SteamOS's signed stock RADV. The current patched compute kernel and active
`amdgpu.sched_policy=2` are mandatory because the private profile includes the
same async-compute changes. After `setup --native-mesh`, use one of these Steam
launch options manually:

```text
~/.local/share/bc250-mesh-shader/native-mesh/bc250-native-mesh-run %command%
~/.local/share/bc250-mesh-shader/native-mesh/bc250-native-mesh-run --ff7-capabilities %command%
```

The default runner sets `RADV_EXPERIMENTAL` to exactly `bc250_mesh` and clears
the FF7 capability switches. `--ff7-capabilities` additionally sets
`RADV_BC250_ADVERTISE_TASK=1` and `RADV_BC250_EXPOSE_FSR=1`. Here `FSR` means
fragment shading rate, not FidelityFX Super Resolution. Task capability
advertisement does not implement safe Task execution. Remove only this private
profile with `./bc250-mesh-shader.sh uninstall --native-mesh`.

Do not use this ICD with the stock kernel module. The alternate driver exposes
dedicated compute queues that require the kernel lifecycle repair, and upstream
reports that the mismatched combination can hang the GPU.

Remove it:

```bash
./bc250-mesh-shader.sh uninstall
```

Uninstall verifies recorded hashes before removing the alternate driver and
environment generator. If scheduler policy `2` is active, uninstall removes it
from the next boot but retains RADV until after that reboot; rerun uninstall to
finish. Sign out and back in afterward to clear the inherited Vulkan
environment. **Older per-game setup cleanup** is relevant
only when upgrading from toolkit versions that recorded games in `~/.drirc`.
Those records identify games that may still have
`MESA_DRICONF_EXECUTABLE_OVERRIDE` or `VK_ICD_FILENAMES` in their Steam launch
options. Remove those options, run `./bc250-mesh-shader.sh legacy-clear`, and
then uninstall; unrelated `~/.drirc` content is preserved. New installations
do not create per-game records.

The global alternate build remains x86-64 only. Its async-compute and FSR4
changes therefore do not apply to 32-bit processes; those processes use the
stock SteamOS RADV fallback instead. The global profile still does not apply
the old optional GFX1013 mesh/task and query patches, which upstream disabled
after mesh/task workloads caused an unrecoverable GPU hang. LoneWolf's newer
private physical-GFX10 implementation is isolated behind explicit runner
opt-in and retains fail-closed limitations for unsupported Task, CullPrimitive,
GPL, shader-object, DGC, query, and special-output paths. It remains an
experimental preview rather than full `VK_EXT_mesh_shader` conformance.

An existing environment generator or legacy V3 runner from an older toolkit
cannot be deactivated merely by replacing these scripts. After upgrading, run
`./bc250-mesh-shader.sh setup`, then sign out and back in before launching
games. Status reports older patch compositions as invalid rather than reusing
their Mesa build output.

Two FSR4 routes are available:

- **Portable RC9 DLL:** game-local, reversible, and independent of custom RADV
  or Proton. This is the lower-risk initial route.
- **FSR4 RADV plus BC-250 GE-Proton:** integrated compatibility-tool
  route. Complete `graphics-setup`, its reboot/sign-out checkpoint, and then
  install GE-Proton from the toolkit. Keep portable RC9 available until the
  integrated route is qualified for each game.

### OptiScaler Game Manager

The Decky and Plasma GPU pages can install OptiScaler into a selected Steam
game executable directory. The manager pins OptiScaler `v0.9.4`, verifies the
release archive with SHA-256
`575cb4df866116093df75af607e37fd70e10f5163e0f23fd5c804142e80ef0ad`, and
never runs the upstream setup or uninstall scripts. Choose the directory that
contains the game executable and the proxy DLL required by that game. The
default `winmm.dll` proxy is not universal; consult OptiScaler's compatibility
notes when a game requires `dxgi.dll`, `version.dll`, or another supported
proxy.

Each installation has a private rollback record. Existing files are backed up
before replacement, user-modified INI files are preserved, interrupted
operations remain removable or resumable, and a changed runtime is never
silently overwritten. The UI sends only an opaque discovered-candidate ID and
the backend resolves and revalidates the directory before each mutation.

Close the game before installing, updating, repairing, or removing OptiScaler.
Do not inject OptiScaler into online or anti-cheat games: DLL injection can
trigger anti-cheat action or account bans. If BC-250 FSR4 is installed beneath
the same directory, restore that DLL before updating or removing OptiScaler;
the two rollback systems are deliberately locked against conflicting changes.

### FSR4 RC9 Game DLL

The portable FSR4 path uses the RC9 DLL from
[`daniel-h-0/bc250-fsr4-fork`](https://github.com/daniel-h-0/bc250-fsr4-fork).
It contains the optimized FSR 4.1.1 INT8 shaders and does not require a custom
Mesa driver or Proton build. The Decky and Plasma GPU pages discover installed
Steam libraries and provide guarded per-game toggles when they find the exact
`amd_fidelityfx_upscaler_dx12.dll` target. They rescan and validate an opaque
target ID before each change; filesystem paths submitted by a UI are never
accepted as mutation inputs.

For command-line installation, close the game and provide the exact existing
compatible OptiScaler or native-game `.dll` file, not its directory. Relative
paths work, but an absolute path is recommended. Quote paths containing spaces
when using the command line; paste them without quotes in the interactive menu:

```bash
./bc250-mesh-shader.sh setup --fsr4 \
  "/path/to/OptiScaler/amd_fidelityfx_upscaler_dx12.dll"
```

The installer downloads `bc250-fsr4-dll-4.0.0-rc9-docs2.tar.xz`, verifies archive
SHA-256 `063e23e0a56605b63deef2c03100432eb75d991c68eb04c6eb9b4a8444fd4f06`,
then verifies DLL SHA-256
`eefcac03ab17b04a29a5bb16e3f3e9c3181ba9ea46b05a61cb49a5003e1516ef`.
The release instructions and notices remain in the private cache. Each target
has a separate rollback record containing the exact original bytes. The
toolkit refuses to overwrite symlinks, unrecorded RC9 copies, or a target that
changed after installation.

For OptiScaler installed through `winmm.dll`, use the upstream launch option:

```text
PROTON_FSR4_UPGRADE=0 PROTON_USE_OPTISCALER=0 WINEDLLOVERRIDES="winmm=n,b;amdxcffx64=" %command%
```

Set OptiScaler to the FFX backend, FSR4 INT8 model 2, and disable frame
generation unless separately qualified. Native FidelityFX games may require a
different destination filename; follow the upstream compatibility notes rather
than applying one filename rule to every game. RC9 remains experimental and
must be qualified per game.
Initial shader compilation can pause long enough to trigger a game's hang
detector.

Restore a target's exact original DLL with:

```bash
./bc250-mesh-shader.sh uninstall --fsr4 \
  "/path/to/OptiScaler/amd_fidelityfx_upscaler_dx12.dll"
```

### BC-250 GE-Proton

After FSR4 RADV reports active, install the integrated Proton route as the
logged-in Deck user:

```bash
./bc250-toolkit.sh proton-install
```

The manager downloads
`protonge-latest-bc250-11.6-166-x86_64.pkg.tar.zst` from the pinned upstream
release and requires SHA-256
`193e0e3b275024231bce8c0b01ed4220507257f86befc7c6fbb940e55a035640`.
It extracts only the compatibility tool and license payload. CachyOS package
metadata, pacman hooks, kernel modules, and host integration are not installed.
The resulting tool lives at
`~/.local/share/Steam/compatibilitytools.d/protonge-latest-bc250` and continues
to use Steam Linux Runtime rather than CachyOS host libraries.

Restart Steam, open an eligible game's compatibility settings, and select
**GE-Proton 11-6 (BC-250 FSR4)**. Do not enable DLL injection or FSR4 upgrade
for online or anti-cheat games; use ordinary Proton or set
`PROTON_FSR4_UPGRADE=0`. Installation and updates are transactional. Removal
deletes only this compatibility tool and preserves Steam prefixes, saves, and
game data:

```bash
./bc250-toolkit.sh proton-status
./bc250-toolkit.sh proton-update
./bc250-toolkit.sh proton-uninstall
```

The CachyOS native Proton package is intentionally not installed because it
bypasses Steam Linux Runtime and requires CachyOS host libraries. The alternate
CachyOS SLR package remains deferred until it can be benchmarked against the GE
build.

### Legacy FSR4 V3 Profile

New legacy V3 builds are retired. Existing recorded private profiles remain
detectable for safe cleanup and are never enabled globally. Remove one with
`./bc250-mesh-shader.sh uninstall --fsr4-legacy`. The old source pin and
checksum remain in the script only so existing lifecycle state can be validated
and removed without treating it as foreign data.

## GDDR6 Memory Temperature (Experimental)

The optional memory-temperature tool integrates
[`pan-Rijovich/bc250-memory-temperature`](https://github.com/pan-Rijovich/bc250-memory-temperature)
at pinned commit `b7e6bffcb5d592fc03edde375b7598ddc79aa846`. It installs a
176-byte Xtensa payload into live SMU SRAM, redirects Queue 3 / Message 5, and
reads the JEDEC GDDR6 MR3 temperature response from all eight memory chips.
This is not a kernel or Mesa patch, does not run at boot, and is reset by a cold
power cycle.

Open the guided workflow with `./bc250-toolkit.sh memory-temperature`, or use:

```bash
sudo ./bc250-memory-temperature.sh prepare
sudo ./bc250-memory-temperature.sh patch --acknowledge-smu-risk
sudo ./bc250-memory-temperature.sh read
sudo ./bc250-memory-temperature.sh read --json
sudo ./bc250-memory-temperature.sh restore --acknowledge-smu-risk
```

`prepare` downloads the exact upstream Python source, payload source, README,
MIT license, and prebuilt payload. Every consumed file has a fixed SHA-256 and
is staged root-owned under `/var/lib/bc250-memory-temperature`. The toolkit does
not download or redistribute the external Xtensa compiler. Before any live SMU
operation, the helper requires the Ariel root complex at `00:00.0` and GFX1013
GPU at `01:00.0`, pauses the GPU governor, and locks the shared PCI `0xB8/0xBC`
indirect window for the complete transaction.

Patch setup records the original handler and overwritten SRAM bytes, writes and
reads back the payload before redirecting the handler, and attempts rollback if
installation fails. Each temperature read re-attests the handler and complete
payload and rejects malformed, non-duplicated, or implausible MR3 responses.
Use `restore` before `purge`; a cold power cycle also returns the SMU to firmware
state, but the recorded backup is deliberately retained until explicitly
restored.

This payload is documented only for the **ASRock BC-250 P3.0 firmware layout**.
The toolkit cannot prove the SMU firmware revision from Linux, and upstream's
firmware-side UMC polling loops have no timeout. An incompatible or wedged
payload can cause memory corruption, filesystem/data corruption, crashes, an
unbootable system, or require a cold power cycle. Live writes therefore require
the exact `--acknowledge-smu-risk` flag and are never automatic.

## NCT6687D Fan-Control Driver

Install the optional enhanced hwmon driver on systems with a compatible
NCT6683, NCT6686D, or NCT6687-family Super-I/O controller:

```bash
./bc250-toolkit.sh fan-driver
```

The installer fetches
[`Fred78290/nct6687d`](https://github.com/Fred78290/nct6687d) at pinned commit
[`a49a8ab`](https://github.com/Fred78290/nct6687d/commit/a49a8abdfb6221772ecc836b3109e0cc338203cf),
verifies fixed hashes for the source and GPL license, builds as the logged-in
user, and installs only a `vermagic`-checked `nct6687.ko`. A root-owned source
snapshot and per-kernel module are retained for SteamOS update recovery. The
boot helper loads only a hash-verified module already staged for the running
kernel; it never downloads build input or runs Kbuild as root.

Successful probing creates an `nct6683`, `nct6686`, or `nct6687` hwmon device
with fan tachometers and writable `pwmN` / `pwmN_enable` controls. Writing `2`
to `pwmN_enable` restores firmware automatic mode. PWM zero can stop supported
fans, so userspace fan control must enforce temperature safeguards and restore
automatic mode before exiting.

The optional `--force-unknown` installer flag permits only unknown `0xdxxx`
chip IDs. It is deliberately not enabled by the toolkit action: using the wrong
register map can write unknown controller bits and leave firmware fan control
in an unsafe state. See [`nct6687d/README.md`](nct6687d/README.md) for status,
uninstall, hwmon discovery, and force-mode details.

## AIC8800 Class WiFi and Bluetooth Driver

Install the AIC8800 USB modules and firmware configuration:

```bash
sudo bash aic8800/steamdeck-setup.sh
```

The installer snapshots driver source, firmware, and verified per-kernel modules into root-owned storage. When Valve omitted headers, interactive setup prepares the exact source and builds AIC8800 without compiling the complete kernel if module versioning is disabled. The boot helper reuses staged modules or rebuilds from published headers, but never prepares kernel source as root.

The integrated driver includes AIC and OEM runtime IDs such as the UGREEN
`368b:8d88` variant. Known `a69c:572x` mass-storage personalities are switched
by SCSI eject, while `1111:1111` adapters use the required two-message sequence.

## SteamOS Updates

| Component | Update action |
|---|---|
| GPU compute-unit unlock | Run `sudo ./bc250-40cu.sh verify` after an update |
| Power management | The keep list retains tuning and GRUB defaults; the ACPI service validates and restores the `/boot` override and EFI GRUB config |
| RAM / VRAM split | CMOS persists independently; the keep list retains the TTM GRUB drop-in |
| Compressed swap | The keep list retains the selected zram configuration or the zswap tmpfiles configuration, setup service, and disk-swap unit; the swapfile persists in toolkit storage |
| CEC | Home configuration and allowlisted system integration carry forward |
| HDMI AC-3 encoding | The udev profile selector is retained; the WirePlumber fragment lives in the user's home directory |
| Patched AMDGPU module | Run `bc250-audio-fix/patch-driver.sh` after each kernel update to rebuild the kernel-specific module; the rebuild disables any retained scheduler policy until RADV setup is rerun |
| Mesa / RADV async compute | Rerun `bc250-mesh-shader.sh setup` after a SteamOS update to restore the root-owned driver, safety-gated environment generator, and scheduler policy |
| BC-250 GE-Proton | Lives in the user's Steam compatibility-tools directory and survives normal atomic updates; rerun `bc250-proton.sh status` to verify it |
| NCT6687 fan-control module | The boot helper restores only a verified module already staged for the running kernel; rerun setup interactively after a kernel change |
| AIC8800 modules | The boot helper reuses staged modules or published headers; rerun setup if it requests interactive source preparation |

Current installers preserve their configuration across normal atomic updates.

Privileged executables, firmware, and state live at `/var/lib/bc250-control`.
On SteamOS this is a bind mount backed by
`/home/.steamos/offload/var/lib/bc250-control`, following Valve's offload
layout. The backing path and all of its ancestors are root-owned, so the Deck
user cannot replace code later executed by a root service. The mount unit and
its enablement symlink are included in a dedicated atomic-update drop-in and
in every component drop-in.

`bc250-persistence-recovery.service` runs after `/home` is mounted and before
the toolkit's bind mount and other local filesystems finish starting. It checks
the root-owned backing path and repairs the bind-mount unit, enablement links,
and storage keep list before any root-backed component starts. The recovery
helper is addressed through the direct `/home/.steamos/offload` path, so it is
available even when the `/var/lib/bc250-control` mount is what needs repair.
Its boot scope is storage and retention infrastructure. Tuning recovery and
component enablement remain explicit setup actions.

```bash
./bc250-storage.sh
sudo bash ./bc250-storage.sh status
sudo bash ./bc250-storage.sh repair
```

`repair` is idempotent and performs installation-time migration as well as
repairing the recovery service, backing directory, mount unit, enablement
links, and atomic-update drop-in. At boot, the narrower
`repair-infrastructure` action requires intact backing data, the expected
mount, secure permissions, and an empty mountpoint.
The backing data survives normal atomic updates because `/home` is the shared
partition. Use a separate backup for factory-reset and reimage recovery.

### Persistence Commands

Run `./bc250-update-persistence.sh` to open the interactive menu with current protection status for each component.

| Example | Action |
|---|---|
| `sudo ./bc250-update-persistence.sh install compute` | Protect compute-unit configuration |
| `sudo ./bc250-update-persistence.sh install power` | Protect power and tuning configuration |
| `sudo ./bc250-update-persistence.sh install ram` | Protect the TTM dynamic VRAM setting |
| `sudo ./bc250-update-persistence.sh install swap` | Protect the selected compressed-swap profile |
| `sudo ./bc250-update-persistence.sh install cec` | Protect CEC system integration |
| `sudo ./bc250-update-persistence.sh install aic` | Protect AIC8800 system integration |
| `sudo ./bc250-update-persistence.sh install fan` | Protect NCT6687 fan-driver integration |
| `sudo ./bc250-update-persistence.sh install all` | Protect every component |
| `./bc250-update-persistence.sh status` | Show protection and recovery status |

### Recover an Earlier Installation

SteamOS stores edits from the previous image under `/etc/previous` and archives them in `/var/lib/steamos-atomupd/etc_backup`.

```bash
cd ~/.local/share/bc250-fixes/bc250-steamos
git pull
```

| Example | Action |
|---|---|
| `sudo ./bc250-update-persistence.sh recover compute` | Recover CU routing configuration |
| `sudo ./bc250-update-persistence.sh recover power` | Recover GPU and CPU tuning configuration |
| `sudo ./bc250-update-persistence.sh recover all` | Recover compute and power configuration |
| `sudo ./bc250-update-persistence.sh recover all --force` | Replace current configuration from the newest snapshot |

Run the normal component setup commands afterward to regenerate services for the current image.

## References

| Project | Resources | Used by |
|---|---|---|
| BC-250 40 CU Unlock | [Repository](https://github.com/duggasco/bc250-40cu-unlock) | Original Arch implementation for `bc250-40cu.sh` |
| BC-250 CU Live Manager | [Repository](https://github.com/WinnieLV/bc250-cu-live-manager) · [Script](https://github.com/WinnieLV/bc250-cu-live-manager/blob/main/bc250-cu-live-manager.sh) | `bc250-40cu.sh` |
| UMR | [Repository](https://gitlab.freedesktop.org/tomstdenis/umr) | `bc250-40cu.sh`, `bc250-cu-status.sh` |
| BC-250 ACPI Fix | [Original tables](https://github.com/bc250-collective/bc250-acpi-fix) · [8-core update](https://github.com/mendesrr/bc250-acpi-fix-updated-8c) · [guarded universal sources](acpi-tables/) | `bc250-power.sh` |
| Cyan Skillfish Governor | [Repository](https://github.com/filippor/cyan-skillfish-governor/tree/smu) · [Performance-mode script](https://github.com/filippor/cyan-skillfish-governor/blob/smu/scripts/cyan-skillfish-performance-mode) | `bc250-power.sh` |
| BC-250 SMU OC | [Repository](https://github.com/bc250-collective/bc250_smu_oc) | `bc250-power.sh` |
| CachyOS BC250 Toolkit | [Repository](https://github.com/redbeard1083/bc250-toolkit) | Design reference for the independently implemented zswap-backed disk profile; upstream code has no declared license |
| BC-250 CPU Core Unlock | [Linux helper](https://github.com/rw-r-r-0644/bc250-core-unlock) · [EFI source](https://github.com/Hexxeh/bc250-efi-core-unlock) · [EFI headers](https://github.com/yoppeh/efi) | Original SMU method and the optional pre-boot implementation adapted by `bc250-power.sh` |
| BC-250 Memory Config | [Repository](https://github.com/fanoush/bc250_memcfg) · [VRAM guide](https://elektricm.github.io/amd-bc250-docs/bios/vram/) | CMOS UMA utility fetched by `bc250-ram-split.sh` |
| BC-250 GDDR6 Memory Temperature | [Repository](https://github.com/pan-Rijovich/bc250-memory-temperature) · [integrated commit](https://github.com/pan-Rijovich/bc250-memory-temperature/commit/b7e6bffcb5d592fc03edde375b7598ddc79aa846) | Live SMU payload and MR3 temperature method by pan-Rijovich and bc250-collective, guarded by `bc250-memory-temperature.sh` |
| BC-250 GFX1013 Fix | [Repository](https://github.com/DryhoppedIPA/bc250-gfx1013-fix) · [integrated commit](https://github.com/DryhoppedIPA/bc250-gfx1013-fix/commit/d3e6dc062c34d2523db0abe5741d1f5b0dea00d9) | Kernel compute lifecycle repair and pinned alternate RADV build by DryhoppedIPA |
| OptiScaler | [Repository](https://github.com/optiscaler/OptiScaler) · [release](https://github.com/optiscaler/OptiScaler/releases/tag/v0.9.4) | Checksum-pinned per-game installation with collision backups and guarded rollback |
| BC-250 FSR4 RC9 | [Repository](https://github.com/daniel-h-0/bc250-fsr4-fork) · [release](https://github.com/daniel-h-0/bc250-fsr4-fork/releases/tag/v4.0.0-rc9) | Integrity-checked portable FSR 4.1.1 INT8 DLL with per-target rollback |
| CachyOS BC-250 GE-Proton and RADV | [Repository](https://github.com/MastaG/linux-cachyos-bc250) · [release assets](https://github.com/MastaG/linux-cachyos-bc250/releases/tag/repo) | Checksum-pinned GE compatibility tool and FSR4 Mesa patch series adapted for user-local SteamOS installation |
| BC-250 HDMI AC-3 encoding | [Implementation guide and scripts](https://github.com/rpf16rj/bc250-steamos-real-toolkit/tree/main/extras/hdmi-ac3-encoding) | ALSA `a52` routing and WirePlumber profile behavior adapted by `hdmi-ac3/hdmi-ac3.sh` |
| Valve kernel mirror | [Repository](https://github.com/Evlav/linux-integration) | `bc250-audio-fix/fetch-sources.sh` |
| SteamOS package mirror | [Package index](https://steamdeck-packages.steamos.cloud/archlinux-mirror/) | Audio, AIC8800, and NCT6687 build scripts; stable channels are discovered automatically |
| SteamOS atomic-update keep list | [Defaults](https://github.com/evlaV/steamos-customizations/blob/master/atomic-update/rauc/atomic-update-keep.conf.in) · [Drop-in example](https://github.com/evlaV/steamos-customizations/blob/master/atomic-update/rauc/example-additional-keep-list.conf.in) | `bc250-update-persistence.sh` |
| AIC8800 | [Repository](https://github.com/shenmintao/aic8800d80) · [integrated commit](https://github.com/shenmintao/aic8800d80/commit/e93a7d2b6b9634acefc2aae2891e787fb48fdb01) | `aic8800/steamdeck-setup.sh` |
| NCT6687D | [Repository](https://github.com/Fred78290/nct6687d) · [integrated commit](https://github.com/Fred78290/nct6687d/commit/a49a8abdfb6221772ecc836b3109e0cc338203cf) | `nct6687d/steamdeck-setup.sh` |
