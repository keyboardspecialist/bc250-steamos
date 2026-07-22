import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Dict, Tuple


ROOT = Path(__file__).resolve().parents[1]
MAINTENANCE = ROOT / "bc250-maintenance.sh"


class MaintenanceTests(unittest.TestCase):
    def make_environment(self, directory: Path) -> Tuple[Dict[str, str], Path]:
        call_log = directory / "calls"
        bindir = directory / "bin"
        bindir.mkdir()
        sudo = bindir / "sudo"
        sudo.write_text('#!/bin/sh\nexec "$@"\n', encoding="utf-8")
        sudo.chmod(0o755)

        env = os.environ.copy()
        env["HOME"] = str(directory / "home")
        env["PATH"] = f"{bindir}:{env['PATH']}"
        env["CALL_LOG"] = str(call_log)

        scripts = {
            "POWER_SH": "power",
            "COMPUTE_SH": "compute",
            "CEC_SH": "cec",
            "STORAGE_SH": "storage",
            "AIC_SH": "aic",
            "AUDIO_SH": "audio",
            "DECKY_SH": "decky",
            "DESKTOP_SH": "desktop",
        }
        for variable, name in scripts.items():
            script = directory / f"{name}.sh"
            script.write_text(
                "#!/usr/bin/env bash\n"
                "case \"${1:-}\" in\n"
                "  status|installed) echo installed; exit 0 ;;\n"
                f'  uninstall) printf "%s\\n" "{name}:uninstall" >> "$CALL_LOG"; '
                f'[ "${{FAIL_COMPONENT:-}}" != "{name}" ] || exit 9 ;;\n'
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            script.chmod(0o755)
            env[variable] = str(script)

        persistence = directory / "persistence.sh"
        persistence.write_text(
            '#!/usr/bin/env bash\nprintf "persistence:%s\\n" "$*" >> "$CALL_LOG"\n',
            encoding="utf-8",
        )
        persistence.chmod(0o755)
        env["PERSISTENCE_SH"] = str(persistence)

        audio_clean = directory / "audio-clean.sh"
        audio_clean.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        audio_clean.chmod(0o755)
        env["AUDIO_CLEAN_SH"] = str(audio_clean)
        return env, call_log

    def test_help_documents_preserving_uninstall_and_purge(self):
        result = subprocess.run(
            ["bash", str(MAINTENANCE), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("uninstall COMPONENT|all", result.stdout)
        self.assertIn("preserves settings and persistent data", result.stdout)
        self.assertIn("purge", result.stdout)

    def test_status_and_plan_are_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            env, call_log = self.make_environment(Path(temporary))
            status = subprocess.run(
                ["bash", str(MAINTENANCE), "status"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            plan = subprocess.run(
                ["bash", str(MAINTENANCE), "plan", "all"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(status.stdout.count("installed"), 8)
            self.assertIn("Saved tuning profiles", plan.stdout)
            self.assertFalse(call_log.exists())

    def test_uninstall_all_uses_dependency_safe_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            env, call_log = self.make_environment(Path(temporary))
            subprocess.run(
                ["bash", str(MAINTENANCE), "uninstall", "all", "--yes"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(
                call_log.read_text(encoding="utf-8").splitlines(),
                [
                    "desktop:uninstall",
                    "persistence:remove desktop",
                    "decky:uninstall",
                    "cec:uninstall",
                    "persistence:remove cec",
                    "power:uninstall",
                    "persistence:remove power",
                    "compute:uninstall",
                    "persistence:remove compute",
                    "audio:uninstall",
                    "aic:uninstall",
                    "persistence:remove aic",
                    "persistence:remove all",
                    "storage:uninstall",
                ],
            )

    def test_noninteractive_uninstall_requires_explicit_yes(self):
        with tempfile.TemporaryDirectory() as temporary:
            env, call_log = self.make_environment(Path(temporary))
            result = subprocess.run(
                ["bash", str(MAINTENANCE), "uninstall", "desktop"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("use --yes", result.stderr)
            self.assertFalse(call_log.exists())

    def test_failed_component_keeps_persistence_and_blocks_storage_teardown(self):
        with tempfile.TemporaryDirectory() as temporary:
            env, call_log = self.make_environment(Path(temporary))
            env["FAIL_COMPONENT"] = "power"
            result = subprocess.run(
                ["bash", str(MAINTENANCE), "uninstall", "all", "--yes"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            calls = call_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("power:uninstall", calls)
            self.assertNotIn("persistence:remove power", calls)
            self.assertNotIn("persistence:remove all", calls)
            self.assertNotIn("storage:uninstall", calls)
            self.assertIn("aic:uninstall", calls)

    def test_scripts_parse(self):
        subprocess.run(
            ["bash", "-n", str(MAINTENANCE), str(ROOT / "bc250-storage.sh")],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
