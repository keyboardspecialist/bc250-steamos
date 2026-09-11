# BC-250 Mesa and FSR4 integration

The current FSR4 workflow installs the portable RC8 game DLL from
`daniel-h-0/bc250-fsr4-fork` release `v4.0.0-rc8`:

- Archive: `bc250-fsr4-dll-4.0.0-rc8.tar.xz`
- Archive SHA-256: `805a3df9cef931decd42d02eaffb375f95844afce2e13d78bad757a27c806da2`
- DLL SHA-256: `f8816fed46bce60179228a58905e16788f021fad0b68c08d1e3555564093b2b4`

RC8 carries its optimizations in a Windows x64 FSR 4.1.1 INT8 DLL. It does not
replace Mesa, require the alternate RADV runtime, or require a custom Proton
build. The toolkit retains the release notices and the original target DLL for
verified rollback.

The toolkit does not ship a repository-owned FSR4 Mesa patch. Explicit legacy
V3 setup fetches the tested patch from `dmorazasanchez/bc250-fsr4` at commit
`741ff3e369026f34820c41a846cf5e55d08e2a61`:

- File: `bc250-fsr4-v3.patch`
- SHA-256: `7fde37fad572b4ba4dcac6052792d10d8d3df65982b01236c63a3eff0a25d225`
- Mesa baseline: `mesa-26.2.0`, commit
  `9f0a761020bca92f2b07156a0621e5360cb8eca5`

The download is rejected unless its SHA-256 matches. The upstream repository
does not currently declare a license; the Unlicense file in this directory
applies only to this repository's integration documentation, not to the fetched
patch, upstream source, or Mesa.

## Mesa Composition

The global async-compute profile is built with the required patch from
`DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9`:

1. `0001-gfx1013-compute-queue-fix.patch`

DryhoppedIPA disabled optional patches `0002` and `0003` after mesh/task
workloads caused an unrecoverable GPU hang. The toolkit no longer downloads or
applies them.

FSR4 V3 already contains the compute-queue changes from `0001`. Legacy setup
preserves the compiled base driver, reverses `0001` in the shared source tree,
and applies the exact V3 patch with `--fuzz=0`. Ninja then incrementally rebuilds
the affected RADV targets.

The final profiles are therefore:

- Global profile: DryhoppedIPA `0001`
- Legacy private FSR4 profile: upstream FSR4 V3

## Scope And Risk

RC8 changes sixteen of 348 shader slots and reports an 8.52 percent reduction
in synthetic 1440p Quality upscaler GPU time versus RC7. Output images matched
in its recorded test set, but RC8 has no fresh whole-game qualification and the
claim is not a game FPS measurement.

Legacy V3 provides deferred signed-dot optimization, signed i24 MUL/MAD lowering,
FSR4 wrapper fusion, dense-reduction selection, and its tested ACO spill policy.
It also contains the optional `RADV_GFX103` generation override from upstream.
The toolkit does not set that environment variable.

Upstream reports 63 FPS in its Cyberpunk 2077 FSR 4.1.1 test and a 64-shader
audit with no new VGPR-spill or resident-wave regressions. Those results have
not been independently reproduced by this toolkit. This remains experimental
BC-250 software and can regress performance, corrupt frames, hang, or reset the
GPU.
