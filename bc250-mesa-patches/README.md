# BC-250 Mesa and FSR4 integration

The toolkit supports two distinct FSR4 routes.

## Portable RC9 DLL

The game-local route downloads `daniel-h-0/bc250-fsr4-fork` release
`v4.0.0-rc9`:

- Archive: `bc250-fsr4-dll-4.0.0-rc9-docs2.tar.xz`
- Archive SHA-256: `063e23e0a56605b63deef2c03100432eb75d991c68eb04c6eb9b4a8444fd4f06`
- DLL SHA-256: `eefcac03ab17b04a29a5bb16e3f3e9c3181ba9ea46b05a61cb49a5003e1516ef`

This route does not replace Mesa or require the alternate RADV runtime or a
custom Proton build. The toolkit retains the release notices and the original
target DLL for verified rollback.

## FSR4 RADV Profile

The integrated GE-Proton route builds Mesa `mesa-26.2.2` at commit
`3281a69a8bfd9f997e91c15ed0e6290cae12dd32`. The FSR4 patch series is
downloaded from `MastaG/linux-cachyos-bc250` at immutable commit
`db49878af40551b481f511053201fcf1e1bd5d90`:

1. `0001-gfx1013-compute-queue-fix.patch`
2. `0005-bc250-fsr4-v3.patch`
3. `0006-bc250-fsr4-combined-unroll.patch`
4. `0007-bc250-fsr4-imageprep-texture.patch`
5. `0008-bc250-fsr4-resolution-variants.patch`
6. `0009-bc250-fsr4-production-defaults.patch`

Every file has a fixed SHA-256 in `bc250-mesh-shader.sh`. Setup requires
`--fuzz=0`, validates source markers after patching, and checks FSR4
markers in the final ELF driver. Patches `0002` through `0004` are deliberately
omitted because the mesh/task path is unsafe on this hardware and the broad
GFX10.3 override is not required by the FSR4 profile.

## BC250 RADV R2 Native-Mesh Profile

The optional private profile consumes
[`luckiskind/bc250-radv-r2`](https://github.com/luckiskind/bc250-radv-r2)
prerelease `r2-20260921` at commit
`3367cd5eed23ab38fddfc0fb52dbc4e17adf6e11`. The release archive SHA-256 is
`36188f341adbbd3f61069155601b18eda2e90d557bf4d16005a0b44b177e5a40`.
Its RADV driver SHA-256 is
`ee8b43e646036e6fde20040dbd18afb40da63f12b79d5c0826fcbdd9c0fae58e`,
and its patched vkd3d core SHA-256 is
`1dd2de3737fa70b2131368304c36d8fae0797fb7f3bfe1357b207c59739686c5`.
Both values must also match the release manifest.

R2 substantially extends the earlier LoneWolf baseline. Native mesh-only draws
use direct dispatch where eligible, while application TASK shaders use a
compute-emulated producer/native-mesh-consumer path. The patched vkd3d core
contains the matching compute-to-graphics queue workaround, so the toolkit
installs both payloads and creates a private copy of exactly Proton 11.0-2c.
Using the RADV payload alone is not the supported D3D12 configuration.

The current patched compute kernel and active `amdgpu.sched_policy=2` remain
required. R2 is x86-64, never exported globally, and requires native Steam,
explicit compatibility-tool selection, plus its per-game runner. Flatpak Steam
and 32-bit games are not qualified. Compact vertices and native TASK remain
disabled. The old LoneWolf manifest constants remain only to recognize,
replace, or safely remove toolkit-owned legacy profiles.

The GFX1013 async-compute kernel lifecycle remains based on
`DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9`. Its matching AMDGPU repair and
`amdgpu.sched_policy=2` gate must be active before the alternate RADV driver is
exported to the user session.

## GE-Proton Package

`bc250-proton.sh` discovers the newest valid
`protonge-latest-bc250-<version>-x86_64.pkg.tar.zst` asset in the upstream
`repo` rolling release. It validates the canonical GitHub URL and verifies the
archive with the SHA-256 digest from the release API. It consumes only the
compatibility tool and license directories and does not install CachyOS package
metadata, hooks, modules, or host dependencies. The GE build uses Steam Linux
Runtime and is installed beneath the current user's Steam compatibility-tools
directory.

## Legacy State

New private FSR4 V3 profile builds are retired. The old upstream commit and
patch checksum remain in the lifecycle script only to recognize and safely
remove previously recorded profiles. The upstream legacy repository declares
no license, so its patch is not copied into this repository.

## Scope And Risk

All FSR4 paths remain experimental BC-250 software. They can regress
performance, corrupt frames, hang, or reset the GPU. Qualify one game at a time,
retain the portable rollback route while evaluating integrated GE-Proton, and
do not use DLL injection or FSR4 upgrade with anti-cheat games.
BC250 RADV R2 is an experimental prerelease, not a claim of Vulkan or D3D
conformance. Its installed `VALIDATION.md` documents known hangs, memory
failures, and unqualified paths.
