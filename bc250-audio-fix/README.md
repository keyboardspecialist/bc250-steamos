# AMDGPU corrections

Corrects DisplayPort video/audio timing, Cyan Skillfish GPU telemetry, and the
GFX1013 compute-queue lifecycle through one patched `amdgpu` module. GPU
activity comes from GC status sampling and GFX clock comes from a validated
direct SMU query while retaining the firmware's published `SmuMetrics_t`
layout. The GFX1013 async-compute repair also requires patched Mesa RADV and
`amdgpu.sched_policy=2`. Module installation deliberately leaves that policy
off. `bc250-mesh-shader.sh setup` enables it only after the matching RADV
runtime is installed, preventing either half from being activated alone.

## Install

Run from the logged-in user session:

```bash
cd ~/.local/share/bc250-fixes/bc250-steamos/bc250-audio-fix
./patch-driver.sh
sudo reboot
```

`patch-driver.sh` restores the SteamOS build toolchain if an OS update removed it, fetches matching sources and kernel-specific dependencies, applies the host-tool compatibility backport needed by GCC 15/C23, builds the module, validates it, and invokes `sudo` for privileged steps. If Valve omitted the exact headers package, it builds the exact kernel source completely to generate the missing symbol inventory. That fallback can take hours and requires about 40 GiB of free temporary space.

## Kernel Support

| SteamOS | Kernel | Patch |
|---|---|---|
| 3.8.x | `linux-neptune-616` | [`bc250-dp-audio-clock-6.16.patch`](bc250-dp-audio-clock-6.16.patch) and [`0002-bc250-audio.patch`](0002-bc250-audio.patch) |
| 3.9.x | `linux-neptune-618` | [`0002-bc250-audio.patch`](0002-bc250-audio.patch) |

Both versions also apply the Cyan Skillfish telemetry patches. They preserve
the firmware's published metrics-table transfer size, query and validate the
GFX clock through the SMU, sample GPU activity from GC status, and apply the
three-part GFX1013 PASID/GFXOFF compute-queue repair.
The build selects the display patch from the running kernel and produces
`amdgpu.ko.zst` for that exact release.

### DisplayPort Audio

The 6.16 display patch backports upstream commit `9c7be0efa6f0`, routing
Cyan Skillfish through its DCN 2.01 clock manager so the driver uses the real
DP reference clock instead of the dcn3 730 MHz default.

`0002-bc250-audio.patch` backports stable-tagged upstream commit
[`ff209cd04845`](https://github.com/torvalds/linux/commit/ff209cd04845d819acc2fcc19b25904b4b7c3ea9).
BC-250 VBIOS reports DP reference-clock downspread, but hardware testing found
that the clock is not actually downspread. Correcting the audio DTO for the
reported spread therefore causes audio to drift from video. The upstream quirk
sets `ignore_dpref_ss` only for `AMD_APU_IS_CYAN_SKILLFISH2`; it does not rewrite
the clock manager's spread-spectrum state.

## GPU Metrics Patches

Display/audio and telemetry corrections share the same per-kernel `amdgpu`
override.

### Runtime Patch Set

| Patch | Operation |
|---|---|
| `bc250-cyan-skillfish-gpu-telemetry.patch` | Apply bounded GC activity sampling while retaining `SmuMetrics_t` |
| `bc250-cyan-skillfish-gfxclk.patch` | Apply range-checked direct SMU GFX-clock reporting |
| `0001-gfx1013-mmio-pasid-route.patch` | Route GFX1013 PASID invalidation through MMIO |
| `0002-gfx1013-compute-gfxoff-guard.patch` | Manage GFXOFF across the BC-250 compute lifecycle |
| `0003-gfx1013-scoped-pasid-type0.patch` | Scope type-0 invalidation to the GFX1013 PASID path |
| `bc250-gfx1013-attestation.patch` | Expose the loaded repair commit as a read-only module parameter |

The GFX1013 series is fetched from
[`DryhoppedIPA/bc250-gfx1013-fix`](https://github.com/DryhoppedIPA/bc250-gfx1013-fix)
at commit
[`d3e6dc0`](https://github.com/DryhoppedIPA/bc250-gfx1013-fix/commit/d3e6dc062c34d2523db0abe5741d1f5b0dea00d9)
and verified by SHA-256 before application. DryhoppedIPA developed the scoped
V33 kernel repair through direct BC-250 hardware testing. The fetched kernel
patches are `GPL-2.0-only`; they are not relicensed by this toolkit.

### Runtime Data

| Export | Source | Representation |
|---|---|---|
| `AMDGPU_PP_SENSOR_GPU_LOAD` | `GRBM_STATUS.GUI_ACTIVE` sampling | `0-100` percent |
| `gpu_metrics_v2_2.average_gfx_activity` | `GRBM_STATUS.GUI_ACTIVE` sampling | `0-10000` centipercent |
| `METRICS_CURR_GFXCLK` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |
| `gpu_metrics_v2_2.current_gfxclk` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |
| `gpu_metrics_v2_2.average_gfxclk_frequency` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |

### Activity Sampling

`gpu-telemetry` samples `GRBM_STATUS.GUI_ACTIVE` 32 times at 50-microsecond
intervals. The approximately 1.55-millisecond window supplies both activity
exports. The `average_gfx_activity` member name follows the
`gpu_metrics_v2_2` ABI; its value represents this sampling window.

### GFX Clock Query

`gfxclk` maps `SMU_MSG_GetGfxclkFrequency` to Cyan Skillfish firmware command
`PPSMC_MSG_GetGfxFrequency`. One SMU reply populates `METRICS_CURR_GFXCLK`,
`current_gfxclk`, and `average_gfxclk_frequency`. Query errors and replies
outside the supported 1000-2000 MHz range propagate to the metrics caller.

### Compute Queues

The GFX1013 repair keeps PASID TLB invalidation off the KIQ path, guards GFXOFF
during KFD compute activity, and uses the GFXHUB semaphore/type-0 transaction
only for BC-250 PASID invalidation. The three patches are mandatory and applied
in upstream order. The module installer does not change scheduler policy.

The kernel repair does not expose compute queues by itself. The optional,
recommended Mesa / RADV workflow in `bc250-mesh-shader.sh` builds the matching
userspace half that enables asynchronous compute. After installing RADV, it
writes `/etc/default/grub.d/bc250-amdgpu.cfg`, verifies exactly one
`amdgpu.sched_policy=2` on every generated Linux boot line, and registers the
drop-in for atomic updates. Its environment generator requires the installed
and active patched module plus active policy `2` before exposing RADV. Never
point an application at the alternate ICD while a stock kernel module is
active; upstream reports that combination can hang the GPU.

## Commands

| Command | Action |
|---|---|
| `./patch-driver.sh` | Fetch, build, validate, and install |
| `./patch-driver.sh status` | Report module overrides and scheduler-policy state |
| `./patch-driver.sh uninstall` | Noninteractively restore stock modules for all installed kernels |
| `./fetch-sources.sh` | Fetch the matching kernel source, symbols, and dependencies |
| `./ensure-build-prereqs.sh` | Restore a missing SteamOS host build toolchain |
| `./prepare-kernel.sh` | Prepare an exact Kbuild tree for external modules |
| `./build.sh` | Build and validate `amdgpu.ko.zst` |
| `./check-module.sh amdgpu.ko.zst` | Validate vermagic and ABI compatibility |
| `sudo ./install.sh` | Install the module and rebuild the initramfs |
| `sudo ./rollback.sh` | Restore the stock module for the running kernel |
| `sudo ./rollback.sh <kernel-release>` | Restore the stock module for a selected kernel |
| `sudo ./rollback.sh --all` | Restore stock modules for every installed kernel override |
| `sudo ./cleanup-other-slot.sh` | Restore the stock module in the alternate SteamOS slot |
| `./clean.sh` | Reset build state and retain downloaded packages |
| `./clean.sh --all` | Remove the kernel tree, dependencies, downloads, and generated builds |
| `./clean.sh --dry-run` | Preview cleanup |

Use a custom kernel-tree path as the final argument:

```bash
./patch-driver.sh /path/to/kernel-tree
./fetch-sources.sh /path/to/kernel-tree
./build.sh /path/to/kernel-tree
```

## Validation

The build and installer verify the source revision, kernel release, kernel configuration, and stock-module ABI before installation.

## Rollback

Restore the stock module and reboot:

```bash
cd ~/.local/share/bc250-fixes/bc250-steamos/bc250-audio-fix
./patch-driver.sh uninstall
sudo reboot
```

Recovery environments can target the installed kernel directly:

```bash
sudo ./rollback.sh 6.16.12-valve24.2-1-neptune-616-g57ac0765fe0d
```

For an override installed in the alternate A/B slot:

```bash
sudo ./cleanup-other-slot.sh
```

## SteamOS Updates

Rebuild after each kernel update:

```bash
cd ~/.local/share/bc250-fixes/bc250-steamos
git pull
cd bc250-audio-fix
./patch-driver.sh
sudo reboot
```

Source availability follows the Evlav kernel mirror. Run the command again after the target kernel commit appears in the mirror. When the commit exists but Valve's headers package does not, the full-build fallback runs automatically. Set `FULL_BUILD_JOBS` to control parallelism or `FULL_BUILD_MIN_FREE_GB` to adjust the default 40 GiB free-space guard.

The complete fallback remains mandatory for the AMDGPU override. AIC8800 may instead use `prepare-kernel.sh --wifi`, which runs `modules_prepare` without `Module.symvers` only when `CONFIG_MODVERSIONS` is explicitly disabled.

## Files

| File | Purpose |
|---|---|
| `patch-driver.sh` | Complete build and installation workflow |
| `fetch-sources.sh` | Source, symbol, and dependency acquisition |
| `ensure-build-prereqs.sh` | Conditional SteamOS host-toolchain installation |
| `prepare-kernel.sh` | Shared exact Kbuild preparation for Wi-Fi and GPU modules |
| `build.sh` | Patch application, module build, packaging, and validation |
| `bc250-libbpf-c23-const.patch` | GCC 15/C23 const-correctness backport for the kernel's libbpf host tool |
| `check-module.sh` | Vermagic and ABI validation |
| `install.sh` | Module override installation and initramfs generation |
| `boot-config.sh` | Persistent `amdgpu.sched_policy=2` GRUB configuration |
| `rollback.sh` | Stock-module restoration |
| `cleanup-other-slot.sh` | Alternate-slot restoration |
| `clean.sh` | Generated-state cleanup |
| `build-env.sh` | Local build environment |
| `bc250-dp-audio-clock-6.16.patch` | SteamOS 3.8.x DCN 2.01 clock-manager selection backport |
| `0002-bc250-audio.patch` | Stable-tagged upstream Cyan Skillfish DP-audio quirk |
| `bc250-cyan-skillfish-gpu-telemetry.patch` | Runtime GPU activity export using the published metrics layout |
| `bc250-cyan-skillfish-gfxclk.patch` | Runtime GFX clock export using a direct SMU query |
| `bc250-gfx1013-attestation.patch` | Read-only loaded-module identity for safe global RADV activation |
