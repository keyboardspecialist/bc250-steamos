# Known limitations

This is an experimental physical-GFX10 BC250 implementation. The observed
FF7 workload and general `VK_EXT_mesh_shader` support are different claims.

## A. FF7-tested/observed support

The retained corpus contains 224 source-monolithic Mesh/fragment PSOs. Its
offline classification is:

```text
DIRECT=224
OVERFLOW=0
UNKNOWN=0
REJECTED=0
FALSE_DIRECT=0
```

The observed corpus does not use Task, CullPrimitiveEXT, PrimitiveId,
generic `PerPrimitiveEXT` outputs, Layer, ViewportIndex, or DrawID. FF7 has
been demonstrated working on BC250 with this project backend. This is a
compatibility result for the retained workload, not a conformance result for
all future FF7 pipelines or all Vulkan Mesh shaders.

## B. General `VK_EXT_mesh_shader` support

- `PrimitiveId`: compiler/offline support exists through the direct and
  hybrid/replay paths; runtime framebuffer validation is pending.
- Generic per-primitive outputs: support is bounded by the proven S11
  representation; full legal-domain coverage is not claimed.
- `Layer`: incomplete and fail-closed where the required physical-GFX10
  transport is not proven.
- `ViewportIndex`: incomplete and fail-closed where applicable.
- Shader objects: generalized standalone/linked Mesh shader-object routing is
  incomplete; missing route provenance is fail-closed and is never treated as
  `DIRECT`.
- GPL: generalized Graphics Pipeline Library Mesh routing is incomplete;
  unresolved final interface provenance is fail-closed.
- Task execution: unsupported and not validated. The optional capability
  advertisement switch must not be interpreted as Task execution support.
- CullPrimitiveEXT: unsupported and fail-closed. Earlier experimental native
  runtime approaches were unsafe and caused GPU hangs during development.
- DGC: Mesh/Task Device Generated Commands support is not claimed. Do not
  enable public Mesh/Task DGC capability based on this package.
- Queries, indirect, indirect-count, secondary-command-buffer, and
  predication combinations involving the hybrid scheduler may remain
  conservative/fail-closed.
- Points and lines have compiler/pipeline-creation evidence, but their broad
  runtime matrix is not validated here.

This preview is not full Vulkan Mesh compliance.

## Safety and performance

Direct-safe work uses the direct physical-GFX10 NGG path and retains the S11
zero-extra-traffic and zero-extra-draw behavior. Overflow and conservative
unknown routes use ordered graphics-queue record-once/raster-only replay. No
separate ACE/compute queue is required. GPU validation of this package was not
performed and requires separate authorization.
