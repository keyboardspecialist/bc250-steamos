import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "directmesh_rebase", ROOT / "bc250-mesa-patches/rebase-directmesh.py"
)
REBASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REBASE)


class DirectMeshRebaseTests(unittest.TestCase):
    def fixture(self):
        return (
            "@@ -566,7 +684,29 @@ struct radv_compiler_info {\n"
            "       uint32_t no_implicit_varying_subgroup_size : 1;\n"
            "       uint32_t force_nan_preserve_min_max : 1;\n"
            "       uint32_t nir_debug_info : 1;\n"
            "-      uint32_t padding : 28;\n"
            "    const uint64_t va_size = radv_amdgpu_bo_va_size(bo->base.size, bo->flags);\n"
            "    radv_amdgpu_bo_va_op(ws, bo->bo_handle, 0, va_size, bo->base.va, 0, 0, AMDGPU_VA_OP_UNMAP);\n"
            "+   uint8_t route_key[24];\n"
            "+   uint8_t bc250_route_key[24];\n"
            "+   STATIC_ASSERT(sizeof(device->compiler_info.key) == 24);\n"
            '+                 "BC250 route policy must retain the complete 24-byte compiler key");\n'
            "+       * and size preserves every switch-off key byte; the key stays 24 bytes. */\n"
            + "\n".join(original for original, _replacement in REBASE.MESA_COMPAT_REPLACEMENTS)
        ).encode()

    def test_unknown_upstream_patch_is_rejected_before_rebasing(self):
        with self.assertRaisesRegex(ValueError, "pinned upstream checksum"):
            REBASE.rebase(self.fixture())

    def test_rebase_preserves_new_mesa_flag_and_complete_cache_keys(self):
        data = self.fixture()
        with patch.object(REBASE, "UPSTREAM_SHA256", hashlib.sha256(data).hexdigest()):
            result = REBASE.rebase(data).decode()
        self.assertIn("uint32_t force_exact_glsl_fma : 1;", result)
        self.assertIn("-      uint32_t padding : 27;", result)
        self.assertIn("route_key[28]", result)
        self.assertIn("bc250_route_key[28]", result)
        self.assertIn("sizeof(device->compiler_info.key) == 28", result)
        self.assertIn("complete 28-byte compiler key", result)
        self.assertNotIn("[24]", result)
        # The old unmap context is removed so Mesa's separate padding unmap stays.
        self.assertNotIn("AMDGPU_VA_OP_UNMAP", result)

    def test_missing_or_ambiguous_context_fails_closed_even_with_valid_checksum(self):
        for data in (
            self.fixture().replace(b"route_key[24]", b"route_key[20]"),
            self.fixture() + b"+   uint8_t route_key[24];\n",
            self.fixture().replace(b"VkShaderStageFlagBits bound_stages = 0", b"unexpected_context"),
        ):
            with self.subTest(data=data), patch.object(
                REBASE, "UPSTREAM_SHA256", hashlib.sha256(data).hexdigest()
            ), self.assertRaisesRegex(ValueError, "missing or ambiguous"):
                REBASE.rebase(data)

    def test_rebase_preserves_mesa_fixes_and_v14_cache_identity(self):
        data = self.fixture()
        with patch.object(REBASE, "UPSTREAM_SHA256", hashlib.sha256(data).hexdigest()):
            result = REBASE.rebase(data).decode()
        self.assertNotIn("diff --git a/src/compiler/nir/nir_opt_uub.c", result)
        self.assertNotIn("+         bound_stages |= pStages[i];", result)
        self.assertIn("VkShaderStageFlagBits stages = 0, bound_stages = 0;", result)
        self.assertIn("max_indirect_draw_count", result)
        self.assertIn("uint32_t base_array_layer", result)
        self.assertIn("+      if (fs_stage->nir &&", result)
        self.assertIn("-      if (!stage->layout.set[i].layout)", result)

    def test_hunk_counts_follow_rebased_context(self):
        text = "@@ -4,1 +5,1 @@ test\n context\n-old\n+new\n+extra\n"
        self.assertEqual(REBASE.recount_hunks(text), "@@ -4,2 +5,3 @@ test\n context\n-old\n+new\n+extra\n")

    def test_split_signatures_do_not_require_context_fuzz(self):
        text = "@@ -4,4 +5,5 @@ test\n first\n second\n third\n fourth\n+added\n"
        result = REBASE.recount_hunks(text)
        self.assertEqual(result, "@@ -5,3 +6,4 @@ test\n second\n third\n fourth\n+added\n")


if __name__ == "__main__":
    unittest.main()
