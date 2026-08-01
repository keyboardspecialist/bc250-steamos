import json
import os
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
            "ram",
            "compute",
            "cec",
            "storage",
            "persistence",
            "wifi",
            "audio",
            "mesh",
            "decky",
            "manage",
            "inventory-json",
            "action OPERATION_ID",
        ):
            self.assertIn(command, result.stdout)
        self.assertIn("logged-in Deck user, not with sudo", result.stdout)

    def make_action_environment(self, root):
        toolkit = root / TOOLKIT.name
        shutil.copy2(TOOLKIT, toolkit)
        call_log = root / "calls"
        bindir = root / "bin"
        bindir.mkdir()
        (bindir / "sudo").write_text(
            "#!/usr/bin/env bash\n"
            "printf 'sudo' >> \"$CALL_LOG\"\n"
            "for argument; do printf '|%s' \"$argument\" >> \"$CALL_LOG\"; done\n"
            "printf '|machine=%s\\n' \"${BC250_TOOLKIT_MACHINE:-}\" >> \"$CALL_LOG\"\n",
            encoding="utf-8",
        )
        (bindir / "sudo").chmod(0o755)

        scripts = (
            "bc250-storage.sh",
            "bc250-power.sh",
            "bc250-ram-split.sh",
            "bc250-40cu.sh",
            "bc250-cec.sh",
            "bc250-update-persistence.sh",
            "bc250-mesh-shader.sh",
            "bc250-maintenance.sh",
            "aic8800/steamdeck-setup.sh",
            "bc250-audio-fix/patch-driver.sh",
            "decky-plugin/install.sh",
            "desktop-control/install.sh",
        )
        for relative in scripts:
            script = root / relative
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "#!/usr/bin/env bash\n"
                f"printf '{relative}' >> \"$CALL_LOG\"\n"
                "for argument; do printf '|%s' \"$argument\" >> \"$CALL_LOG\"; done\n"
                "printf '|machine=%s\\n' \"${BC250_TOOLKIT_MACHINE:-}\" >> \"$CALL_LOG\"\n",
                encoding="utf-8",
            )

        env = os.environ.copy()
        env["PATH"] = f"{bindir}:{env['PATH']}"
        env["CALL_LOG"] = str(call_log)
        return toolkit, call_log, env

    def make_inventory_environment(self, root):
        toolkit = root / TOOLKIT.name
        maintenance = root / "bc250-maintenance.sh"
        shutil.copy2(TOOLKIT, toolkit)
        shutil.copy2(ROOT / "bc250-maintenance.sh", maintenance)

        probes = {
            "bc250-power.sh": ("installed", 0),
            "bc250-ram-split.sh": ("installed", 0),
            "bc250-40cu.sh": ("installed", 0),
            "bc250-cec.sh": ("installed", 1),
            "bc250-storage.sh": ("installed", 0),
            "bc250-mesh-shader.sh": ("status", 0),
            "aic8800/steamdeck-setup.sh": ("status", 0),
            "bc250-audio-fix/patch-driver.sh": ("status", 0),
            "decky-plugin/install.sh": ("status", 1),
            "desktop-control/install.sh": ("status", 0),
            "trainer/install.sh": ("status", 0),
            "trainer/install-flatpak.sh": ("status", 1),
        }
        for relative, (probe, result) in probes.items():
            script = root / relative
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "#!/usr/bin/env bash\n"
                f"[[ \"${{1:-}}\" == {probe} ]] || exit 2\n"
                f"exit {result}\n",
                encoding="utf-8",
            )

        home = root / "home"
        cec_artifact = home / ".config/systemd/user/bc250-cec-boot-wake.service"
        cec_artifact.parent.mkdir(parents=True)
        cec_artifact.touch()
        env = os.environ.copy()
        env["HOME"] = str(home)
        return toolkit, env

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

    def test_action_dispatch_is_a_fixed_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit, call_log, env = self.make_action_environment(root)
            mappings = {
                "storage-install": ("sudo", "bc250-storage.sh", "install"),
                "storage-repair": ("sudo", "bc250-storage.sh", "repair-infrastructure"),
                "power-install": ("sudo", "bc250-power.sh", "all"),
                "ram-install": ("sudo", "bc250-ram-split.sh", "install"),
                "compute-build": ("sudo", "bc250-40cu.sh", "prep"),
                "cec-setup": ("direct", "bc250-cec.sh", "setup"),
                "cec-repair": ("direct", "bc250-cec.sh", "repair"),
                "persistence-install": (
                    "sudo",
                    "bc250-update-persistence.sh",
                    "install",
                    "all",
                ),
                "aic-install": ("sudo", "aic8800/steamdeck-setup.sh", "install"),
                "audio-build": ("direct", "bc250-audio-fix/patch-driver.sh"),
                "mesh-setup": ("direct", "bc250-mesh-shader.sh", "setup"),
                "decky-install": ("direct", "decky-plugin/install.sh", "install"),
                "desktop-install": ("direct", "desktop-control/install.sh", "install"),
                "persistence-remove": (
                    "sudo",
                    "bc250-update-persistence.sh",
                    "remove",
                    "all",
                ),
            }
            for component in (
                "storage",
                "power",
                "ram",
                "compute",
                "cec",
                "aic",
                "audio",
                "mesh",
                "decky",
                "desktop",
            ):
                mappings[f"{component}-remove"] = (
                    "direct",
                    "bc250-maintenance.sh",
                    "uninstall",
                    component,
                    "--yes",
                )

            for operation, (mode, relative, *arguments) in mappings.items():
                with self.subTest(operation=operation):
                    call_log.unlink(missing_ok=True)
                    subprocess.run(
                        ["bash", str(toolkit), "action", operation],
                        check=True,
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    if mode == "sudo":
                        expected = ["sudo", "bash", str(root / relative), *arguments]
                    else:
                        expected = [relative, *arguments]
                    self.assertEqual(
                        call_log.read_text(encoding="utf-8").strip(),
                        "|".join(expected) + "|machine=1",
                    )

    def test_action_rejects_unknown_ids_and_wrong_argument_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, call_log, env = self.make_action_environment(Path(directory))
            for arguments in (
                ("action",),
                ("action", "power-install", "unexpected"),
                ("action", "bc250-power.sh"),
            ):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(
                        ["bash", str(toolkit), *arguments],
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(call_log.exists())

    def test_inventory_json_uses_maintenance_states_without_terminal_output(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, env = self.make_inventory_environment(Path(directory))
            result = subprocess.run(
                ["bash", str(toolkit), "inventory-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            inventory = json.loads(result.stdout)
            self.assertEqual(inventory["schemaVersion"], 1)
            self.assertEqual(
                [component["id"] for component in inventory["components"]],
                [
                    "trainer",
                    "desktop",
                    "decky",
                    "cec",
                    "power",
                    "ram",
                    "compute",
                    "mesh",
                    "audio",
                    "aic",
                    "storage",
                ],
            )
            states = {
                component["id"]: component["state"]
                for component in inventory["components"]
            }
            self.assertEqual(states["power"], "installed")
            self.assertEqual(states["cec"], "partial")
            self.assertEqual(states["decky"], "not-installed")
            self.assertTrue(
                set(states.values())
                <= {"installed", "partial", "data-preserved", "not-installed"}
            )
            self.assertNotIn("\x1b", result.stdout)
            self.assertEqual(result.stderr, "")

    def test_inventory_json_rejects_extra_arguments(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT), "inventory-json", "unexpected"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)

    def test_script_parses(self):
        subprocess.run(
            ["bash", "-n", str(TOOLKIT), str(ROOT / "bc250-maintenance.sh")],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
