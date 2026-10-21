# BC-250 DirectMesh, Mesa, and FSR4 integration

The toolkit provides a global DirectMesh + FSR4 RADV runtime and a separate
portable, game-local FSR4 DLL route. The former R2 private profile is retired;
its recorded provenance is retained only for safe recognition and removal.

## Portable RC11 DLL

The game-local route downloads `daniel-h-0/bc250-fsr4-fork` release
`v4.0.0-rc11`:

- Archive: `bc250-fsr4-dll-4.0.0-rc11.zip`
- Archive SHA-256: `95ef0c6ea887e0506a3a92f7e4648e7ab7e1100e99f5eff2f70dd33b8dff2a72`
- DLL SHA-256: `8192ea97620f8e6407bff346bf905f0d555ff73d89fe14616eb1fa5e41ab3175`

This route does not replace Mesa or require the alternate RADV runtime or a
custom Proton build. The toolkit retains the release notices and the original
target DLL for verified rollback.
`bc250-fsr4.sh` validates the ZIP layout before extraction and also retains
legacy tar.xz support for recorded older payloads. RC11 remains a prerelease;
packaging/rollback checks are not a claim of gameplay stability or higher FPS.

## Global DirectMesh + FSR4 RADV runtime

The global route builds Mesa `mesa-26.2.5` at commit
`ddaf85e353442d9d7f192fdcf1823e652e3f2ee3`. Its patch series is
downloaded from `MastaG/linux-cachyos-bc250` at immutable commit
`f05991ace64a42eda3d2dc583e96b8d35ce393e3`:

1. `0001-gfx1013-compute-queue-fix.patch`
2. `0002-bc250-directmesh.patch` (DirectMesh 1.3.1, locally rebased as below)
3. `0003-bc250-fsr4-v3.patch`
4. `0004-bc250-fsr4-combined-unroll.patch`
5. `0005-bc250-fsr4-imageprep-texture.patch`
6. `0006-bc250-fsr4-resolution-variants.patch`
7. `0007-bc250-fsr4-production-defaults.patch`

Every file has a fixed SHA-256 in `bc250-mesh-shader.sh`. Setup requires
`--fuzz=0`, validates source markers after patching, and checks FSR4
markers in the final ELF driver. All seven patches applied with zero fuzz to
the pinned source, and a full RADV build with `ninja -j2` **passed**. Installation,
GPU gameplay, and conformance were not qualified by that build.

`rebase-directmesh.py` accepts only the checksum-pinned upstream DirectMesh
patch and refuses missing or ambiguous contexts. It preserves Mesa 26.2.5's
`force_exact_glsl_fma` flag and padded-VA unmapping fix, and expands DirectMesh's
compiler-key arrays and static assertions from 24 to **28 bytes**, retaining the
complete key in pipeline-plan and shader-object caches. It does not import the
older unsafe mesh/task patch series or a broad GFX10.3 override.

The source-build libdrm fallback is `2.4.134`, archive SHA-256
`ac5e74d157830eb8bee44c6a6bf3ad49774ef0dd2a72bdad74a8f20308b52a95`.
This fallback is separate from the host's system libdrm.

Install as the logged-in user:

```bash
./bc250-mesh-shader.sh setup --directmesh
```

Plain `setup` is equivalent. The patched 64-bit RADV ICD is exported globally;
SteamOS still supplies the 32-bit RADV path. DirectMesh is enabled by default
on BC-250. To opt out for one game, set its Steam launch option to:

```text
RADV_DIRECTMESH=0 %command%
```

The GFX1013 async-compute kernel lifecycle remains based on
`DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9`. Its matching AMDGPU repair and
`amdgpu.sched_policy=2` gate must be active before the alternate RADV driver is
exported to the user session. Follow the requested reboot checkpoints.

## Retired R2 cleanup and removal-only provenance

Close games before migration. Global setup **first** verifies both the old
toolkit-owned native-mesh profile and private `BC250-R2` compatibility tool,
then removes recognized files before proceeding with DirectMesh. Modified
recorded profile files, unrecognized tools, symlinks, and unsafe ancestors fail
closed; setup does not
delete them or continue over an unverifiable profile. Restore the recorded
files or inspect and remove the unrecognized state manually before retrying.

The old private Proton copy was identified by its managed marker, version,
compatibility-tool identity, and pinned vkd3d core, not a full-tree manifest.
Cleanup removes that entire private copy; arbitrary personal additions or changes
elsewhere inside it cannot be detected. Preserve those manually before migration.

Cleanup checks current-user process command lines and mappings before recovery
or deletion. Protected mappings trigger a read-only sudo retry; if they still
cannot be inspected, cleanup stops instead of assuming R2 is idle.

Decky and Plasma cannot answer terminal sudo password prompts. Their global
installer checks noninteractive sudo authorization before starting R2 cleanup;
if unavailable, use `./bc250-mesh-shader.sh setup --directmesh` in a terminal.
Trainer's native maintenance runner provides its existing authentication flow.

Cleanup does not alter original Proton, prefixes, saves, or per-game Steam
settings. For former R2 games, **manually select ordinary Proton and remove the
old `bc250-r2` launch option in Steam**, then restart Steam. No private Proton
copy or patched R2 vkd3d core is installed for DirectMesh.

To remove recognized legacy files without installing the new global runtime:

```bash
./bc250-mesh-shader.sh uninstall --native-mesh
```

`setup --native-mesh` is retired and refuses installation. The following values
are historical attestation data for removal, **not installation instructions**.
The old private profile came from
[`luckiskind/bc250-radv-r2`](https://github.com/luckiskind/bc250-radv-r2)
prerelease `r2-20260921` at commit
`3367cd5eed23ab38fddfc0fb52dbc4e17adf6e11`. The release archive SHA-256 is
`36188f341adbbd3f61069155601b18eda2e90d557bf4d16005a0b44b177e5a40`.
Its RADV driver SHA-256 is
`ee8b43e646036e6fde20040dbd18afb40da63f12b79d5c0826fcbdd9c0fae58e`,
and its patched vkd3d core SHA-256 is
`1dd2de3737fa70b2131368304c36d8fae0797fb7f3bfe1357b207c59739686c5`.
Recorded payload values are checked against the installed manifest for cleanup.

The corresponding `mesa-r2-source.tar.gz` asset is pinned at SHA-256
`752eb8c0941c0aeb46be991cdf7f8fc2fc1ed2f0c940a62759e47770e33a0f94`.
Older source-built R2 manifests also record the locally built driver hash and
this exact source asset's provenance. Recognition retains the historical Proton
`11.0-2c`/vkd3d identities; it does not download or rebuild them for new installs.
The earlier LoneWolf manifest constants likewise remain only for safe removal.

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
DirectMesh's successful source build is not a claim of Vulkan or D3D
conformance, GPU stability, or game compatibility. Keep the per-game opt-out and
portable rollback routes available during evaluation.
