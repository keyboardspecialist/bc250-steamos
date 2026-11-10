#!/usr/bin/env python3
"""Rebase the checksum-pinned LoneWolf DirectMesh 1.4 onto Mesa 26.2.5.

Preserve Mesa's force_exact_glsl_fma flag and the new padded-VA unmapping fix.
The added flag grows the compiler key to 28 bytes, so retain its full identity
in DirectMesh's pipeline-plan and shader-object caches as well.
"""

import hashlib
from pathlib import Path
import re
import sys


UPSTREAM_SHA256 = "a51b430e7465b9de37d2cc88778c8970676c301c1f77d4b330edca28caff7418"

# These adaptations keep fixes already present in Mesa 26.2.5, and leave the
# separately pinned compute-queue prerequisite intact. The input hash above
# binds every replacement to the reviewed v1.4 release asset.
MESA_COMPAT_REPLACEMENTS = (
    ("""@@ -483,10 +483,10 @@ ac_fill_hw_ip_info(struct radeon_info *info, const struct drm_amdgpu_info_device
        */
       info->ip[ip_type].num_queues = 1;
    } else if (ip_info->available_rings) {
-      /* GFX1013 is known to have broken compute queue */
-      if (ip_type == AMD_IP_COMPUTE && device_info->family == FAMILY_NV &&
-          ASICREV_IS(device_info->external_rev, GFX1013))
-         return false;
+      /* GFX1013: this experimental build requires the matching BC250
+       * kernel PASID TLB invalidation and compute GFXOFF fixes.
+       * Expose ACE queues only when using that patched kernel.
+       */
\x20
       info->ip[ip_type].num_queues = util_bitcount(ip_info->available_rings);
    }
""", ""),
    ("""@@ -1019,7 +1019,8 @@ void ac_fill_bug_info(struct radeon_info *info)
     * dimension mode.
     */
    info->has_async_compute_threadgroup_bug = info->family == CHIP_ICELAND ||
-                                             info->family == CHIP_TONGA;
+                                             info->family == CHIP_TONGA ||
+                                             info->family == CHIP_GFX1013;
\x20
    /* GFX7 CP requires 32 bytes alignment for the indirect buffer arguments on
     * the compute queue.
""", ""),
    ("                     struct radv_image *dst_image, uint64_t htile_va, bool read_htile_value)\n",
     "                     struct radv_image *dst_image, uint32_t base_array_layer, uint64_t htile_va,\n"
     "                     bool read_htile_value)\n"),
    (" radv_before_draw(struct radv_cmd_buffer *cmd_buffer, const struct radv_draw_info *info, uint32_t drawCount, bool dgc)\n",
     " radv_before_draw(struct radv_cmd_buffer *cmd_buffer, const struct radv_draw_info *info, uint32_t drawCount,\n"
     "                  uint32_t max_indirect_draw_count, bool dgc)\n"),
    ("          if (!radv_before_draw(cmd_buffer, &info, 1, true))\n",
     "          if (!radv_before_draw(cmd_buffer, &info, 1, layout->vk.draw_count ? pGeneratedCommandsInfo->maxDrawCount : 1,\n"
     "                                true))\n"),
    ("    VkShaderStageFlagBits bound_stages = 0;\n",
     "    VkShaderStageFlagBits stages = 0, bound_stages = 0;\n"),
    ("+      if (radv_cmd_buffer_device(cmd_buffer)->bc250_env.shader_object_plan)\n"
     "+         bound_stages |= pStages[i];\n+\n",
     "       stages |= pStages[i];\n \n"),
    # Mesa now tracks bound vs. unbound stages separately. Its graphics dirty
    # check already handles unbinding and must not be replaced with the old one.
    ("""@@ -16924,7 +17705,9 @@ radv_CmdBindShadersEXT(VkCommandBuffer commandBuffer, uint32_t stageCount, const
       /* Graphics shaders are handled at draw time because of shader variants. */
    }
\x20
-   cmd_buffer->state.dirty |= RADV_CMD_DIRTY_GRAPHICS_SHADERS;
+   if (!radv_cmd_buffer_device(cmd_buffer)->bc250_env.shader_object_plan ||
+       (bound_stages & RADV_GRAPHICS_STAGE_BITS))
+      cmd_buffer->state.dirty |= RADV_CMD_DIRTY_GRAPHICS_SHADERS;
 }
\x20
 VKAPI_ATTR void VKAPI_CALL
""", ""),
    # Retain Mesa's immutable-sampler hashing and extend it with v1.4's absent
    # set identity, rather than adding a second independent hash loop.
    ("    _mesa_blake3_update(&ctx, stage->shader_blake3, sizeof(stage->shader_blake3));\n"
     "+   /* Immutable sampler conversion affects original SPIR-V translation.\n",
     "    _mesa_blake3_update(&ctx, stage->shader_blake3, sizeof(stage->shader_blake3));\n"
     "-   _mesa_blake3_update(&ctx, &stage->layout.num_sets, sizeof(stage->layout.num_sets));\n"
     "-   for (unsigned i = 0; i < stage->layout.num_sets; i++) {\n"
     "-      if (!stage->layout.set[i].layout)\n-         continue;\n"
     "-      _mesa_blake3_update(&ctx, stage->layout.set[i].layout->hash,\n"
     "-                          sizeof(stage->layout.set[i].layout->hash));\n-   }\n"
     "+   /* Immutable sampler conversion affects original SPIR-V translation.\n"),
    ("-      if (fs_stage && (fs_stage->info.ps.allow_flat_shading || fs_stage->info.ps.force_disable_vrs)) {\n",
     "-      if (fs_stage->nir && (fs_stage->info.ps.allow_flat_shading || fs_stage->info.ps.force_disable_vrs)) {\n"),
    ("+      if (fs_stage &&\n", "+      if (fs_stage->nir &&\n"),
    # This exact NIR fix is already upstream. Applying it again would cause
    # patch(1) to reverse it unless --forward is specified.
    ("""diff --git a/src/compiler/nir/nir_opt_uub.c b/src/compiler/nir/nir_opt_uub.c
index 19d50f5..3b397c2 100644
--- a/src/compiler/nir/nir_opt_uub.c
+++ b/src/compiler/nir/nir_opt_uub.c
@@ -193,7 +193,7 @@ opt_uub_minmax(nir_builder *b, nir_alu_instr *alu, opt_uub_state *state)
    if (src_uub > nir_scalar_as_uint(const_src))
       return false;
\x20
-   nir_scalar replacement = alu->op == nir_op_umax ? const_src : src;
+   nir_scalar replacement = op == nir_op_umax ? const_src : src;
    b->cursor = nir_after_instr(&alu->instr);
    nir_def_replace(&alu->def, nir_mov_scalar(b, replacement));
    return true;
""", ""),
)


def recount_hunks(text):
    """Recount changed context, retaining standard three-line hunk boundaries."""
    lines = text.splitlines(keepends=True)
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        match = re.fullmatch(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)\n", line)
        if not match:
            result.append(line)
            i += 1
            continue
        end = i + 1
        while end < len(lines):
            body_line = lines[end]
            if body_line.startswith(("diff --git ", "@@ ")) or not body_line.startswith((" ", "+", "-", "\\")):
                break
            end += 1
        body = lines[i + 1:end]
        leading = 0
        while leading < len(body) and body[leading].startswith(" "):
            leading += 1
        # Splitting a newer function signature adds a fourth context line.
        # Normalize it instead of requiring patch(1) to discard context (fuzz).
        trim = max(0, leading - 3)
        body = body[trim:]
        old_count = sum(line[0] in " -" for line in body)
        new_count = sum(line[0] in " +" for line in body)
        result.append("@@ -%s,%s +%s,%s @@%s\n" % (
            int(match[1]) + trim, old_count, int(match[2]) + trim, new_count, match[3]
        ))
        result.extend(body)
        i = end
    return "".join(result)


def rebase(data):
    if hashlib.sha256(data).hexdigest() != UPSTREAM_SHA256:
        raise ValueError("DirectMesh patch does not match its pinned upstream checksum")
    text = data.decode("utf-8")
    replacements = (
        (
            "@@ -566,7 +684,29 @@ struct radv_compiler_info {\n"
            "       uint32_t no_implicit_varying_subgroup_size : 1;\n"
            "       uint32_t force_nan_preserve_min_max : 1;\n"
            "       uint32_t nir_debug_info : 1;\n"
            "-      uint32_t padding : 28;\n",
            "@@ -567,7 +685,29 @@ struct radv_compiler_info {\n"
            "       uint32_t force_nan_preserve_min_max : 1;\n"
            "       uint32_t force_exact_glsl_fma : 1;\n"
            "       uint32_t nir_debug_info : 1;\n"
            "-      uint32_t padding : 27;\n",
        ),
        (
            "    const uint64_t va_size = radv_amdgpu_bo_va_size(bo->base.size, bo->flags);\n"
            "    radv_amdgpu_bo_va_op(ws, bo->bo_handle, 0, va_size, bo->base.va, 0, 0, AMDGPU_VA_OP_UNMAP);\n",
            "    const uint64_t va_size = radv_amdgpu_bo_va_size(bo->base.size, bo->flags);\n \n",
        ),
        ("+   uint8_t route_key[24];", "+   uint8_t route_key[28];"),
        ("+   uint8_t bc250_route_key[24];", "+   uint8_t bc250_route_key[28];"),
        (
            "+   STATIC_ASSERT(sizeof(device->compiler_info.key) == 24);",
            "+   STATIC_ASSERT(sizeof(device->compiler_info.key) == 28);",
        ),
        (
            '"BC250 route policy must retain the complete 24-byte compiler key"',
            '"BC250 route policy must retain the complete 28-byte compiler key"',
        ),
        (
            "the key stays 24 bytes.",
            "the Mesa 26.2.5 key is 28 bytes.",
        ),
    )
    for original, replacement in replacements + MESA_COMPAT_REPLACEMENTS:
        if text.count(original) != 1:
            raise ValueError("DirectMesh rebase context is missing or ambiguous")
        text = text.replace(original, replacement, 1)
    return recount_hunks(text).encode("utf-8")


if __name__ == "__main__":
    try:
        sys.stdout.buffer.write(rebase(Path(sys.argv[1]).read_bytes()))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
