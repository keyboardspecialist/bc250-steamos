#!/usr/bin/env python3
"""Rebase the checksum-pinned DirectMesh 1.3.1 carry onto Mesa 26.2.5.

Preserve Mesa's force_exact_glsl_fma flag and the new padded-VA unmapping fix.
The added flag grows the compiler key to 28 bytes, so retain its full identity
in DirectMesh's pipeline-plan and shader-object caches as well.
"""

import hashlib
from pathlib import Path
import sys


UPSTREAM_SHA256 = "505a5df741aab30f51405630f5fab853e942db6c44beb5aa1d787480a3b127ee"


def rebase(data):
    if hashlib.sha256(data).hexdigest() != UPSTREAM_SHA256:
        raise ValueError("DirectMesh patch does not match its pinned upstream checksum")
    text = data.decode("utf-8")
    replacements = (
        (
            "@@ -565,7 +683,29 @@ struct radv_compiler_info {\n"
            "       uint32_t no_implicit_varying_subgroup_size : 1;\n"
            "       uint32_t force_nan_preserve_min_max : 1;\n"
            "       uint32_t nir_debug_info : 1;\n"
            "-      uint32_t padding : 28;\n",
            "@@ -566,7 +684,29 @@ struct radv_compiler_info {\n"
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
    for original, replacement in replacements:
        if text.count(original) != 1:
            raise ValueError("DirectMesh rebase context is missing or ambiguous")
        text = text.replace(original, replacement, 1)
    return text.encode("utf-8")


if __name__ == "__main__":
    try:
        sys.stdout.buffer.write(rebase(Path(sys.argv[1]).read_bytes()))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
