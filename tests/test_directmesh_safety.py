from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

import test_mesh_shader as fixtures


class DirectMeshSafetyTests(unittest.TestCase):
    def prepare(self, root):
        helper = fixtures.MeshShaderTests()
        env = helper.environment(root)
        # These tests exercise path validation; do not bypass Python preflights.
        (root / "bin/python3").write_text(
            '#!/bin/sh\nexec "{}" "$@"\n'.format(sys.executable), encoding="utf-8"
        )
        helper.install_native_mesh_runtime(env)
        return env, Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh", Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2"

    def verify(self, env, command="preflight_retired_native_mesh"):
        return subprocess.run(
            ["bash", "-c", 'script=$1; set -- help; source "$script" >/dev/null; '
             'require_r2_idle() { :; }; ' + command, "test", str(fixtures.MESH)],
            env=env, capture_output=True, text=True,
        )

    def test_unexpected_profile_file_blocks_cleanup_of_both_destinations(self):
        with tempfile.TemporaryDirectory() as temporary:
            env, profile, tool = self.prepare(Path(temporary))
            extra = profile / "my-notes.txt"
            extra.write_text("user file\n")
            result = self.verify(env, "remove_retired_native_mesh")
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("modified or unrecognized", result.stderr)
            self.assertEqual(extra.read_text(), "user file\n")
            self.assertTrue(tool.exists())

    def test_symlinked_notice_directory_is_not_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env, profile, tool = self.prepare(root)
            outside = root / "original-notices"
            (profile / "licenses").rename(outside)
            (profile / "licenses").symlink_to(outside, target_is_directory=True)
            result = self.verify(env, "remove_retired_native_mesh")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((outside / "mesa-license.rst").exists())
            self.assertTrue(tool.exists())

    def test_symlinked_compatibility_ancestor_blocks_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env, profile, tool = self.prepare(root)
            actual = root / "actual-steam"
            actual.mkdir()
            tool.parent.rename(actual / "compatibilitytools.d")
            (root / "steam-link").symlink_to(actual, target_is_directory=True)
            env["BC250_R2_COMPAT_DIR"] = str(root / "steam-link/compatibilitytools.d")
            result = self.verify(env, "remove_retired_native_mesh")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe ancestor", result.stderr)
            self.assertTrue(profile.exists())
            self.assertTrue((actual / "compatibilitytools.d/BC250-R2/proton").exists())

    def test_process_scan_blocks_mapped_driver_before_recovery(self):
        source = fixtures.MESH.read_text()
        code = source.split("scan_script=$(cat <<'PY'\n", 1)[1].split("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = root / "123456"
            process.mkdir()
            (process / "cmdline").write_bytes(b"game\0")
            (process / "maps").write_bytes(b"r-xp /private/r2/libvulkan_radeon.so\n")
            uid = process.stat().st_uid
            (process / "status").write_text("Uid:\t{0}\t{0}\t{0}\t{0}\n".format(uid))
            code = code.replace('Path("/proc")', "Path(" + repr(str(root)) + ")")
            result = subprocess.run(
                [sys.executable, "-c", code, "/private/r2", "/steam/BC250-R2", str(process.stat().st_uid)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("R2 is in use (PID 123456)", result.stderr)

    def test_mesh_cli_forwards_latest_and_local_dlss_without_losing_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = fixtures.MeshShaderTests().environment(root)
            helper = root / "helixsr.sh"
            log = root / "arguments"
            helper.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "{}"\n'.format(log))
            env["BC250_HELIXSR_TOOL"] = str(helper)
            dlss = str(root / "local DLL/nvngx_dlss.dll")
            result = subprocess.run(
                ["bash", "-c", 'script=$1; shift; set -- "$@"; '
                 'source <(sed "s/^    require_normal_user$/    :/" "$script")',
                 "test", str(fixtures.MESH), "helixsr-prepare", "--latest", dlss],
                env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["prepare", "--latest", dlss])

    def test_protected_process_maps_use_readonly_root_retry_and_fail_closed(self):
        for root_result in (0, 75):
            with self.subTest(root_result=root_result), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                env = fixtures.MeshShaderTests().environment(root)
                log = root / "root-scan"
                (root / "bin/python3").write_text(
                    "#!/bin/sh\ncat >/dev/null\nexit 75\n", encoding="ascii"
                )
                env["TEST_SCAN_LOG"] = str(log)
                env["TEST_SCAN_RC"] = str(root_result)
                result = subprocess.run(
                    ["bash", "-c", 'script=$1; set -- help; source "$script" >/dev/null; '
                     'as_root() { printf "%s\\n" "$@" > "$TEST_SCAN_LOG"; '
                     'cat >/dev/null; return "$TEST_SCAN_RC"; }; require_r2_idle',
                     "test", str(fixtures.MESH)],
                    env=env, capture_output=True, text=True,
                )
                args = log.read_text().splitlines()
                self.assertEqual(args[:3], ["/usr/bin/python3", "-I", "-"])
                self.assertEqual(args[-1], str(os.getuid()))
                self.assertIn("read-only", result.stdout)
                if root_result:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("No R2 files were removed", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
