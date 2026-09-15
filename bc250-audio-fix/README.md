# AMDGPU corrections

Corrects Cyan Skillfish 6-core and 8-core telemetry and the GFX1013 compute-queue lifecycle
through one patched `amdgpu` module. On older supported kernels it also
corrects DisplayPort video/audio timing. GPU
activity comes from cached GFX-ring fence sampling and GFX clock comes from a
cached direct SMU query. Stock, current 8-core BIOS, and legacy 8-core BIOS
metrics layouts are decoded without confusing fields. The GFX1013
async-compute repair also requires patched Mesa RADV and
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

Kernel 7.2 can also build experimental DCN201 DSC and HDMI 2.1 PCON support for
4K at 120 Hz. It is omitted by default because it may cause display instability.
The exact acknowledgement is required for both build and install:

```bash
./patch-driver.sh --acknowledge-dcn201-display-risk
```

The resulting module records its display composition. Installing an experimental
artifact directly also requires `install.sh --acknowledge-dcn201-display-risk`.

## Kernel Support

| SteamOS | Kernel | Patch |
|---|---|---|
| 3.8.x | `linux-neptune-616` | [`bc250-dp-audio-clock-6.16.patch`](bc250-dp-audio-clock-6.16.patch) and [`0002-bc250-audio.patch`](0002-bc250-audio.patch) |
| 3.9.x | `linux-neptune-618` | [`0002-bc250-audio.patch`](0002-bc250-audio.patch) |
| Valve 7.2 integration | `7.2` | No DisplayPort audio patch required; experimental DSC/HDMI 2.1 PCON is opt-in |

All supported versions apply the same pinned consolidated Cyan Skillfish
telemetry patch. It supports the stock 244-byte export and the current 284-byte
8-core firmware export, queries the GFX clock through the SMU, exposes the
350-2230 MHz SCLK range, samples GPU activity from emitted GFX-ring fences,
guards partial TTM cleanup, and applies the three-part
GFX1013 PASID/GFXOFF compute-queue repair. They also carry an experimental KFD
HWS runlist TLB-flush workaround, disabled by default.
The build selects the kernel-specific patch set and produces
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

For receivers that require a compressed surround bitstream, the separate
[`hdmi-ac3`](../hdmi-ac3/) component enables real-time Dolby Digital 5.1 after
this kernel correction is installed and active. Its ALSA and WirePlumber setup
is adapted from the
[`rpf16rj/bc250-steamos-real-toolkit` HDMI AC-3 guide](https://github.com/rpf16rj/bc250-steamos-real-toolkit/tree/main/extras/hdmi-ac3-encoding).

## GPU Metrics Patches

Display/audio and telemetry corrections share the same per-kernel `amdgpu`
override.

### Runtime Patch Set

| Patch | Operation |
|---|---|
| MastaG `0001-bc250-8core-telemetry-gpu-activity.patch` | Decode 6/8-core SMU layouts, cache telemetry and GFXCLK, and sample GFX-ring activity |
| `bc250-cyan-skillfish-sclk-range.patch` | Widen the kernel SCLK interface to 350-2230 MHz |
| `bc250-amdgpu-ttm-null-page-guard.patch` | Safely clean up partially populated TTM page vectors |
| `0001-gfx1013-mmio-pasid-route.patch` | Route GFX1013 PASID invalidation through MMIO |
| `0002-gfx1013-compute-gfxoff-guard.patch` | Manage GFXOFF across the BC-250 compute lifecycle |
| `0003-gfx1013-scoped-pasid-type0.patch` | Scope type-0 invalidation to the GFX1013 PASID path |
| `bc250-gfx1013-attestation.patch` | Expose the loaded repair commit as a read-only module parameter |
| `bc250-kfd-flush-by-runlist-6.16.patch` / `6.18.patch` | Add the opt-in BC-250 KFD HWS runlist TLB flush; 7.2 retains the 6.18 patch API |
| `bc250-dcn201-pcon-hdmi21.patch` | Opt-in DP-to-HDMI 2.1 PCON support on DCN201 for kernel 7.2 |
| `bc250-dcn201-dsc-enable.patch` | Opt-in DSC resources on DCN201 for kernel 7.2 |

The consolidated telemetry patch is pinned to MastaG commit
[`622ed9e`](https://github.com/MastaG/linux-cachyos-bc250/commit/622ed9e56107f8d13a19848ed06b7a7241ff6cd3), checksum-verified, and normalized
only for the feature table, allocation helper, socket-power units, and sysfs
callback context that differ between kernels 6.16/6.18 and 7.2. The SCLK and
TTM changes are adapted from the stable `linux-cachyos` patch set
in [`MastaG/linux-cachyos-bc250`](https://github.com/MastaG/linux-cachyos-bc250/tree/main/patches/linux-cachyos).
The kernel SCLK interface and toolkit governor use the same conservative
350 MHz floor.

The KFD runlist workaround is adapted from the stable `linux-cachyos` patch set
in the same repository. Separate 6.16 and 6.18 variants account for the KFD TLB
flush API change; Valve 7.2 retains the 6.18 API. They are applied with zero
fuzz.

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
| `AMDGPU_PP_SENSOR_GPU_LOAD` | emitted GFX-ring fence sampling | `0-100` percent |
| `gpu_metrics_v2_2.average_gfx_activity` | emitted GFX-ring fence sampling | `0-10000` centipercent |
| `METRICS_CURR_GFXCLK` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |
| `gpu_metrics_v2_2.current_gfxclk` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |
| `gpu_metrics_v2_2.average_gfxclk_frequency` | `PPSMC_MSG_GetGfxFrequency` | Point-in-time MHz |

### Activity Sampling

The consolidated implementation samples the GFX ring's emitted-fence count 32
times at 50-microsecond intervals. `GRBM_STATUS` is deliberately not used: on
Cyan Skillfish it can return the all-ones bus-fault sentinel and falsely report
100% load. A 25 ms cache lets adjacent sensor and `gpu_metrics` reads share the
approximately 1.55-millisecond sample window.

### GFX Clock Query

The telemetry patch maps `SMU_MSG_GetGfxclkFrequency` to Cyan Skillfish firmware
command `PPSMC_MSG_GetGfxFrequency` and caches successful mailbox replies for 25
ms. A valid table GFXCLK is the fallback when available; the legacy 8-core
layout has no such slot. The widened kernel range separately lets SMU governors
use their lower-power and overclocking ranges through the frequency interface.

### 8-Core Layouts

Physical-core detection selects the stock 6-core or an 8-core layout
automatically. Builds for older Valve 6.16/6.18 kernels preserve their
stock-BIOS behavior by defaulting to the partial 116-byte 8-core mapping; set
`amdgpu.cs_legacy_8core_metrics=0` when using one of those kernels with the
current SMU-patched community BIOS. Valve 7.2 builds default to the widened
mapping; set `amdgpu.cs_legacy_8core_metrics=1` there for an older core-unlock
BIOS. Missing fields remain unsupported rather than being decoded from
unrelated offsets. Diagnostic full telemetry through `pp_dpm_socclk` is opt-in
with `amdgpu.cs_full_telemetry=1`.

### Compute Queues

The GFX1013 repair keeps PASID TLB invalidation off the KIQ path, guards GFXOFF
during KFD compute activity, and uses the GFXHUB semaphore/type-0 transaction
only for BC-250 PASID invalidation. The three patches are mandatory and applied
in upstream order. A stable TTM guard also handles partially populated page
vectors during allocation-failure cleanup. The module installer does not change
scheduler policy.

The kernel repair does not expose compute queues by itself. The optional,
recommended Mesa / RADV workflow in `bc250-mesh-shader.sh` builds the matching
userspace half that enables asynchronous compute. After installing RADV, it
writes `/etc/default/grub.d/bc250-amdgpu.cfg`, verifies exactly one
`amdgpu.sched_policy=2` on every generated Linux boot line, and registers the
drop-in for atomic updates. Its environment generator requires the installed
and active patched module plus active policy `2` before exposing RADV. Never
point an application at the alternate ICD while a stock kernel module is
active; upstream reports that combination can hang the GPU.

### Experimental KFD HWS TLB Flush

The module includes an opt-in workaround for stale ROCm/KFD translations after
GPU memory is unmapped. It rebuilds an already-active HWS runlist only on the
BC-250 PCI device with GFX1013, and does nothing under MES, with no active
runlist, or with `amdgpu.sched_policy=2` (`KFD_SCHED_POLICY_NO_HWS`). The module
parameter defaults to off.

Toggle the persistent boot option from **Core system > Advanced AMDGPU boot
options > KFD runlist workaround**
or with `../bc250-toolkit.sh kfd-runlist`. Enabling writes
`amdgpu.bc250_flush_by_runlist=1` and requires a reboot. The toolkit refuses to
enable it while policy `2` is configured. RADV setup can replace the workaround
with policy `2`; the two options are never emitted together.

## Commands

| Command | Action |
|---|---|
| `./patch-driver.sh` | Fetch, build, validate, and install |
| `./patch-driver.sh status` | Report module overrides and scheduler-policy state |
| `../bc250-toolkit.sh kfd-runlist` | Toggle the experimental persistent KFD HWS runlist workaround |
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

The build and installer verify the source revision, telemetry composition,
kernel release, kernel configuration, and stock-module ABI before installation.
The loaded module exposes `bc250_amdgpu_revision=mastag-8core-622ed9e-r1` in
addition to the GFX1013 commit. Readiness requires both, so a newly installed
module cannot be reported ready while the previous module remains loaded.

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
| `mkinitcpio-compat.sh` | Initramfs generation with SteamOS 7.2 BLAKE2 hook compatibility |
| `boot-config.sh` | Persistent `amdgpu.sched_policy=2` GRUB configuration |
| `rollback.sh` | Stock-module restoration |
| `cleanup-other-slot.sh` | Alternate-slot restoration |
| `clean.sh` | Generated-state cleanup |
| `build-env.sh` | Local build environment |
| `bc250-dp-audio-clock-6.16.patch` | SteamOS 3.8.x DCN 2.01 clock-manager selection backport |
| `0002-bc250-audio.patch` | Stable-tagged upstream Cyan Skillfish DP-audio quirk |
| Pinned MastaG consolidated telemetry patch | Runtime 6/8-core telemetry, GFX clock, and GPU activity exports |
| `bc250-gfx1013-attestation.patch` | Read-only loaded-module compute and telemetry-composition identity |
