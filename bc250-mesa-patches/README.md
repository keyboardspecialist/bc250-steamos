# BC-250 Mesa patches

This directory contains an independently developed Mesa optimization patch for
the Cyan Skillfish BC-250 (`CHIP_GFX1013`). The BC-250 SteamOS contribution,
patch metadata, and this documentation are released under the Unlicense in
`LICENSE`. Mesa remains MIT-licensed; applying this patch does not remove or
replace any Mesa copyright or license notice, and distributions must preserve
Mesa's notices.

## Clean-room provenance

`0004-gfx1013-fsr4-sdot-lowering.patch` was designed only from the supplied
functional specification, pristine Mesa 26.2.0 source, the three MIT-licensed
DryhoppedIPA prerequisite patches listed below, and direct reasoning about NIR,
ACO instruction selection, and ACO spilling. No external FSR4 implementation,
patch, repository, clone, binary, disassembly, or temporary research artifact
was accessed, inspected, fetched, diffed, or copied.

The patch is a clean-room implementation for FSR4-style signed packed-dot
compute workloads. It does not claim source equivalence, performance parity,
or benchmark parity with any other implementation.

## Exact baseline and order

Use pristine Mesa tag `mesa-26.2.0`, commit
`9f0a761020bca92f2b07156a0621e5360cb8eca5`.

Apply the MIT Mesa patches from `DryhoppedIPA/bc250-gfx1013-fix` commit
`d3e6dc062c34d2523db0abe5741d1f5b0dea00d9` in this exact order:

1. `0001-gfx1013-compute-queue-fix.patch` (`sha256:78bccb8022955b3e4e11ab76d8373e95e5cd0b4e8b09f5a9abbe87dce8d92484`)
2. `0002-gfx1013-mesh-task-shaders.patch` (`sha256:f01fea1aa7c639ede8289059fe6ec0fde30ffecd13f4c3c3f50c14ef6a7aea47`)
3. `0003-gfx1013-taskmesh-queries.patch` (`sha256:8056be93d6f15358275cffe8798b13f90e41c228a8832c563dc30116372d2995`)
4. `0004-gfx1013-fsr4-sdot-lowering.patch`

```sh
patch -p1 --fuzz=0 < 0001-gfx1013-compute-queue-fix.patch
patch -p1 --fuzz=0 < 0002-gfx1013-mesh-task-shaders.patch
patch -p1 --fuzz=0 < 0003-gfx1013-taskmesh-queries.patch
patch -p1 --fuzz=0 < 0004-gfx1013-fsr4-sdot-lowering.patch
```

Patch `0004` is intentionally based on the post-`0001`-`0003` tree. It does not
duplicate their compute-queue, mesh/task, or query changes.

## Architecture and scope

The default optimization gate requires ACO (`!compiler_info->key.use_llvm`),
`MESA_SHADER_COMPUTE`, and `CHIP_GFX1013`. Graphics, task, mesh, ray-tracing,
and LLVM compilation are unchanged. Other GPU families are always unchanged,
including when the experimental option described below is enabled.

The implementation has five parts:

1. RADV temporarily uses a private copy of `nir_shader_compiler_options` with
   signed 4x8 dot support enabled for one `nir_opt_algebraic` round. This keeps
   signed dots available long enough to absorb surrounding additions and
   FSR4-style `iadd` wrappers. The shared compiler options and Vulkan-visible
   capabilities are never changed. This custom deferral and MAD24 lowering is
   ACO-only. LLVM retains Mesa's existing generic software signed-dot lowering
   and never receives `imul24` or `imad24_ir3` from this patch.
2. A dedicated pass explicitly lowers every remaining `sdot_4x8_iadd` and
   `sdot_4x8_iadd_sat` before normal RADV optimization and code generation.
   Constant packed operands become signed byte literals. General
   accumulator-bearing forms use linear signed MAD24 chains. Zero-accumulator,
   saturating, and selected dense forms use two independent two-MAD chains.
   Wrapping forms retain modulo-2^32 addition; saturating forms form the bounded
   dot sum first and perform one final signed saturating add with the original
   accumulator.
3. A structural pre-pass counts signed dots, saturating dots, ALU instructions,
   and control-flow blocks. The dense strategy requires at least 768 wrapping
   dots and either at least 30% dot density with no more than 128 blocks, or at
   least 2048 dots in a shader with at least eight blocks. This is intended to
   cover reduction families around 1088 and 1152 dots and control-rich families
   around 2304 dots without exact shader fingerprints.
4. ACO gains exact handling for signed `imul24` and `imad24_ir3` NIR forms,
   mapping them to `v_mul_i32_i24` and `v_mad_i32_i24`, including uniform-result
   conversion. A GFX1013 guard reports an instruction-selection error if any
   signed packed dot escapes explicit lowering, so the broken native
   `v_dot4_i32_i8` path cannot be selected for BC-250.
5. ACO's baseline single-wave LDS spill eligibility condition is preserved
   exactly for all shaders, including every GFX1013 case. After baseline ACO
   computes the eligible slot count, an already eligible pathological BC-250
   compute case is capped at eight dword slots per lane, or 2048 bytes per
   workgroup. The cap predicate requires wave64, workgroup-size 64, no
   pre-existing LDS, and VGPR demand at least 16 above the occupancy limit.
   Baseline eligibility still independently requires a compute or ray-tracing
   stage, workgroup size no larger than wave size, no stack pointer, and GFX9+.
   This is a resource-policy specialization, not new permission to use LDS.
   Non-pathological GFX1013 and every other family retain baseline semantics.

The patch provides no environment-variable generation override and does not
alter or spoof RADV's physical-device or compiler `gfx_level`. In particular,
it does not promote GFX1013 to GFX10.3. Such a promotion is unsafe because it
can select the wrong subgroup-ID ABI for multi-wave compute, expose unsupported
derived capabilities and VRS paths, skip required GFX10 workarounds, and bypass
the prerequisite series' mesh restrictions. NIR continues to receive false
signed-dot capability flags, and no native signed-dot support is advertised.

## Files changed by 0004

- `src/amd/compiler/aco_ir.cpp`: retain the physical GPU family in `aco::Program`.
- `src/amd/compiler/aco_ir.h`: add the family field used by BC-250 backend gates.
- `src/amd/compiler/aco_spill.cpp`: cap eligible LDS slots for the pathological GFX1013 policy without changing baseline eligibility.
- `src/amd/compiler/instruction_selection/aco_select_nir_alu.cpp`: select signed MUL24/MAD24 and reject leaked GFX1013 signed dots.
- `src/amd/vulkan/radv_shader.c`: analyze, defer, fuse, and lower signed packed dots.

## Verification

Verification was performed on Apple Silicon macOS with Apple Clang 21 against
an independently fetched pristine Mesa worktree:

- Confirmed baseline commit `9f0a761020bca92f2b07156a0621e5360cb8eca5`.
- Confirmed the three prerequisite SHA-256 values shown above.
- Applied `0001` through `0004` in order with `patch -p1 --fuzz=0`; every hunk
  applied and no reject or `.orig` file was produced.
- `git diff --check` passed on the fully composed tree.
- Meson generated `nir_builder_opcodes.h`, `nir_constant_expressions.c`,
  `nir_opcodes.h`, `nir_opcodes.c`, `nir_opt_algebraic.c`, `nir_intrinsics.h`,
  `nir_intrinsics_indices.h`, and `nir_intrinsics.c` successfully.
- Ninja built `src/compiler/nir/libnir.a` successfully.
- Ninja built the complete `src/amd/compiler/libaco.a`, including the modified
  instruction selector and spiller, successfully. A build-only Meson harness
  exposed Mesa's AMD compiler library without enabling a platform driver; that
  harness was not included in the patch.
- An independent C test harness compiled with AddressSanitizer and
  UndefinedBehaviorSanitizer and passed edge vectors plus 1,000,000 randomized
  wrapping and saturating cases for linear and split MAD24 strategies.
- The same harness passed selector invariants for dense 1088- and 1152-dot
  shapes, a control-rich 2304-dot shape, and negative small, saturation-heavy,
  and sparse/control-heavy shapes.
- The harness also passed ACO/LLVM/family gate invariants: BC-250 LLVM and
  non-compute cases reject the custom path, BC-250 ACO compute selects it, and
  every non-GFX1013 family rejects it.
- Static inspection confirmed that the patch contains no generation-override
  environment variable, changes no RADV physical-device initialization file,
  adds no compiler-key field, and does not modify `gfx_level`, physical family,
  or accelerated-dot capability state.
- Static policy comparison confirmed that the LDS eligibility expression is
  byte-for-byte the Mesa baseline expression and contains no family filter.
  Exhaustive policy checks over family, stage eligibility, workgroup/wave size,
  and stack-pointer states produced identical baseline eligibility. Slot-count
  checks confirmed that only the pathological predicate clamps values above
  eight; zero, smaller eligible counts, and all non-pathological counts remain
  unchanged.
- Source/IR-path inspection confirmed that RADV restores the real NIR options,
  explicitly lowers both signed-dot opcodes only for ACO, leaves LLVM on Mesa's
  generic lowering, and that ACO rejects leaked GFX1013 signed dots before its
  otherwise valid native-dot cases.

## Limitations and unresolved risk

A complete RADV driver build was not feasible on this macOS host: Mesa's RADV
configuration requires `glslangValidator` and Linux `libdrm_amdgpu`, neither of
which was available. Hardware-generated ISA was therefore not disassembled.
The patch has not been tested on a BC-250, benchmarked with captured FSR4
shaders, run through Vulkan CTS, or validated for visual correctness. The
selection thresholds and eight-slot LDS cap are independently reasoned starting
points, not hardware-tuned results. Linux RADV compilation, BC-250 ISA capture,
FSR4 image-quality testing, spill statistics, performance measurements, and CTS
remain required before production deployment.
