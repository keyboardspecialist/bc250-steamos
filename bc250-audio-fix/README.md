# bc250-audio-fix — DP output clock fix for the BC-250

Patched `amdgpu.ko` for the ASRock BC-250 on SteamOS. Fixes DisplayPort output
running slow: **both video and audio played at ~82% speed** — everything in
slow motion, audio pitched down.

**This branch (`dcn201`)**: hunk 2 is the upstream-faithful fix — the same
reorder as mainline commit `9c7be0efa6f0` ("drm/amd: fix dcn 2.01 check",
merged March 2026, first release after v6.19), which routes Cyan Skillfish to
the dcn201 clock manager it was always meant to use. The module here is built
and ABI-verified but **not yet boot-tested**; the conservative variant on
`master` (keep dcn3 clk_mgr, pin dprefclk to 600 MHz) is the one **confirmed
working** on `6.16.12-valve24.2-1-neptune-616-g57ac0765fe0d` as of 2026-07-05.

## The bug

The BC-250's GPU (Cyan Skillfish, DCN 2.0.1) reports a hardware revision that
falls into the *Beige Goby* range check in
`drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c`, so it is handed the dcn3
clock manager. That clock manager starts from a hardcoded DP reference clock
(dprefclk) of **730 MHz** and normally corrects it from a register dump — but
the register dump is unimplemented for this ASIC, so 730 MHz sticks. The real
reference clock is **600 MHz**.

Every DP DTO (the divider that generates the pixel and audio clocks) is
programmed as `rate × dprefclk_actual / dprefclk_assumed`, so the entire DP
output — pixel clock and audio clock alike — ran at 600/730 ≈ **82% of the
requested rate**. Video played in slow motion and audio with it, audibly slow
and pitched flat.

A second, smaller skew: the BC-250 VBIOS carries no DP spread-spectrum entry,
and the driver's fallback SS data would also nudge the DP reference clock and
audio DTO.

## The fix

`bc250-dp-audio-clock.patch` — two hunks against Valve's kernel tree
(`linux-neptune-616`, commit `57ac0765fe0d`):

1. **`dc/clk_mgr/clk_mgr.c`** — check `dce_version == DCN_VERSION_2_01`
   *before* the Beige Goby rev-range check, so Cyan Skillfish gets
   `dcn201_clk_mgr_construct` (backport of upstream `9c7be0efa6f0`). The
   dcn201 clock manager reads the real dprefclk from the chip's own CLK
   registers (`CLK4_CLK2_CURRENT_CNT`, falling back to 600 MHz — the same
   value the master-branch variant pins) and actively manages
   dispclk/dppclk via DENTIST, which the mis-selected dcn3 clock manager
   never did on this ASIC (its SMU handshake fails, so its update path is
   inert).
2. **`amdgpu_dm/amdgpu_dm.c`** — set `ignore_dpref_ss` for DCE IP 2.0.3 so the
   bogus fallback spread-spectrum data is not applied.

The patch is small; getting a module that's safe to boot is the harder part.
See "Why the build setup matters" below.

## What was affected

The bug lives in the DP stream clocking — on DisplayPort the pixel and audio
clocks are synthesized by DTOs programmed as a ratio against dprefclk — so
everything that leaves the GPU as native DP was affected, and the fix covers
all of it:

- **Straight DP to a DP monitor** — any resolution, refresh rate, or audio
  format; the DTO formula scales everything from the same reference.
- **Active DP→HDMI converters** — the GPU still outputs native DP and the
  converter re-encodes downstream, so this path was broken before and is
  fixed now.
- **Any BC-250 board** — the 600 MHz reference is a property of the Cyan
  Skillfish ASIC design, not one unit, and the patch only touches DCN 2.0.1
  hardware.

**Passive DP→HDMI adapters are a different electrical path.** They rely on
dual-mode DP (DP++): the port itself switches to emitting TMDS — actual HDMI
signaling — and the DP link layer isn't used. The pixel clock then comes
straight from the PHY PLL rather than a dprefclk-referenced DTO, and audio
timing rides on the TMDS clock via HDMI audio clock regeneration. dprefclk
isn't in that chain, so the 82%-speed bug should never have manifested through
a passive adapter, and the fix neither helps nor risks anything there.

(Untested caveats: this follows from the DCN clocking architecture, not from
testing a passive adapter on this board — and passive adapters only work at
all if the port wires up DP++. Slow-motion playback through a passive adapter
would be a separate bug, not a gap in this fix.)

## Why the build setup matters

A kernel module built out-of-tree must match the running kernel in *two*
independent ways, and on SteamOS both are easy to get silently wrong. Since
this module replaces the GPU driver via an `updates/` override baked into the
initramfs, a bad build doesn't just fail — it can leave the machine with no
display at boot.

**1. Exact source version.** The module must be built from the source of the
kernel that's actually running (Valve ships point releases like `valve24.1`
vs `valve24.2-1` that are not interchangeable). A version mismatch is the
benign failure: modprobe rejects the module on its vermagic string — but with
the override in the initramfs, "rejected" still means booting without a GPU
driver.

**2. Exact kernel config.** This is the dangerous one, because nothing checks
it. The SteamOS kernel has `CONFIG_SCHED_CLASS_EXT=y`, which depends on
`CONFIG_DEBUG_INFO_BTF` — and Kconfig **silently disables BTF whenever
`pahole` is not on PATH**. Any `olddefconfig`/`syncconfig` run does this
without a word (syncconfig even rewrites `.config` behind your back
mid-build). sched_ext adds a 256-byte member in the middle of `task_struct`,
so a module built without it has every `task_struct` field offset 0x100 short
of the running kernel's.

Nothing catches that at load time: vermagic is only a release-string compare,
and `CONFIG_MODVERSIONS` is off in this kernel, so there is **no ABI check at
all**. The module loads cleanly and then hangs before amdgpu's first printk —
black screen, zero log output, nothing to debug from.

Guards in this repo that close both holes:

- Guard 1 in `install.sh` refuses to install a module whose vermagic doesn't
  equal `uname -r`, so a version-mismatched build can never reach the
  initramfs.
- `build-env.sh` puts the bundled `pahole`/`bc` on PATH and **fails loudly**
  if they're missing. Source it before *any* `make` in the kernel tree.
- After any config regen, verify `CONFIG_SCHED_CLASS_EXT=y` survived in both
  `.config` and (after `modules_prepare`) `include/generated/autoconf.h`.
- Guard 2 in `install.sh` does a real ABI check: it disassembles
  `amdgpu_vm_set_task_info` in the candidate and stock modules and diffs the
  `task_struct` field offsets — a mis-built module reads `current->pid` at
  0x9d0 where the stock module reads 0xad0, so config drift is caught before
  it can touch the boot path.

Related Kbuild footguns to keep in mind: after fixing a config, syncconfig
may regenerate `auto.conf` without touching the per-option
`include/config/` stamp files, so stale objects **don't rebuild** — run
`make M=... clean` after any config change. And BTF implies DEBUG_INFO, so the
built module carries DWARF; `strip --strip-debug` before packaging
(591 MB → 27.5 MB, matching stock minus the `.BTF` section).

## Files

| File | Purpose |
|---|---|
| `bc250-dp-audio-clock.patch` | The two-hunk source patch |
| `amdgpu.ko.zst` | Built, ABI-verified module for `6.16.12-valve24.2-1-neptune-616-g57ac0765fe0d` |
| `install.sh` | Installs to `/usr/lib/modules/$(uname -r)/updates/`, runs both guards, rebuilds initramfs |
| `rollback.sh` | Removes the override and restores the stock module |
| `build-env.sh` | Build-time PATH/env setup for the bundled deps (pahole, bc, libelf, openssl) |
| `cleanup-other-slot.sh` | Cleans a stale override out of the other SteamOS A/B slot |

The kernel trees, source tarballs, dep packages, build logs, and intermediate
modules are gitignored — they're multi-gigabyte and fully reproducible.

## Install

```
sudo ./install.sh     # prints "vermagic OK" and "ABI OK", then rebuilds initramfs
# reboot, then confirm video and audio play at normal speed over DisplayPort
```

If anything misbehaves: `sudo ./rollback.sh` restores the stock module. Worst
case is soft now — a behaviorally-buggy module that passes both guards is
still ABI-consistent, so it will load and you keep a working GPU at boot.

The module is tied to the exact kernel release above; after a SteamOS update
it must be rebuilt (install.sh will refuse to install it against a different
kernel).

## Rebuilding after a SteamOS update

1. Fetch Valve's source package for the *running* kernel
   (`linux-neptune-616`, version matching `uname -r`) and check out the
   commit hash embedded in `uname -r`.
2. Extract the Arch packages for `pahole`, `bc`, `libelf`, `openssl`, `zlib`
   into `deps/` (pacman `.pkg.tar.zst` files extracted with `tar -x`).
3. `source build-env.sh` — must print nothing; a FATAL means fix deps first.
4. Configure from the running kernel (`zcat /proc/config.gz > .config`,
   `make olddefconfig`), then **verify**
   `grep '^CONFIG_SCHED_CLASS_EXT=y' .config`.
5. Apply `bc250-dp-audio-clock.patch`, `make modules_prepare`, re-verify the
   option in `include/generated/autoconf.h`, then
   `make M=drivers/gpu/drm/amd/amdgpu modules`.
6. `strip --strip-debug amdgpu.ko && zstd -19 amdgpu.ko`, replace
   `amdgpu.ko.zst` here, run `sudo ./install.sh` (the guards re-check
   everything).
