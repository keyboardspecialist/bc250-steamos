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

## LoneWolf Native-Mesh Profile

The optional private profile combines that unchanged Mesa `mesa-26.2.2`,
async-compute, and FSR4 composition with LoneWolf's physical-GFX10 native-mesh
work from
[`lonewolf0622/BC250-Native-Mesh-Shaders-`](https://github.com/lonewolf0622/BC250-Native-Mesh-Shaders-)
at commit `d67c00d4aad5797364abc3401d419e76afb04edd`. The upstream patch is
SHA-256 `bb3561153c97413b9c4a348b09a1219e7971b5f1490963c28a238733cc946fed`
and targets Mesa 26.1.4 commit
`6dfbc555b4128ee51139c5f78c5aba2594c9701b`.

`0010-lonewolf-native-mesh-mesa-26.2.2-rebase.patch` is a
**toolkit-maintained rebase**, not an upstream LoneWolf release. Its SHA-256 is
`2dabe48622732d9761efefc1a655909ee775cc36efb49deeaccda585d0fab0ea`.
It adapts LoneWolf's patch to Mesa 26.2's compiler-info/API changes and to the
already-applied `0001` plus `0005` through `0009` composition. Setup verifies
both upstream and rebased patch hashes, applies every patch without fuzz or
3-way fallback, and retains LoneWolf's license, README, and known-limitations
notices.

This profile is x86-64 and private. Its attested runner routes 32-bit processes
to the stock SteamOS i686 RADV ICD and sets `RADV_EXPERIMENTAL` to exactly
`bc250_mesh`. `--ff7-capabilities` additionally sets
`RADV_BC250_ADVERTISE_TASK=1` and `RADV_BC250_EXPOSE_FSR=1`; the latter means
fragment shading rate, not FidelityFX Super Resolution. Capability
advertisement does not make Task execution safe. The current patched compute
kernel and active `amdgpu.sched_policy=2` are required because this combined
profile also contains async compute. It has independent install, transaction,
status, uninstall, and purge gates, is never exported globally, and does not
edit Steam launch options.

The GFX1013 async-compute kernel lifecycle remains based on
`DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9`. Its matching AMDGPU repair and
`amdgpu.sched_policy=2` gate must be active before the alternate RADV driver is
exported to the user session.

## GE-Proton Package

`bc250-proton.sh` consumes only the compatibility tool and license directories
from `protonge-latest-bc250-11.6-166-x86_64.pkg.tar.zst`, SHA-256
`193e0e3b275024231bce8c0b01ed4220507257f86befc7c6fbb940e55a035640`.
It does not install CachyOS package metadata, hooks, modules, or host
dependencies. The GE build uses Steam Linux Runtime and is installed beneath
the current user's Steam compatibility-tools directory.

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
The LoneWolf profile is also an experimental preview, not a claim of full
`VK_EXT_mesh_shader` compliance. Read `LONEWOLF-KNOWN_LIMITATIONS.md` before
use.
