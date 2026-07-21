import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLKIT = ROOT / "bc250-toolkit.sh"


class ToolkitTests(unittest.TestCase):
    def test_help_lists_components_and_user_privilege_model(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        for command in (
            "status",
            "power",
            "compute",
            "cec",
            "storage",
            "persistence",
            "wifi",
            "audio",
            "decky",
        ):
            self.assertIn(command, result.stdout)
        self.assertIn("logged-in Deck user, not with sudo", result.stdout)

    def test_without_terminal_prints_help(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Usage:", result.stderr)

    def test_component_dispatch_opens_menu_and_rejects_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit = root / TOOLKIT.name
            power = root / "bc250-power.sh"
            shutil.copy2(TOOLKIT, toolkit)
            power.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\"\n",
                encoding="utf-8",
            )

            default = subprocess.run(
                ["bash", str(toolkit), "power"],
                check=True,
                capture_output=True,
                text=True,
            )
            rejected = subprocess.run(
                ["bash", str(toolkit), "power", "freq", "status"],
                capture_output=True,
                text=True,
            )

            self.assertEqual(default.stdout.strip(), "menu")
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Usage:", rejected.stderr)

    def test_script_parses(self):
        subprocess.run(["bash", "-n", str(TOOLKIT)], check=True)


if __name__ == "__main__":
    unittest.main()
