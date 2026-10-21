import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_mesh_shader as fixtures


MESH = fixtures.MESH
ROOT = fixtures.ROOT


class DirectMeshTests(unittest.TestCase):
    def environment(self, root):
        return fixtures.MeshShaderTests().environment(root)

    def install_runtime(self, env):
        fixtures.MeshShaderTests().install_runtime(env)

    def install_r2(self, env):
        fixtures.MeshShaderTests().install_native_mesh_runtime(env)

    def run_shell(self, env, command):
        return subprocess.run(
            ["bash", "-c", 'script=$1; set -- help; source "$script" >/dev/null; '
             + command, "_", str(MESH)],
            env=env, capture_output=True, text=True,
        )

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def snapshot(self, root):
        return {
            path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file() and not path.is_symlink()
        }

    def test_directmesh_is_the_global_default_and_pinned(self):
        source = MESH.read_text()
        self.assertIn('DEFAULT_MESA_TAG="mesa-26.2.5"', source)
        self.assertIn('MESA_COMMIT="ddaf85e353442d9d7f192fdcf1823e652e3f2ee3"', source)
        self.assertIn('RADV_PROFILE_REVISION="directmesh-1.3.1-fsr4-v5"', source)
        self.assertIn('DIRECTMESH_RELEASE="directmesh-v1.3.1"', source)
        self.assertIn('if (($# == 1)); then cmd_setup default', source)
        self.assertIn('[[ "$2" == --directmesh ]]', source)
        self.assertIn('RADV_DIRECTMESH=0 %command%', source)
        self.assertNotIn('export RADV_DIRECTMESH=1', source)
        self.assertIn('DIRECTMESH_REBASE="$MESA_PATCH_DIR/rebase-directmesh.py"', source)

    def test_directmesh_rebaser_rejects_unpinned_input(self):
        with tempfile.TemporaryDirectory() as directory:
            patch = Path(directory) / "patch"
            patch.write_text("not the pinned DirectMesh patch\n")
            result = subprocess.run(
                ["python3", str(ROOT / "bc250-mesa-patches/rebase-directmesh.py"), str(patch)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pinned upstream checksum", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_r2_installer_cli_is_retired_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            result = subprocess.run(
                ["bash", str(MESH), "setup", "--native-mesh"],
                env=env, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("retired", result.stderr)
            self.assertFalse(Path(env["BC250_MESH_STATE_DIR"]).exists())
            self.assertFalse(Path(env["BC250_R2_COMPAT_DIR"]).exists())

    def test_setup_cleans_r2_on_current_runtime_fast_path_without_build(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_r2(env)
            steam = Path(env["BC250_R2_STEAM_ROOT"])
            for relative, content in {
                "steamapps/common/Proton 11.0/proton": b"original Proton\n",
                "steamapps/compatdata/123/pfx/save.dat": b"game save\n",
                "userdata/123/config/localconfig.vdf": b"game settings\n",
            }.items():
                path = steam / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            steam_before = self.snapshot(steam)
            state = Path(env["BC250_MESH_STATE_DIR"])
            original = {name: Path(env[name]).read_bytes() for name in (
                "BC250_MESH_DRIVER", "BC250_MESH_ICD", "BC250_GFX1013_GENERATOR"
            )}
            result = self.run_shell(env, '''
require_production_kernel_paths() { :; }
ensure_radv_prerequisites() { :; }
stage_upstream() { echo unexpected-build >&2; return 71; }
cmd_setup default
''')
            self.assert_ok(result)
            self.assertIn("no Mesa rebuild", result.stdout)
            self.assertFalse((state / "native-mesh").exists())
            self.assertFalse((Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2").exists())
            for name, content in original.items():
                self.assertEqual(Path(env[name]).read_bytes(), content)
            self.assertEqual(self.snapshot(steam), steam_before)

    def test_setup_cleans_r2_before_kernel_build_prerequisites(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_r2(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            result = self.run_shell(env, '''
require_production_kernel_paths() { :; }
ensure_radv_core_tools() { :; }
ensure_compute_kernel_prerequisite() {
    [[ ! -e "$NATIVE_MESH_DIR" && ! -e "$NATIVE_MESH_TOOL" ]] || exit 74
    return 1
}
ensure_radv_prerequisites() { echo unexpected-packages >&2; return 73; }
cmd_setup default
''')
            self.assert_ok(result)
            self.assertNotIn("unexpected", result.stderr)
            self.assertFalse((state / "native-mesh").exists())
            self.assertTrue(Path(env["BC250_MESH_DRIVER"]).exists())

    def test_setup_rejects_modified_r2_before_package_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_r2(env)
            profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
            (profile / "README.md").write_text("user changes\n")
            before = self.snapshot(profile)
            result = self.run_shell(env, '''
require_production_kernel_paths() { :; }
ensure_radv_prerequisites() { echo unexpected-package-repair >&2; return 73; }
stage_upstream() { echo unexpected-build >&2; return 74; }
cmd_setup default
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing cleanup", result.stderr)
            self.assertNotIn("unexpected", result.stderr)
            self.assertEqual(self.snapshot(profile), before)
            self.assertTrue((Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2").exists())

    def test_previous_global_profile_migrates_and_removes_lonewolf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            fixtures.MeshShaderTests().install_legacy_native_mesh_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            manifest = state / "install.conf"
            fields = manifest.read_text().split()
            fields[2] = "mesa-26.2.2"
            fields[4] = "production-fsr4-v4"
            manifest.write_text(" ".join(fields) + "\n")
            (root / "new-driver.so").write_bytes(b"new DirectMesh driver\n")
            result = self.run_shell(env, '''
preflight_runtime_ownership 0
verify_legacy_native_mesh_runtime
! verify_current_runtime
ro_was_enabled=0
staged_driver="${DRIVER}.bc250-new"
work=$(mktemp -d "$STATE_DIR/.migration.XXXXXX")
unlock_root() { :; }
relock_root() { :; }
ensure_state_dir
exec 9> "$LOCK_FILE"
flock 9
install_default_profile "${DRIVER%/*}/new-driver.so" "$DEFAULT_MESA_TAG"
verify_current_runtime
''')
            self.assert_ok(result)
            self.assertFalse((state / "native-mesh").exists())
            self.assertEqual(manifest.read_text().split()[2:5], [
                "mesa-26.2.5", fixtures.UPSTREAM_COMMIT, fixtures.RADV_PROFILE_REVISION
            ])
            self.assertEqual(Path(env["BC250_MESH_DRIVER"]).read_bytes(), b"new DirectMesh driver\n")

    def test_cleanup_handles_independently_attested_orphans(self):
        for orphan in ("profile", "tool"):
            with self.subTest(orphan=orphan), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_r2(env)
                profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
                tool = Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2"
                shutil.rmtree(tool if orphan == "profile" else profile)
                result = self.run_shell(env, "remove_retired_native_mesh")
                self.assert_ok(result)
                self.assertFalse(profile.exists())
                self.assertFalse(tool.exists())

    def test_cleanup_refuses_unowned_or_modified_orphan_tool(self):
        for kind in ("unowned", "modified", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = self.environment(root)
                self.install_r2(env)
                profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
                tool = Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2"
                shutil.rmtree(profile)
                if kind == "unowned":
                    (tool / ".bc250-r2-managed").unlink()
                elif kind == "modified":
                    (tool / "files/lib/wine/vkd3d-proton/x86_64-windows/d3d12core.dll").write_bytes(b"user DLL")
                else:
                    real = root / "user-tool"
                    tool.rename(real)
                    tool.symlink_to(real, target_is_directory=True)
                before = self.snapshot(tool)
                result = self.run_shell(env, "remove_retired_native_mesh")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing cleanup", result.stderr)
                self.assertEqual(self.snapshot(tool), before)
                self.assertTrue(tool.exists())

    def test_cleanup_validates_both_halves_before_deleting_either(self):
        for target in ("profile", "tool"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_r2(env)
                profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
                tool = Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2"
                if target == "profile":
                    (profile / "LICENSE").write_text("user changes\n")
                else:
                    (tool / ".bc250-r2-managed").write_text("unrecognized\n")
                before = (self.snapshot(profile), self.snapshot(tool))
                result = self.run_shell(env, "remove_retired_native_mesh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.snapshot(profile), self.snapshot(tool)), before)

    def test_cleanup_refuses_r2_in_use_before_deleting_files(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_r2(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            before = self.snapshot(state)
            result = self.run_shell(env, '''
require_r2_idle() { die "BC250 R2 is in use; close its games/tools and retry."; }
remove_retired_native_mesh
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("in use", result.stderr)
            self.assertEqual(self.snapshot(state), before)
            self.assertTrue((Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2").exists())

    def test_source_built_r2_records_still_require_pinned_provenance(self):
        for valid in (True, False):
            with self.subTest(valid=valid), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_r2(env)
                profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
                manifest = profile / "install.conf"
                fields = manifest.read_text().split()
                fields[0] = "3"
                env["BC250_R2_SOURCE_ARCHIVE_SHA256"] = "b" * 64
                fields += ["source", "b" * 64 if valid else "c" * 64]
                manifest.write_text(" ".join(fields) + "\n")
                result = self.run_shell(env, "remove_retired_native_mesh")
                if valid:
                    self.assert_ok(result)
                    self.assertFalse(profile.exists())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(profile.exists())

    def test_cleanup_removes_only_checksum_pinned_regular_archives(self):
        for kind in ("verified", "modified", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = self.environment(root)
                self.install_r2(env)
                cache = Path(env["BC250_MESH_STATE_DIR"]) / ("upstream-" + fixtures.UPSTREAM_COMMIT)
                cache.mkdir()
                payload = b"synthetic pinned R2 archive\n"
                archive = cache / "bc250-r2-linux-x86_64.tar.gz"
                source = cache / "mesa-r2-source.tar.gz"
                for path in (archive, source):
                    path.write_bytes(payload)
                env["BC250_R2_ARCHIVE_SHA256"] = hashlib.sha256(payload).hexdigest()
                env["BC250_R2_SOURCE_ARCHIVE_SHA256"] = hashlib.sha256(payload).hexdigest()
                if kind == "modified":
                    archive.write_bytes(b"user cache file\n")
                    source.write_bytes(b"user source archive\n")
                elif kind == "symlink":
                    real = root / "user-archive"
                    real.write_bytes(payload)
                    archive.unlink()
                    source.unlink()
                    archive.symlink_to(real)
                    source.symlink_to(real)
                # Keep the schema-2 profile's recorded archive hash in sync.
                manifest = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh/install.conf"
                fields = manifest.read_text().split()
                fields[1] = env["BC250_R2_ARCHIVE_SHA256"]
                manifest.write_text(" ".join(fields) + "\n")
                result = self.run_shell(env, "remove_retired_native_mesh")
                self.assert_ok(result)
                for path in (archive, source):
                    self.assertEqual(path.exists(), kind != "verified")
                if kind == "symlink":
                    self.assertEqual(real.read_bytes(), payload)

    def test_recovery_refuses_modified_or_unrecognized_live_profile(self):
        for target in ("modified", "unrecognized", "symlink"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = self.environment(root)
                self.install_r2(env)
                state = Path(env["BC250_MESH_STATE_DIR"])
                profile = state / "native-mesh"
                transaction = state / "native-mesh-install-transaction"
                shutil.copytree(profile, transaction / "previous")
                (transaction / "transaction.conf").write_text("swapping 1\n")
                if target == "modified":
                    (profile / "README.md").write_text("user edits\n")
                else:
                    shutil.rmtree(profile)
                    if target == "unrecognized":
                        profile.mkdir()
                        (profile / "user-file").write_text("keep me\n")
                    else:
                        real = root / "user-profile"
                        real.mkdir()
                        (real / "user-file").write_text("keep me\n")
                        profile.symlink_to(real, target_is_directory=True)
                before = self.snapshot(profile)
                result = self.run_shell(env, "recover_native_mesh_install_transaction")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("manual recovery required", result.stderr)
                self.assertEqual(self.snapshot(profile), before)
                self.assertTrue(transaction.exists())
                self.assertTrue((Path(env["BC250_R2_COMPAT_DIR"]) / "BC250-R2").exists())

    def test_cleanup_refuses_symlinked_cache_ancestor_without_deleting_user_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_r2(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            cache = state / ("upstream-" + fixtures.UPSTREAM_COMMIT)
            user_cache = root / "user-cache"
            user_cache.mkdir()
            (user_cache / "bc250-r2-linux-x86_64.tar.gz").write_bytes(b"user archive")
            cache.symlink_to(user_cache, target_is_directory=True)
            before = self.snapshot(state)
            result = self.run_shell(env, "remove_retired_native_mesh")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing cleanup", result.stderr)
            self.assertEqual(self.snapshot(state), before)
            self.assertEqual((user_cache / "bc250-r2-linux-x86_64.tar.gz").read_bytes(), b"user archive")

    def test_recovery_preserves_tampered_backup_even_with_intact_live_runtime(self):
        for phase in ("prepared", "swapping"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_r2(env)
                state = Path(env["BC250_MESH_STATE_DIR"])
                profile = state / "native-mesh"
                transaction = state / "native-mesh-install-transaction"
                shutil.copytree(profile, transaction / "previous")
                (transaction / "transaction.conf").write_text(f"{phase} 1\n")
                (transaction / "previous/LICENSE").write_text("modified backup\n")
                before = self.snapshot(state)
                result = self.run_shell(env, "recover_native_mesh_install_transaction")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("backup failed attestation", result.stderr)
                self.assertEqual(self.snapshot(state), before)

    def test_recovery_preserves_unrecognized_transaction_contents(self):
        for kind in ("extra-file", "unexpected-backup", "multiline-record"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                state = Path(env["BC250_MESH_STATE_DIR"])
                transaction = state / "native-mesh-install-transaction"
                transaction.mkdir(parents=True)
                record = transaction / "transaction.conf"
                record.write_text("prepared 0\n")
                if kind == "extra-file":
                    (transaction / "user-file").write_text("keep me\n")
                elif kind == "unexpected-backup":
                    (transaction / "previous").mkdir()
                    (transaction / "previous/user-file").write_text("keep me\n")
                else:
                    record.write_text("prepared 0\nadditional data\n")
                before = self.snapshot(state)
                result = self.run_shell(env, "recover_native_mesh_install_transaction")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("manual recovery required", result.stderr)
                self.assertEqual(self.snapshot(state), before)

    def test_recovery_completes_intact_legacy_install_without_runtime_linkage(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_r2(env)
            env["BC250_TEST_LDD_GNU2_TLS_MISSING"] = "1"
            state = Path(env["BC250_MESH_STATE_DIR"])
            transaction = state / "native-mesh-install-transaction"
            transaction.mkdir()
            (transaction / "transaction.conf").write_text("swapping 0\n")
            profile = state / "native-mesh"
            before = self.snapshot(profile)
            result = self.run_shell(env, "recover_native_mesh_install_transaction")
            self.assert_ok(result)
            self.assertFalse(transaction.exists())
            self.assertEqual(self.snapshot(profile), before)


if __name__ == "__main__":
    unittest.main()
