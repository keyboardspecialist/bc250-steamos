# BC-250 Mesa patch integration

The toolkit does not ship a repository-owned FSR4 Mesa patch. FSR4 setup fetches
the tested V3 patch from `dmorazasanchez/bc250-fsr4` at immutable commit
`741ff3e369026f34820c41a846cf5e55d08e2a61`:

- File: `bc250-fsr4-v3.patch`
- SHA-256: `7fde37fad572b4ba4dcac6052792d10d8d3df65982b01236c63a3eff0a25d225`
- Mesa baseline: `mesa-26.2.0`, commit
  `9f0a761020bca92f2b07156a0621e5360cb8eca5`

The download is rejected unless its SHA-256 matches. The upstream repository
does not currently declare a license; the Unlicense file in this directory
applies only to this repository's integration documentation, not to the fetched
patch, upstream source, or Mesa.

## Composition

The global async-compute profile is built first with the three patches from
`DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9`:

1. `0001-gfx1013-compute-queue-fix.patch`
2. `0002-gfx1013-mesh-task-shaders.patch`
3. `0003-gfx1013-taskmesh-queries.patch`

Upstream FSR4 V3 already contains the compute-queue changes from `0001`. To
produce the private FSR4 profile without modifying upstream V3, setup preserves
the compiled base driver, reverses `0001` in the shared source tree, and applies
the exact V3 patch with `--fuzz=0`. Patches `0002` and `0003` do not overlap V3
and remain applied. Ninja then incrementally rebuilds the affected RADV targets.

The final profiles are therefore:

- Global profile: DryhoppedIPA `0001` + `0002` + `0003`
- Private FSR4 profile: upstream FSR4 V3 + DryhoppedIPA `0002` + `0003`

## Scope And Risk

V3 provides deferred signed-dot optimization, signed i24 MUL/MAD lowering,
FSR4 wrapper fusion, dense-reduction selection, and its tested ACO spill policy.
It also contains the optional `RADV_GFX103` generation override from upstream.
The toolkit does not set that environment variable.

Upstream reports 63 FPS in its Cyberpunk 2077 FSR 4.1.1 test and a 64-shader
audit with no new VGPR-spill or resident-wave regressions. Those results have
not been independently reproduced by this toolkit. This remains experimental
BC-250 software and can regress performance, corrupt frames, hang, or reset the
GPU.
