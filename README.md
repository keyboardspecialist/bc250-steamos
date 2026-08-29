# bc250-steamos

Management tools for SteamOS 3.8.x and 3.9.x.

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
| AMDGPU kernel fixes | `./bc250-toolkit.sh amdgpu`, then reboot |
| Mesa / RADV async-compute patch (optional, highly recommended) | `./bc250-toolkit.sh radv`, then reboot |
| Power management | `sudo ./bc250-power.sh all`, then `sudo ./bc250-power.sh enable` |
| RAM / VRAM split | `./bc250-ram-split.sh` |
| Compressed swap (optional) | `sudo ./bc250-swap.sh`, then choose zram or zswap-backed disk swap |
| GPU compute-unit unlock | `sudo ./bc250-40cu.sh` |
| CEC | `./bc250-cec.sh setup` |
| HDMI Dolby Digital 5.1 (optional) | **Display & Connectivity > HDMI audio** or `./hdmi-ac3/hdmi-ac3.sh install` |
| AIC8800 | `sudo bash ./aic8800/steamdeck-setup.sh` |
| Decky plugin | `bash ./decky-plugin/install.sh` |
| Plasma desktop control | `bash ./desktop-control/install.sh install` |
| BC250 Trainer | `./bc250-toolkit.sh trainer` |
| Compressed swap | `sudo ./bc250-swap.sh install zram` or `sudo ./bc250-swap.sh install zswap` |
| Persistent storage and recovery | Automatic with each setup workflow; `./bc250-storage.sh` opens its menu |
| Verification | `sudo ./bc250-storage.sh status` |

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
| [`bc250-toolkit.sh`](#toolkit-menu) | Unified menu and read-only status overview for all toolkit components |
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
| [`bc250-mesh-shader.sh`](#mesa--radv-async-compute-patch-optional-recommended) | Optional, recommended Mesa / RADV async-compute driver enabled globally for the user session |
| [`aic8800/`](#wifi-and-bluetooth) | AIC8800 USB WiFi and Bluetooth driver |

The unified launcher and individual component scripts remain independently usable. Use the child scripts directly for command-line automation.

## Toolkit Menu

Run `./bc250-toolkit.sh` without `sudo`. The main menu groups drivers, hardware
unlocks, power, memory, CEC, storage/update integration, control interfaces,
and installed-component maintenance. Child menus return to the toolkit when
they exit. Installer and build entries require confirmation before starting
their longer setup workflows.
Each child requests administrator access only when needed.

| Command | Action |
|---|---|
| `./bc250-toolkit.sh` | Open the unified interactive menu |
| `./bc250-toolkit.sh setup` | Open the status-aware guided setup checklist |
| `./bc250-toolkit.sh status` | Show the read-only component status overview |
| `./bc250-toolkit.sh inventory-json` | Emit versioned lifecycle state for the native Trainer dashboard |
| `./bc250-toolkit.sh action OPERATION_ID` | Run one fixed dashboard action without opening a TUI |
| `./bc250-toolkit.sh drivers` | Open AMDGPU, Mesa / RADV, and AIC8800 driver setup |
| `./bc250-toolkit.sh unlocks` | Open GPU compute-unit and CPU core unlock setup |
| `./bc250-toolkit.sh power` | Open a component menu directly |
| `./bc250-toolkit.sh ram` | Open RAM / VRAM split settings |
| `./bc250-toolkit.sh swap` | Choose a compressed swap profile |
| `./bc250-toolkit.sh amdgpu` | Build the AMDGPU kernel fixes |
| `./bc250-toolkit.sh radv` | Open the global Mesa / RADV async-compute menu |
| `./bc250-toolkit.sh audio-output` | Open HDMI AC-3 enable and stereo-revert options |
| `./bc250-toolkit.sh trainer` | Download, verify, and install the latest native BC250 Trainer release |
| `./bc250-toolkit.sh manage` | Review and remove installed components |
| `./bc250-toolkit.sh help` | List launcher commands and components |

`action` accepts only the operation IDs printed by `help`; it does not accept
arbitrary scripts or arguments. These machine-facing commands back the native
Trainer dashboard. Normal interactive use should continue through the toolkit
menu.

### Guided Setup

The `Start here - Guided setup` menu organizes initial setup around dependency
and restart boundaries rather than exposing every tuning option at once:

1. Install the AMDGPU kernel fixes, then reboot.
2. Install the ACPI and GPU-governor foundation. Reboot for ACPI, load-test the
   governor, and only then enable it at boot.
3. Install the memory helper and choose the CMOS minimum and dynamic TTM limit.
4. Optionally follow the staged GPU-CU or CPU-core unlock workflows, including
   their reboot and stability tests.
5. Optionally build the Mesa / RADV async-compute patch after AMDGPU is active,
   then reboot so RADV and `amdgpu.sched_policy=2` activate together.
6. Add matching devices and a control UI, then run the complete status report.

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
AMDGPU, and loaded AIC8800 rollback may require a reboot. After every
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

sudo ./bc250-power.sh ramp set 500
sudo ./bc250-power.sh ramp reset
```

Frequency, voltage, load-target, and ramp settings persist across boots. The
default voltage curve spans 300-2230 MHz; points use a 700-1050 mV range and
must have increasing frequencies with nondecreasing voltages. Curve updates
are atomic and restore the prior config/runtime if governor reload or saved
frequency replay fails. The guided TUI can list, add, edit, and remove points.

`[frequency-range] max` in `config.toml` is the adaptive ceiling, not a fixed
clock. The active clock rises toward that ceiling only when GPU load exceeds
the configured upper load target. `freq 1800` pins 1800 MHz, while
`freq 0 1800` keeps adaptive scaling with an 1800 MHz ceiling.

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
7.2 does not need the legacy audio patches. Then open **Display & Connectivity
> HDMI audio** and choose **Enable HDMI AC-3 5.1**.

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

The patches preserve the Cyan Skillfish firmware metrics layout, query GFX
frequency directly from the SMU, add GPU utilization reporting, and repair the
GFX1013 compute-queue lifecycle. On 6.16 and 6.18 they also apply the required
DisplayPort audio corrections; Valve 7.2 needs neither legacy audio patch.
Builds are matched to the running kernel and checked for vermagic and ABI compatibility
before installation. If Valve omitted the matching headers, the toolkit can
generate the required symbols with a complete exact-source kernel build.

The module also carries a disabled-by-default KFD HWS runlist TLB-flush
workaround for stale ROCm mappings. Enable it only from **Drivers > KFD HWS
runlist TLB flush**. It requires hardware scheduling and is mutually exclusive
with the RADV workflow's `amdgpu.sched_policy=2`; enabling RADV policy replaces
the workaround rather than combining both boot options.

Rollback:

```bash
sudo ./rollback.sh
```

See [`bc250-audio-fix/README.md`](bc250-audio-fix/README.md) for kernel support and build controls.

## Mesa / RADV Async-Compute Patch (Optional, Recommended)

This optional but highly recommended patch builds the Mesa/RADV half of
[`DryhoppedIPA/bc250-gfx1013-fix`](https://github.com/DryhoppedIPA/bc250-gfx1013-fix)
as a separate Vulkan ICD to enable GFX1013 asynchronous compute. The matching
`bc250-audio-fix` AMDGPU kernel module must be built, installed, selected, and
active first. Setup refuses to continue unless all installed module markers,
the selected `modinfo` path, and the loaded repair attestation agree. Use the
toolkit's **Drivers** menu: install **AMDGPU kernel fixes**, reboot, and then
open **Mesa / RADV async-compute patch**. The RADV-only build normally takes
about 3-5 minutes.

Open the menu as the logged-in user:

```bash
./bc250-mesh-shader.sh
```

Or use the CLI:

```bash
./bc250-mesh-shader.sh setup
./bc250-mesh-shader.sh setup --fsr4
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
stock `radeon_icd.i686.json` and `lib32-vulkan-radeon`. This also supports games
that launch a mixture of 64-bit and 32-bit Vulkan processes.

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

The upstream alpha build itself remains x86-64 only. Its compute and mesh
changes therefore do not apply to 32-bit processes; those processes use the
stock SteamOS RADV fallback instead.

### Experimental FSR4 Profile

An additional upstream FSR4 V3 profile can be built explicitly:

```bash
./bc250-mesh-shader.sh setup --fsr4
```

FSR4 setup can be selected first. If the default async-compute RADV runtime is
missing or stale, setup builds and installs it automatically. The base output
is preserved after DryhoppedIPA patches `0001`-`0003`. Because upstream FSR4 V3
already contains the compute-queue changes from `0001`, setup then reverses
`0001` in the source tree and applies the exact V3 patch. Non-overlapping mesh
and query patches `0002` and `0003` remain applied, and Ninja incrementally
rebuilds the affected targets for the private driver. An integrity-checked
cached base is reused only while it still matches the installed global driver.

This profile is disabled by default. The private FSR4 artifact installs entirely
under `~/.local/share/bc250-mesh-shader/fsr4` and does not replace the global
driver or alter the systemd environment generator after any required base
runtime bootstrap. Enable it for one Steam game with the launch option printed
by setup:

```text
$HOME/.local/share/bc250-mesh-shader/fsr4/bc250-fsr4-run %command%
```

The launcher rechecks the selected AMDGPU module, all module attestations,
loaded repair revision, scheduler policy, profile hashes, and 64/32-bit ICD
routing before starting the game. Remove only this profile with
`./bc250-mesh-shader.sh uninstall --fsr4`.

The two installed artifacts remain distinct: the global driver contains
DryhoppedIPA patches `0001`-`0003`, while the per-game driver contains upstream
FSR4 V3 plus DryhoppedIPA patches `0002` and `0003`. Each has its own ICD and
manifest even though setup shares one incremental build tree.

When FSR4 setup was selected first, it has already installed the global
async-compute artifact before producing the private driver. Selecting the
async-compute setup option afterward verifies that installed artifact and its
kernel prerequisites, restores scheduler policy if necessary, and reports it
ready without rebuilding Mesa. If an async rebuild is genuinely required, it
replaces only the global artifact. The private FSR4 driver, ICD, runner, and
manifest are never removed or overwritten by async setup, and their resulting
validation state is reported explicitly.

Setup fetches `bc250-fsr4-v3.patch` from
[`dmorazasanchez/bc250-fsr4`](https://github.com/dmorazasanchez/bc250-fsr4)
at immutable commit `741ff3e369026f34820c41a846cf5e55d08e2a61` and verifies SHA-256
`7fde37fad572b4ba4dcac6052792d10d8d3df65982b01236c63a3eff0a25d225`.
The patch is not copied into this repository. Its upstream repository currently
declares no license; users should account for that before redistribution.

V3 implements deferred signed-dot optimization, software signed i24 MUL/MAD
lowering, FSR4 wrapper fusion, tuned dense-reduction strategies, and the tested
ACO spill policy. It does not use the BC-250's broken native signed packed-dot
instruction. V3 also includes an optional `RADV_GFX103` override; the toolkit
does not set that variable. Upstream reports 63 FPS in its Cyberpunk 2077 test
and no new spill or resident-wave regressions across its 64 captured shaders.
The toolkit has not independently reproduced those results. Treat the profile
as experimental: games may regress, corrupt frames, hang, or reset the GPU.

The upstream series is pinned to commit
[`d3e6dc0`](https://github.com/DryhoppedIPA/bc250-gfx1013-fix/commit/d3e6dc062c34d2523db0abe5741d1f5b0dea00d9),
tagged `v0.2.0-alpha`. DryhoppedIPA developed the scoped V33 kernel repair and
the narrow GFX1013 compute, mesh, and task implementation through direct
hardware testing. Setup downloads all three Mesa patches and the pristine
final `mesa-26.2.0` source at commit `9f0a761`. Setup verifies the Git commit,
the downloaded patch and libdrm SHA-256 hashes, and requires zero-fuzz
patch application. The Mesa patches retain their upstream MIT license; the
kernel patches are `GPL-2.0-only`.

This remains alpha hardware research tested upstream on one board, not a full
Vulkan conformance result. The toolkit restores SteamOS read-only-root state,
records installed hashes, and transactionally restores a prior profile if its
installation fails. If first-run FSR4 compilation fails after the async profile
was installed successfully, that valid prerequisite remains installed. Retry
FSR4 setup; invalid intermediate build state falls back to a clean base build.

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
| Mesa / RADV async-compute patch | Rerun `bc250-mesh-shader.sh setup` after a SteamOS update to restore the root-owned driver, safety-gated environment generator, and scheduler policy |
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
| BC-250 GFX1013 Fix | [Repository](https://github.com/DryhoppedIPA/bc250-gfx1013-fix) · [integrated commit](https://github.com/DryhoppedIPA/bc250-gfx1013-fix/commit/d3e6dc062c34d2523db0abe5741d1f5b0dea00d9) | Kernel compute lifecycle repair and pinned alternate RADV build by DryhoppedIPA |
| BC-250 FSR4 experiment | [Repository](https://github.com/dmorazasanchez/bc250-fsr4) · [integrated commit](https://github.com/dmorazasanchez/bc250-fsr4/commit/741ff3e369026f34820c41a846cf5e55d08e2a61) | Integrity-checked upstream V3 patch fetched for the optional private FSR4 RADV profile |
| BC-250 HDMI AC-3 encoding | [Implementation guide and scripts](https://github.com/rpf16rj/bc250-steamos-real-toolkit/tree/main/extras/hdmi-ac3-encoding) | ALSA `a52` routing and WirePlumber profile behavior adapted by `hdmi-ac3/hdmi-ac3.sh` |
| Valve kernel mirror | [Repository](https://github.com/Evlav/linux-integration) | `bc250-audio-fix/fetch-sources.sh` |
| SteamOS package mirror | [Package index](https://steamdeck-packages.steamos.cloud/archlinux-mirror/) | Audio-driver and AIC8800 build scripts; stable channels are discovered automatically |
| SteamOS atomic-update keep list | [Defaults](https://github.com/evlaV/steamos-customizations/blob/master/atomic-update/rauc/atomic-update-keep.conf.in) · [Drop-in example](https://github.com/evlaV/steamos-customizations/blob/master/atomic-update/rauc/example-additional-keep-list.conf.in) | `bc250-update-persistence.sh` |
| AIC8800 | [Repository](https://github.com/shenmintao/aic8800d80) · [integrated commit](https://github.com/shenmintao/aic8800d80/commit/e93a7d2b6b9634acefc2aae2891e787fb48fdb01) | `aic8800/steamdeck-setup.sh` |
