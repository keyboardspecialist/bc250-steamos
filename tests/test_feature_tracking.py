import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECORDER = ROOT / "backend/bc250_control/feature_state.py"


class AutomaticFeatureTrackingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {**os.environ, "XDG_STATE_HOME": str(self.root / "state"),
                    "CLEANUP_LOG": str(self.root / "cleanup")}
        self.env.pop("BC250_FEATURE_CHILD", None)
        self.env.pop("BC250_FEATURE_RECORDING", None)
        self.journal = self.root / "state/bc250-toolkit/features.json"
        self.helper = self.root / "component.sh"
        self.helper.write_text(
            '#!/bin/bash\nset -euo pipefail\n'
            f'source "{ROOT}/scripts/feature-tracking.sh" power help "$@"\n'
            'trap \'echo cleanup >> "$CLEANUP_LOG"\' EXIT\n'
            'case "${1:-help}" in\n'
            'set|update|install|uninstall) : ;;\n'
            'exec-update) exec /bin/true ;;\n'
            'fail) exit 7 ;;\n'
            'menu) bc250_feature_note_command 0 cmd_set ;;\n'
            'status|help|cpu-unlock) echo readonly ;;\n'
            '*) exit 2 ;;\nesac\n'
        )

    def run_helper(self, *args):
        return subprocess.run(["bash", str(self.helper), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_install_update_and_change_refresh_the_same_private_journal(self):
        for revision, action in enumerate(("install", "update", "set"), 1):
            result = self.run_helper(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(self.journal.read_text())
            self.assertEqual(value["revision"], revision)
            self.assertEqual(value["features"]["power"]["lastAction"], action)
            self.assertEqual(value["features"]["power"]["lastResult"], "success")
        self.assertEqual(self.journal.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "cleanup").read_text().splitlines(), ["cleanup"] * 3)

    def test_read_only_and_dry_run_commands_do_not_create_a_journal(self):
        for args in (("status",), ("help",), ("cpu-unlock", "status"), ("set", "--dry-run")):
            result = self.run_helper(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.journal.exists())

    def test_exec_and_menu_changes_are_recorded_without_replacing_cleanup_traps(self):
        for action in ("exec-update", "menu"):
            result = self.run_helper(action)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.journal.read_text())["features"]["power"]["lastAction"], "set")
        self.assertEqual((self.root / "cleanup").read_text().splitlines(), ["cleanup"])

    def test_failure_keeps_exit_status_and_never_seeds_an_installed_feature(self):
        result = self.run_helper("fail")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(json.loads(self.journal.read_text())["features"], {})
        self.run_helper("install")
        self.run_helper("fail")
        self.assertEqual(json.loads(self.journal.read_text())["features"]["power"]["lastResult"], "failed")

    def test_full_uninstall_forgets_repair_intent(self):
        self.run_helper("install")
        result = self.run_helper("uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(self.journal.read_text())
        self.assertEqual(value["features"], {})
        self.assertEqual(value["lastMutation"]["action"], "uninstall")

    def test_tracking_failure_does_not_turn_a_successful_change_into_failure(self):
        self.journal.parent.mkdir(parents=True, mode=0o700)
        self.journal.write_text("broken journal")
        result = self.run_helper("set")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Could not save", result.stderr)
        self.assertEqual(self.journal.read_text(), "broken journal")

    def test_concurrent_components_merge_without_lost_updates(self):
        components = ["power", "ram", "fan", "audio", "mesh", "fsr4", "optiscaler", "wifi-backend"]

        def record(component):
            return subprocess.run(["python3", "-I", str(RECORDER), component, "install", "success"],
                                  env=self.env, capture_output=True, text=True, timeout=15)

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(record, components))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(self.journal.read_text())
        self.assertEqual(set(value["features"]), set(components))
        self.assertEqual(value["revision"], len(components))


if __name__ == "__main__":
    unittest.main()
