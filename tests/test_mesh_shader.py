import hashlib
import json
import os
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MESH = ROOT / "bc250-mesh-shader.sh"


class MeshShaderTests(unittest.TestCase):
    def environment(self, root: Path):
        home = root / "home"
        state = home / ".local" / "share" / "bc250-mesh-shader"
        bindir = root / "bin"
        bindir.mkdir()
        sudo = bindir / "sudo"
        sudo.write_text('#!/bin/sh\nexec "$@"\n', encoding="utf-8")
        sudo.chmod(0o755)
        flock = bindir / "flock"
        flock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        flock.chmod(0o755)
        install = bindir / "install"
        install.write_text(
            "#!/bin/sh\n"
            "while [ $# -gt 2 ]; do\n"
            "  case \"$1\" in -o|-g|-m) shift 2 ;; *) break ;; esac\n"
            "done\n"
            "cp \"$1\" \"$2\"\n",
            encoding="utf-8",
        )
        install.chmod(0o755)
        sync = bindir / "sync"
        sync.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        sync.chmod(0o755)
        return {
            **os.environ,
            "HOME": str(home),
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "BC250_MESH_STATE_DIR": str(state),
            "BC250_MESH_DRIVER": str(root / "libvulkan_radeon_driconf.so"),
            "BC250_MESH_ICD": str(home / "radeon_driconf_icd.x86_64.json"),
            "BC250_MESH_DRIRC": str(home / ".drirc"),
        }

    def install_runtime(self, root: Path, env):
        driver = Path(env["BC250_MESH_DRIVER"])
        icd = Path(env["BC250_MESH_ICD"])
        state = Path(env["BC250_MESH_STATE_DIR"])
        driver.parent.mkdir(parents=True, exist_ok=True)
        icd.parent.mkdir(parents=True, exist_ok=True)
        state.mkdir(parents=True, exist_ok=True)
        driver.write_bytes(b"driver\n")
        icd.write_text(
            '{"ICD":{"library_path":"%s"}}\n' % driver, encoding="utf-8"
        )
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        (state / "install.conf").write_text(
            "%s %s mesa-26.1.4 b66203e012594204e5e3049856b28a2681112985\n"
            % (digest(driver), digest(icd)),
            encoding="ascii",
        )

    def test_status_is_read_only_when_not_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            result = subprocess.run(
                ["bash", str(MESH), "status"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("not installed", result.stdout)
            self.assertFalse(Path(env["BC250_MESH_STATE_DIR"]).exists())
            self.assertFalse(Path(env["BC250_MESH_DRIRC"]).exists())

    def test_status_json_is_structured_and_read_only_when_not_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            result = subprocess.run(
                ["bash", str(MESH), "status-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            status = json.loads(result.stdout)
            self.assertTrue(status["scriptAvailable"])
            self.assertEqual(status["runtimeState"], "not-installed")
            self.assertTrue(status["configValid"])
            self.assertEqual(status["games"], [])
            self.assertFalse(Path(env["BC250_MESH_STATE_DIR"]).exists())
            self.assertFalse(Path(env["BC250_MESH_DRIRC"]).exists())

    def test_status_json_lists_appid_alias_and_enable_prints_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            enabled = subprocess.run(
                [
                    "bash",
                    str(MESH),
                    "game",
                    "enable",
                    "bc250-steam-1462040",
                    "Final Fantasy VII Rebirth",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn(
                "MESA_DRICONF_EXECUTABLE_OVERRIDE='bc250-steam-1462040'",
                enabled.stdout,
            )
            status_result = subprocess.run(
                ["bash", str(MESH), "status-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            status = json.loads(status_result.stdout)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertEqual(status["mesaVersion"], "mesa-26.1.4")
            self.assertEqual(
                status["games"],
                [
                    {
                        "executable": "bc250-steam-1462040",
                        "name": "Final Fantasy VII Rebirth",
                    }
                ],
            )

    def test_enable_shell_quotes_printed_launch_option(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            result = subprocess.run(
                ["bash", str(MESH), "game", "enable", "game'$(touch nope).exe"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
                cwd=root,
            )
            self.assertIn(
                "MESA_DRICONF_EXECUTABLE_OVERRIDE='game'\"'\"'$(touch nope).exe'",
                result.stdout,
            )
            self.assertFalse((root / "nope").exists())

    def test_status_json_reports_invalid_drirc_without_failing_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            Path(env["BC250_MESH_DRIRC"]).write_text("<not-closed>", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(MESH), "status-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            status = json.loads(result.stdout)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertFalse(status["configValid"])
            self.assertIn("not valid XML", status["error"])
            self.assertEqual(status["games"], [])

    def test_per_game_toggle_preserves_unrelated_drirc_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            drirc = Path(env["BC250_MESH_DRIRC"])
            drirc.write_text(
                '<driconf>\n  <device driver="other" />\n</driconf>\n',
                encoding="utf-8",
            )

            subprocess.run(
                ["bash", str(MESH), "game", "enable", "game.exe", "Test Game"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            enabled = drirc.read_text(encoding="utf-8")
            ET.fromstring(enabled)
            self.assertIn('<device driver="other" />', enabled)
            self.assertIn("BEGIN BC250 MESH SHADER MANAGED", enabled)
            self.assertIn('executable="game.exe"', enabled)

            subprocess.run(
                ["bash", str(MESH), "game", "disable", "game.exe"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            disabled = drirc.read_text(encoding="utf-8")
            ET.fromstring(disabled)
            self.assertIn('<device driver="other" />', disabled)
            self.assertNotIn("BC250 MESH SHADER MANAGED", disabled)

    def test_malformed_managed_block_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            drirc = Path(env["BC250_MESH_DRIRC"])
            original = (
                "<driconf>\n"
                "<!-- END BC250 MESH SHADER MANAGED -->\n"
                "<!-- BEGIN BC250 MESH SHADER MANAGED -->\n"
                "</driconf>\n"
            )
            drirc.write_text(original, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(MESH), "game", "enable", "game.exe"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(drirc.read_text(encoding="utf-8"), original)

    def test_uninstall_removes_only_owned_runtime_and_managed_block(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            subprocess.run(
                ["bash", str(MESH), "game", "enable", "game.exe"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            subprocess.run(
                ["bash", str(MESH), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertFalse(Path(env["BC250_MESH_DRIVER"]).exists())
            self.assertFalse(Path(env["BC250_MESH_ICD"]).exists())
            self.assertNotIn(
                "BC250 MESH SHADER MANAGED",
                Path(env["BC250_MESH_DRIRC"]).read_text(encoding="utf-8"),
            )

    def test_uninstall_repairs_root_side_file_lost_after_update(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            Path(env["BC250_MESH_DRIVER"]).unlink()
            result = subprocess.run(
                ["bash", str(MESH), "status"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("incomplete", result.stdout)
            subprocess.run(
                ["bash", str(MESH), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertFalse(Path(env["BC250_MESH_ICD"]).exists())
            self.assertFalse(
                (Path(env["BC250_MESH_STATE_DIR"]) / "install.conf").exists()
            )

    def test_uninstall_recovers_interrupted_install_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(root, env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            driver = Path(env["BC250_MESH_DRIVER"])
            icd = Path(env["BC250_MESH_ICD"])
            manifest = state / "install.conf"
            transaction = state / "install-transaction"
            transaction.mkdir()
            for source, name in (
                (driver, "driver"),
                (icd, "icd"),
                (manifest, "manifest"),
            ):
                (transaction / name).write_bytes(source.read_bytes())
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (transaction / "transaction.conf").write_text(
                "1 1 %s 1 %s 1 %s\n"
                % (
                    digest(transaction / "driver"),
                    digest(transaction / "icd"),
                    digest(transaction / "manifest"),
                ),
                encoding="ascii",
            )
            driver.write_bytes(b"interrupted-new-driver\n")
            icd.write_text("interrupted\n", encoding="utf-8")
            manifest.write_text("interrupted\n", encoding="utf-8")

            subprocess.run(
                ["bash", str(MESH), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertFalse(transaction.exists())
            self.assertFalse(driver.exists())
            self.assertFalse(icd.exists())

    def test_script_parses(self):
        subprocess.run(["bash", "-n", str(MESH)], check=True)


if __name__ == "__main__":
    unittest.main()
