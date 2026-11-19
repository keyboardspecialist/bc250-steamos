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

    def test_unreadable_grub_plan_does_not_request_privileges(self):
        desired = record(ram={"toolUsed": True, "ttmPages": 3670016})
        with patch.object(recovery, "json_probe", return_value=ram_status()), \
                patch.object(recovery, "probe", return_value=subprocess.CompletedProcess([], 2)) as probe:
            state, reason = recovery.health("ram", desired, self.states)
        self.assertEqual(state, "verify")
        self.assertIn("Administrator access", reason)
        probe.assert_called_once_with("ram", "ttm-verify")

    def test_confirmed_repair_verifies_root_only_grub_without_rewriting(self):
        self.write_features({"ram": record(ram={"toolUsed": True, "ttmPages": 3670016})})
        for reboot in (False, True):
            with self.subTest(reboot=reboot), \
                    patch.object(recovery, "inventory", return_value=self.states), \
                    patch.object(recovery, "json_probe", return_value=ram_status(rebootRequired=reboot)), \
                    patch.object(recovery, "probe", side_effect=[
                        subprocess.CompletedProcess([], 2),  # Plan: no sudo.
                        subprocess.CompletedProcess([], 2),  # Confirmed recheck.
                        subprocess.CompletedProcess([], 0),  # Read-only sudo check.
                    ]) as probe, \
                    patch.object(recovery, "repair_commands") as commands, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(recovery.repair("ram", True), 0)
            commands.assert_not_called()
            self.assertEqual(probe.call_args_list[-1].kwargs, {"privileged": True})
            self.assertIn("ram: reboot:" if reboot else "ram: healthy:", output.getvalue())

    def test_repaired_ram_can_verify_root_only_grub_with_reboot_pending(self):
        self.write_features({"ram": record(ram={"toolUsed": True, "ttmPages": 3670016})})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "json_probe", side_effect=[
                    ram_status(protected=False),  # Plan.
                    ram_status(protected=False),  # Confirmed recheck.
                    ram_status(rebootRequired=True),  # Post-repair.
                ]), \
                patch.object(recovery, "probe", side_effect=[
                    subprocess.CompletedProcess([], 2), subprocess.CompletedProcess([], 0),
                ]), \
                patch.object(recovery, "repair_commands", return_value=[["repair-ram"]]), \
                patch.object(recovery.subprocess, "run") as run, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(recovery.repair("ram", True), 0)
        run.assert_called_once_with(["repair-ram"], check=True)
        self.assertIn("ram: reboot:", output.getvalue())

    def test_privileged_grub_verification_does_not_hide_actual_damage(self):
        desired = record(ram={"toolUsed": True, "ttmPages": 3670016})
        with patch.object(recovery, "json_probe", return_value=ram_status(rebootRequired=True)), \
                patch.object(recovery, "probe", side_effect=[
                    subprocess.CompletedProcess([], 2), subprocess.CompletedProcess([], 1),
                ]):
            self.assertEqual(recovery.health("ram", desired, self.states, allow_privileged=True)[0], "repair")

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

    def test_menu_status_separates_tracking_from_all_health_states(self):
        self.write_features({component: record() for component in (
            "fan", "power", "audio", "ram", "storage", "aic",
        )})
        before = recovery.state_path().read_bytes()
        self.states["trainer"] = "installed"
        health_states = dict(fan="repair", power="manual", audio="reboot",
                             ram="verify", storage="healthy", aic="blocked")
        with patch.object(recovery, "inventory", return_value=self.states) as inventory, \
                patch.object(recovery, "health", side_effect=lambda component, *args:
                    (health_states[component], "details")) as health, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            recovery.menu_status()
        self.assertEqual(output.getvalue(), "6 tracked; 1 untracked|"
                         "1 repair; 1 blocked; 1 reboot; 1 verify; 1 healthy; 1 manual|error\n")
        inventory.assert_called_once_with()
        self.assertTrue(all(not call.kwargs for call in health.call_args_list))
        self.assertEqual(recovery.state_path().read_bytes(), before)

    def test_menu_status_without_tracking_does_not_claim_health_or_create_state(self):
        self.states.update(fan="installed", ram="partial")
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health") as health, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            recovery.menu_status()
        self.assertEqual(output.getvalue(), "not tracked; 2 untracked|nothing tracked|neutral\n")
        health.assert_not_called()
        self.assertFalse(recovery.state_path().parent.exists())

    def test_menu_status_inventory_failure_preserves_tracking_count(self):
        self.write_features({"power": record()})
        with patch.object(recovery, "inventory", side_effect=ValueError("Incomplete inventory")), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            recovery.menu_status()
        self.assertEqual(output.getvalue(), "1 tracked; inventory unavailable|health unavailable|error\n")

    def test_menu_status_health_levels_never_call_manual_or_unknown_healthy(self):
        self.write_features({"power": record()})
        for state, level in (("healthy", "healthy"), ("manual", "neutral"),
                             ("verify", "warning"), ("reboot", "warning"),
                             ("blocked", "error"), ("repair", "error")):
            with self.subTest(state=state), \
                    patch.object(recovery, "inventory", return_value=self.states), \
                    patch.object(recovery, "health", return_value=(state, "details")), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                recovery.menu_status()
            self.assertEqual(output.getvalue(), f"1 tracked|1 {state}|{level}\n")

    def test_repair_checks_results_and_continues_independent_failures(self):
        self.write_features({"fan": record(), "aic": record()})
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command == ["fan"]:
                raise subprocess.CalledProcessError(9, command)

        health = {"aic": 0}

        def check(component, *args, **kwargs):
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

    def test_manual_features_do_not_fail_successful_supported_repairs(self):
        self.write_features({component: record() for component in (
            "storage", "audio", "fan", "power", "mesh",
        )})
        before = recovery.state_path().read_bytes()
        fan_checks = 0

        def check(component, *args, **kwargs):
            nonlocal fan_checks
            if component == "fan":
                fan_checks += 1
                return ("healthy", "verified") if fan_checks == 3 else ("repair", "missing")
            if component == "storage":
                return "healthy", "verified"
            if component == "audio":
                return "reboot", "Reboot, do not rebuild."
            return "manual", "Review component status."

        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", side_effect=check), \
                patch.object(recovery, "repair_commands", return_value=[["fan"]]) as commands, \
                patch.object(recovery.subprocess, "run") as run, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(recovery.repair("all", True), 0)
        commands.assert_called_once_with("fan", record())
        run.assert_called_once_with(["fan"], check=True)
        self.assertIn("Skipped 2 manual-only feature(s)", output.getvalue())
        self.assertIn("Supported repair checks completed successfully.", output.getvalue())
        self.assertEqual(recovery.state_path().read_bytes(), before)

    def test_manual_only_repair_is_a_successful_noop(self):
        self.write_features({"power": record()})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "repair_commands") as commands, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(recovery.repair("power", True), 0)
        commands.assert_not_called()
        self.assertIn("Skipped 1 manual-only feature(s)", output.getvalue())

    def test_blocked_component_still_fails_with_manual_features(self):
        self.write_features({"ram": record(), "power": record()})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", side_effect=[
                    ("blocked", "Unverified RAM state"), ("manual", "Review tuning"),
                ]), \
                patch.object(recovery, "repair_commands") as commands, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(recovery.repair("all", True), 1)
        commands.assert_not_called()
        self.assertNotIn("completed successfully", output.getvalue())

    def test_unknown_storage_still_blocks_dependent_repairs(self):
        self.write_features({"storage": record(), "fan": record()})
        for state in ("blocked", "manual"):
            with self.subTest(state=state), \
                    patch.object(recovery, "inventory", return_value=self.states), \
                    patch.object(recovery, "health", side_effect=[
                        (state, "Unknown storage health"), ("repair", "Missing fan driver"),
                    ]), \
                    patch.object(recovery, "repair_commands") as commands, \
                    contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(recovery.repair("all", True), 1)
            commands.assert_not_called()
            self.assertIn("no dependent repairs were attempted", errors.getvalue())

    def test_post_repair_failure_still_fails_with_manual_features(self):
        self.write_features({"fan": record(), "power": record()})
        with patch.object(recovery, "inventory", return_value=self.states), \
                patch.object(recovery, "health", side_effect=[
                    ("repair", "Missing"), ("manual", "Review tuning"),
                    ("repair", "Missing"), ("repair", "Still missing"),
                ]), \
                patch.object(recovery, "repair_commands", return_value=[["fan"]]), \
                patch.object(recovery.subprocess, "run"), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(recovery.repair("all", True), 1)
        self.assertIn("Post-repair health checks did not pass", errors.getvalue())
        self.assertNotIn("completed successfully", output.getvalue())

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
