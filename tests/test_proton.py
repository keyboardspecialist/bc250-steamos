import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROTON = ROOT / "bc250-proton.sh"


class ProtonManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        package_root = self.root / "package"
        tool = (
            package_root
            / "usr/share/steam/compatibilitytools.d/protonge-latest-bc250"
        )
        (tool / "ge/files/bin").mkdir(parents=True)
        (tool / "ge/protonfixes").mkdir()
        (tool / "ge/artifacts").mkdir()
        (tool / "proton").write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        (tool / "ge/proton").write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        (tool / "ge/files/bin/wine").write_text(
            "#!/bin/sh\nexit 0\n", encoding="ascii"
        )
        (tool / "proton").chmod(0o755)
        (tool / "ge/proton").chmod(0o755)
        (tool / "ge/files/bin/wine").chmod(0o755)
        (tool / "compatibilitytool.vdf").write_text(
            '"compatibilitytools" { "compat_tools" { '
            '"protonge-latest-bc250" { "install_path" "." } } }\n',
            encoding="ascii",
        )
        (tool / "toolmanifest.vdf").write_text(
            '"manifest" { "commandline" "/proton %verb%" }\n', encoding="ascii"
        )
        (tool / "bc250-fsr4-launch.py").write_text("# wrapper\n", encoding="ascii")
        (tool / "bc250-fsr4-config.json").write_text("{}\n", encoding="ascii")
        (tool / "ge/upscaler-manifest.json").write_text("{}\n", encoding="ascii")
        (tool / "ge/protonfixes/upscalers.py").write_text(
            "# pinned manifest support\n", encoding="ascii"
        )
        (tool / "ge/artifacts/provider.dll.xz").write_bytes(b"provider\n")
        (tool / "files").symlink_to("ge/files")
        licenses = package_root / "usr/share/licenses/protonge-latest-bc250"
        licenses.mkdir(parents=True)
        (licenses / "LICENSE").write_text("test license\n", encoding="ascii")
        self.archive = self.root / "proton.pkg.tar"
        with tarfile.open(self.archive, "w") as output:
            output.add(package_root / "usr", arcname="usr")
        self.sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.mesh = self.root / "mesh.sh"
        self.mesh.write_text(
            "#!/bin/sh\nprintf '%s\\n' "
            "'{\"runtimeState\":\"ready\",\"globalEnabled\":true}'\n",
            encoding="ascii",
        )
        self.env = {
            **os.environ,
            "HOME": str(self.root / "home"),
            "BC250_PROTON_COMPAT_DIR": str(self.root / "compatibilitytools.d"),
            "BC250_PROTON_STATE_DIR": str(self.root / "state"),
            "BC250_PROTON_LOCK_FILE": str(self.root / "lock"),
            "BC250_PROTON_ARCHIVE": str(self.archive),
            "BC250_PROTON_PACKAGE_SHA256": self.sha256,
            "BC250_PROTON_PACKAGE_VERSION": "1.0-test",
            "BC250_PROTON_PACKAGE_NAME": self.archive.name,
            "BC250_MESH_TOOL": str(self.mesh),
        }

    def test_manager_is_executable_and_release_packaged(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="ascii"
        )
        self.assertTrue(os.access(PROTON, os.X_OK))
        self.assertIn("cp README.md bc250-*.sh", workflow)

    def test_default_package_pin_matches_available_upstream_asset(self):
        source = PROTON.read_text(encoding="ascii")
        self.assertIn(
            'PACKAGE_VERSION="${BC250_PROTON_PACKAGE_VERSION:-11.6-166}"', source
        )
        self.assertIn(
            "protonge-latest-bc250-11.6-166-x86_64.pkg.tar.zst", source
        )
        self.assertIn(
            "https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo/",
            source,
        )
        self.assertIn(
            "193e0e3b275024231bce8c0b01ed4220507257f86befc7c6fbb940e55a035640",
            source,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_manager(self, *arguments, env=None, check=False):
        return subprocess.run(
            ["bash", str(PROTON), *arguments],
            env=env or self.env,
            capture_output=True,
            text=True,
            check=check,
        )

    def test_install_status_update_and_uninstall(self):
        missing = self.run_manager("status")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("not-installed", missing.stdout)

        installed = self.run_manager("install", check=True)
        self.assertIn("Installed GE-Proton 1.0-test", installed.stdout)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        self.assertTrue(os.access(target / "proton", os.X_OK))
        self.assertTrue((target / "LICENSE").is_file())
        self.assertFalse((target / "usr").exists())

        status = self.run_manager("status-json", check=True)
        payload = json.loads(status.stdout)
        self.assertEqual(payload["state"], "ready")
        self.assertEqual(payload["installedVersion"], "1.0-test")

        unchanged = self.run_manager("update", check=True)
        self.assertIn("already installed and verified", unchanged.stdout)

        removed = self.run_manager("uninstall", check=True)
        self.assertIn("prefixes and game saves were preserved", removed.stdout)
        self.assertFalse(target.exists())

    def test_install_requires_active_production_radv(self):
        self.mesh.write_text(
            "#!/bin/sh\nprintf '%s\\n' "
            "'{\"runtimeState\":\"ready\",\"globalEnabled\":false}'\n",
            encoding="ascii",
        )
        result = self.run_manager("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FSR4 RADV is not active", result.stderr)
        target = (
            Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        )
        self.assertFalse(target.exists())

    def test_checksum_mismatch_never_creates_tool(self):
        env = {**self.env, "BC250_PROTON_PACKAGE_SHA256": "0" * 64}
        result = self.run_manager("install", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        target = Path(env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        self.assertFalse(target.exists())

    def test_unowned_existing_tool_is_not_replaced(self):
        target = (
            Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        )
        target.mkdir(parents=True)
        sentinel = target / "user-file"
        sentinel.write_text("keep\n", encoding="ascii")
        result = self.run_manager("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unowned compatibility tool", result.stderr)
        self.assertEqual(sentinel.read_text(encoding="ascii"), "keep\n")

    def test_recorded_incomplete_tool_can_be_removed(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        (target / "ge/proton").unlink()
        status = self.run_manager("status")
        self.assertEqual(status.returncode, 2)
        self.assertIn("incomplete", status.stdout)
        self.run_manager("uninstall", check=True)
        self.assertFalse(target.exists())

    def test_modified_integrated_payload_requires_repair(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        (target / "bc250-fsr4-config.json").write_text('{"changed":true}\n')
        status = self.run_manager("status")
        self.assertEqual(status.returncode, 2)
        self.assertIn("incomplete", status.stdout)
        repaired = self.run_manager("update", check=True)
        self.assertIn("Installed GE-Proton", repaired.stdout)
        self.assertEqual(
            (target / "bc250-fsr4-config.json").read_text(encoding="ascii"), "{}\n"
        )

    def test_payload_permission_changes_require_repair(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        config = target / "bc250-fsr4-config.json"
        config.chmod(0o666)
        status = self.run_manager("status")
        self.assertEqual(status.returncode, 2)
        self.assertIn("incomplete", status.stdout)

    def test_control_file_permission_changes_require_repair(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        for name in (".bc250-steamos-install", ".bc250-steamos-files.json"):
            with self.subTest(name=name):
                control = target / name
                control.chmod(0o666)
                status = self.run_manager("status")
                self.assertEqual(status.returncode, 2)
                self.assertIn("incomplete", status.stdout)
                control.chmod(0o644)
                self.run_manager("status", check=True)

    def test_interrupted_upgrade_restores_recorded_tool(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        backup = target.parent / ".protonge-latest-bc250.bc250-backup"
        target.rename(backup)
        transaction = Path(self.env["BC250_PROTON_STATE_DIR"]) / "transaction"
        transaction.mkdir()
        (transaction / "state").write_text("prepared 1\n", encoding="ascii")

        status = self.run_manager("update", check=True)
        self.assertIn("Recovered an interrupted", status.stdout)
        self.assertTrue(target.is_dir())
        self.assertFalse(backup.exists())
        self.assertFalse(transaction.exists())

    def test_prepared_upgrade_does_not_delete_original_before_backup(self):
        self.run_manager("install", check=True)
        target = Path(self.env["BC250_PROTON_COMPAT_DIR"]) / "protonge-latest-bc250"
        transaction = Path(self.env["BC250_PROTON_STATE_DIR"]) / "transaction"
        transaction.mkdir()
        (transaction / "state").write_text("prepared 1\n", encoding="ascii")
        result = self.run_manager("update", check=True)
        self.assertIn("Recovered an interrupted", result.stdout)
        self.assertTrue(target.is_dir())
        self.assertFalse(transaction.exists())

    def test_unrecorded_backup_is_never_deleted(self):
        compat = Path(self.env["BC250_PROTON_COMPAT_DIR"])
        backup = compat / ".protonge-latest-bc250.bc250-backup"
        backup.mkdir(parents=True)
        sentinel = backup / "user-file"
        sentinel.write_text("keep\n", encoding="ascii")
        result = self.run_manager("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecorded GE-Proton backup", result.stderr)
        self.assertEqual(sentinel.read_text(encoding="ascii"), "keep\n")

    def test_interrupted_removal_deletes_only_recorded_tombstone(self):
        self.run_manager("install", check=True)
        compat = Path(self.env["BC250_PROTON_COMPAT_DIR"])
        target = compat / "protonge-latest-bc250"
        tombstone = compat / ".protonge-latest-bc250.bc250-removing"
        target.rename(tombstone)
        removal = Path(self.env["BC250_PROTON_STATE_DIR"]) / "removal"
        removal.mkdir()
        (removal / "state").write_text(
            f"1.0-test {self.sha256}\n", encoding="ascii"
        )
        (tombstone / ".bc250-steamos-install").unlink()

        result = self.run_manager("uninstall", check=True)
        self.assertIn("Recovered an interrupted GE-Proton removal", result.stdout)
        self.assertIn("is not installed", result.stdout)
        self.assertFalse(tombstone.exists())
        self.assertFalse(removal.exists())


if __name__ == "__main__":
    unittest.main()
