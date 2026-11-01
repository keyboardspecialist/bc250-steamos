import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("feature_recovery", ROOT / "scripts/feature-recovery.py")
recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recovery)


def record(**extra):
    return {"firstSeen": "2026-11-01", "lastSeen": "2026-11-01", **extra}


def ram_status(**extra):
    return {"toolState": "verified", "ttmState": "configured",
            "ttmConfiguredPages": 3670016, "ttmLivePages": 3670016,
            "rebootRequired": False, "protected": True, **extra}


class FeatureRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"XDG_STATE_HOME": str(self.directory / "state")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.states = {component: "not-installed" for component in recovery.COMPONENTS}

    def write_features(self, features):
        with recovery.journal(write=True) as value:
            value["features"] = features

    def test_read_only_journal_does_not_create_state(self):
        with recovery.journal() as value:
            self.assertEqual(value["features"], {})
        self.assertFalse(recovery.state_path().parent.exists())

    def test_incomplete_ram_status_is_not_treated_as_healthy(self):
        with patch.object(recovery, "probe", return_value=subprocess.CompletedProcess([], 0, "{}")):
            with self.assertRaisesRegex(ValueError, "invalid status"):
                recovery.json_probe("ram")

    def test_track_discovers_existing_and_preserves_missing_features(self):
        self.states.update(ram="installed", fan="partial")
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "json_probe", return_value=ram_status()), \
                contextlib.redirect_stdout(io.StringIO()):
            recovery.track()
            self.states.update(ram="not-installed", fan="not-installed")
            recovery.track()
        with recovery.journal() as value:
            self.assertEqual(set(value["features"]), {"ram", "fan"})
            self.assertEqual(value["features"]["ram"]["ram"], {"toolUsed": True, "ttmPages": 3670016})
        self.assertEqual(recovery.state_path().stat().st_mode & 0o777, 0o600)

    def test_explicit_ttm_removal_clears_saved_limit_on_tracking(self):
        self.write_features({"ram": record(ram={"toolUsed": True, "ttmPages": 3670016})})
        self.states["ram"] = "installed"
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "json_probe", return_value=ram_status(
                    ttmState="default", ttmConfiguredPages=None, ttmOverrideRemoved=True)), \
                contextlib.redirect_stdout(io.StringIO()):
            recovery.track()
        with recovery.journal() as value:
            self.assertIsNone(value["features"]["ram"]["ram"]["ttmPages"])

    def test_inventory_scan_does_not_overwrite_a_newer_configuration_change(self):
        self.write_features({"ram": record(ram={"toolUsed": True, "ttmPages": 3014656})})
        self.states["ram"] = "installed"

        def inventory_during_change():
            from feature_state import record_event
            record_event("ram", "ttm-set", ram=ram_status())
            return self.states

        with patch.object(recovery, "inventory", side_effect=inventory_during_change), \
                patch.object(recovery, "json_probe", return_value=ram_status(ttmConfiguredPages=3014656)), \
                contextlib.redirect_stdout(io.StringIO()):
            recovery.track()
        with recovery.journal() as value:
            self.assertEqual(value["features"]["ram"]["ram"]["ttmPages"], 3670016)

    def test_persistent_ttm_request_can_bootstrap_tracking_after_update_loss(self):
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "json_probe", return_value=ram_status(
                    toolState="not-installed", ttmState="default", ttmConfiguredPages=None,
                    ttmLastRequestedPages=3670016)), contextlib.redirect_stdout(io.StringIO()):
            recovery.track()
        with recovery.journal() as value:
            self.assertEqual(value["features"]["ram"]["ram"], {"toolUsed": False, "ttmPages": 3670016})

    def test_malformed_or_injectable_journal_is_rejected(self):
        for features in (
            {"fan; reboot": record()},
            {"fan": record(command="sudo reboot")},
            {"ram": record(ram={"toolUsed": True, "ttmPages": "3670016; reboot"})},
            {"ram": record(ram={"toolUsed": True, "ttmPages": 3670017})},
            {"ram": record(ram={"toolUsed": True, "ttmPages": True})},
        ):
            with self.subTest(features=features), self.assertRaises(ValueError):
                recovery.validate_state({"schemaVersion": 1, "features": features})

    def test_symlinked_journal_and_directory_are_rejected(self):
        target = self.directory / "target"
        target.write_text("untouched")
        path = recovery.state_path()
        path.parent.mkdir(parents=True, mode=0o700)
        path.symlink_to(target)
        with self.assertRaises(OSError):
            with recovery.journal(write=True):
                pass
        self.assertEqual(target.read_text(), "untouched")
        path.unlink()
        (path.parent / ".lock").unlink()
        path.parent.rmdir()
        path.parent.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            with recovery.journal(write=True):
                pass

    def test_foreign_or_changed_ram_is_not_overwritten(self):
        desired = record(ram={"toolUsed": True, "ttmPages": 3670016})
        for status, expected in (
            (ram_status(ttmState="foreign"), "blocked"),
            (ram_status(toolState="invalid"), "blocked"),
            (ram_status(ttmConfiguredPages=3014656), "manual"),
            (ram_status(ttmLastRequestedPages=3014656), "manual"),
            (ram_status(ttmConfiguredPages=None, ttmOverrideRemoved=True), "manual"),
        ):
            with self.subTest(status=status), patch.object(recovery, "json_probe", return_value=status):
                self.assertEqual(recovery.health("ram", desired, self.states)[0], expected)

    def test_reboot_pending_is_not_damage(self):
        desired = record(ram={"toolUsed": True, "ttmPages": 3670016})
        with patch.object(recovery, "json_probe", return_value=ram_status(rebootRequired=True)), \
                patch.object(recovery, "probe", return_value=subprocess.CompletedProcess([], 0)):
            self.assertEqual(recovery.health("ram", desired, self.states)[0], "reboot")
        with patch.object(recovery, "json_probe", return_value={"state": "reboot-required"}):
            self.assertEqual(recovery.health("audio", record(), self.states)[0], "reboot")

    def test_ram_repair_uses_recorded_limit_and_never_cmos(self):
        desired = record(ram={"toolUsed": False, "ttmPages": 3014656})
        with patch.object(recovery, "json_probe", return_value=ram_status(toolState="not-installed")):
            commands = recovery.repair_commands("ram", desired)
        self.assertEqual(commands, [["sudo", "bash", str(ROOT / "bc250-ram-split.sh"),
                                     "ttm-set", "3014656", "--yes"]])

    def test_plan_targets_only_tracked_components_and_is_read_only(self):
        self.write_features({"fan": record(), "power": record()})
        before = recovery.state_path().read_bytes()
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "probe", return_value=subprocess.CompletedProcess([], 1)):
            rows = recovery.plan({"fan": record(), "power": record()}, "all")
        self.assertEqual([(component, state) for component, state, _ in rows],
                         [("fan", "repair"), ("power", "manual")])
        self.assertEqual(recovery.state_path().read_bytes(), before)

    def test_repair_checks_results_and_continues_independent_failures(self):
        self.write_features({"fan": record(), "aic": record()})
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command == ["fan"]:
                raise subprocess.CalledProcessError(9, command)

        health = {"aic": 0}

        def check(component, *args):
            if component == "aic":
                health[component] += 1
                if health[component] == 3:
                    return "healthy", "verified"
            return "repair", "missing"

        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", side_effect=check), \
                patch.object(recovery, "repair_commands", side_effect=lambda component, _: [[component]]), \
                patch.object(recovery.subprocess, "run", side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(recovery.repair("all", True), 1)
        self.assertEqual(calls, [["fan"], ["aic"]])
        with recovery.journal() as value:
            self.assertEqual(set(value["features"]), {"fan", "aic"})

    def test_storage_failure_blocks_dependents(self):
        self.write_features({"storage": record(), "fan": record()})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", return_value=("repair", "missing")), \
                patch.object(recovery, "repair_commands", return_value=[["storage"]]), \
                patch.object(recovery.subprocess, "run", side_effect=subprocess.CalledProcessError(9, ["storage"])) as run, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(recovery.repair("all", True), 1)
        run.assert_called_once_with(["storage"], check=True)

    def test_repair_allows_child_hooks_to_update_the_same_journal_without_deadlock(self):
        self.write_features({"fan": record()})
        run = subprocess.run

        def helper_with_tracking(command, **kwargs):
            return run([sys.executable, "-I", str(ROOT / "backend/bc250_control/feature_state.py"),
                        "fan", "install", "success"], check=True, timeout=5,
                       capture_output=True, text=True)

        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", side_effect=[("repair", "missing"),
                    ("repair", "missing"), ("healthy", "verified")]), \
                patch.object(recovery, "repair_commands", return_value=[["fan"]]), \
                patch.object(recovery.subprocess, "run", side_effect=helper_with_tracking), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(recovery.repair("all", True), 0)
        with recovery.journal() as value:
            self.assertEqual(value["features"]["fan"]["lastAction"], "install")

    def test_noninteractive_repair_requires_confirmation_and_does_not_mutate(self):
        self.write_features({"fan": record()})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", return_value=("repair", "missing")), \
                patch.object(recovery, "repair_commands") as commands, \
                patch.object(recovery.sys.stdin, "isatty", return_value=False), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "use --yes"):
                recovery.repair("all", False)
        commands.assert_not_called()

    def test_all_frontend_limits_accept_14_gib(self):
        files = ["backend/bc250_control/backend.py",
                 "desktop-control/service/bc250_control_service/control.py",
                 "desktop-control/plasmoid/contents/ui/Backend.qml",
                 "desktop-control/plasmoid/contents/ui/tabs/RamTab.qml",
                 "trainer/src/Bc250Bridge.cpp", "trainer/qml/pages/RamPage.qml",
                 "decky-plugin/src/tabs/RamTab.tsx"]
        for relative in files:
            with self.subTest(path=relative):
                self.assertIn("3670016", (ROOT / relative).read_text())


if __name__ == "__main__":
    unittest.main()
