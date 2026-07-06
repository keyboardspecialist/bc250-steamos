# bc250-audio-fix — DP output clock fix for the BC-250

Patched `amdgpu.ko` for the ASRock BC-250 on SteamOS. Fixes DisplayPort output
running slow: **both video and audio played at ~82% speed** — everything in
slow motion, audio pitched down. **Confirmed working** on
`6.16.12-valve24.2-1-neptune-616-g57ac0765fe0d` as of 2026-07-05.

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

1. **`dc/clk_mgr/clk_mgr.c`** — when the ASIC that matched the Beige Goby
   range check is actually DCN 2.0.1 (Cyan Skillfish), keep the dcn3 clock
   manager but set `dprefclk_khz = 600000`.
2. **`amdgpu_dm/amdgpu_dm.c`** — set `ignore_dpref_ss` for DCE IP 2.0.3 so the
   bogus fallback spread-spectrum data is not applied.

The patch itself was correct from the start. What went wrong — twice — was the
build setup.

## Why the build setup was the problem

Two bad builds shipped before the working one, and both failures came from the
environment, not the code:

**Attempt 1 (recovered 2026-07-02): wrong source version.** The module was
built from `valve24.1` sources while the running kernel was `valve24.2-1`.
modprobe rejected it at boot on the vermagic string, and because the
`updates/` override was baked into the initramfs, the machine came up with no
GPU driver at all. Guard 1 in `install.sh` (vermagic must equal `uname -r`)
now makes this impossible to install.

**Attempt 2 (the 2026-07-05 black screen): silent config drift.** The running
SteamOS kernel has `CONFIG_SCHED_CLASS_EXT=y`, which depends on
`CONFIG_DEBUG_INFO_BTF` — and Kconfig **silently disables BTF whenever
`pahole` is not on PATH**. Any `olddefconfig`/`syncconfig` run does this
without a word (syncconfig even rewrites `.config` behind your back
mid-build). sched_ext adds a 256-byte member in the middle of `task_struct`,
so a module built without it has every `task_struct` field offset 0x100 short
of the running kernel's.

The nasty part: nothing catches this at load time. vermagic is only a
release-string compare, and `CONFIG_MODVERSIONS` is off in this kernel, so
there is **no ABI check at all**. The module loads cleanly and then hangs
before amdgpu's first printk — black screen, zero log output.

Guards added so neither failure can recur:

- `build-env.sh` puts the bundled `pahole`/`bc` on PATH and **fails loudly**
  if they're missing. Source it before *any* `make` in the kernel tree.
- After any config regen, verify `CONFIG_SCHED_CLASS_EXT=y` survived in both
  `.config` and (after `modules_prepare`) `include/generated/autoconf.h`.
- Guard 2 in `install.sh` does a real ABI check: it disassembles
  `amdgpu_vm_set_task_info` in the candidate and stock modules and diffs the
  `task_struct` field offsets. The bad module read `current->pid` at 0x9d0
  where the stock module reads 0xad0.

Related Kbuild footguns hit along the way: after fixing a config, syncconfig
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
