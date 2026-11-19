import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.menu_graph import parse


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/feature-menu.sh"


def function(source, name):
    return re.search(rf"(?m)^{name}\(\) \{{\n.*?^\}}", source, re.S).group()


class FeatureMenuTests(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(
                ["bash", "-euc",
                 'SCRIPT_DIR=$1; LOG=$2; C0=; CD=; CG=; CY=; CR=; '
                 'source "$SCRIPT_DIR/scripts/feature-menu.sh"; ' + body,
                 "_", str(ROOT), str(Path(directory) / "calls")],
                capture_output=True, text=True, check=True,
            )

    def test_shared_badges_use_one_snapshot_and_refresh_after_changes(self):
        result = self.run_shell(
            'python3() { echo probe >> "$LOG"; printf "%s\\n" "$SNAPSHOT"; }; '
            'SNAPSHOT="18 tracked|5 healthy; 1 verify; 12 manual|warning"; '
            'bc250_feature_menu_refresh; '
            'bc250_feature_menu_badge tracking; echo; '
            'bc250_feature_menu_badge health; echo; '
            '[[ $(wc -l < "$LOG") == 1 ]]; '
            'SNAPSHOT="19 tracked|6 healthy; 13 manual|neutral"; '
            'bc250_feature_menu_refresh; bc250_feature_menu_badge tracking; echo; '
            'bc250_feature_menu_badge health; echo; '
            '[[ $(wc -l < "$LOG") == 2 ]]'
        )
        self.assertEqual(result.stdout.splitlines(), [
            "[18 tracked]", "[5 healthy; 1 verify; 12 manual]",
            "[19 tracked]", "[6 healthy; 13 manual]",
        ])
        self.assertNotIn("installer", result.stdout)

    def test_failed_or_invalid_snapshot_clears_previous_healthy_status(self):
        for response in ("return 1", 'printf "bad\\nextra\\n"'):
            with self.subTest(response=response):
                result = self.run_shell(
                    'FEATURE_MENU_TRACKING="18 tracked"; FEATURE_MENU_HEALTH="18 healthy"; '
                    f'python3() {{ {response}; }}; '
                    'bc250_feature_menu_refresh; '
                    'bc250_feature_menu_badge tracking; echo; '
                    'bc250_feature_menu_badge health'
                )
                self.assertEqual(result.stdout.splitlines(), [
                    "[tracking unavailable]", "[health unavailable]",
                ])

    def test_both_menu_adapters_show_status_and_refresh_after_actions(self):
        for script, symbol, menu, tracking_node, repair_node, check_node in (
            ("bc250-toolkit.sh", "menu_graph", "menu__cmd_maintenance_menu",
             "action__track_features", "action__repair_known", "action__repair_plan"),
            ("bc250-maintenance.sh", "maintenance_menu_graph", "menu__root",
             "action__track", "action__repair", "action__repair_plan"),
        ):
            source = (ROOT / script).read_text()
            with self.subTest(script=script):
                result = self.run_shell(
                    "\n".join(function(source, f"{symbol}_{suffix}")
                              for suffix in ("prepare", "badge", "activate")) + "\n"
                    'require_script() { [[ -f "$1" ]]; }; '
                    'python3() { echo probe >> "$LOG"; echo "18 tracked|5 healthy; 1 reboot; 12 manual|warning"; }; '
                    'run_menu_action() { :; }; '
                    f'{symbol}_prepare {menu}; '
                    f'{symbol}_badge {tracking_node} install; echo; '
                    f'{symbol}_badge {repair_node} install; echo; '
                    f'{symbol}_badge {check_node} read_only; echo; '
                    '[[ $(wc -l < "$LOG") == 1 ]]; '
                    f'{symbol}_activate {tracking_node}; '
                    '[[ $(wc -l < "$LOG") == 2 ]]; '
                    f'{symbol}_activate {repair_node}; '
                    '[[ $(wc -l < "$LOG") == 3 ]]'
                )
                self.assertEqual(result.stdout.splitlines(), [
                    "[18 tracked]", "[5 healthy; 1 reboot; 12 manual]",
                    "[5 healthy; 1 reboot; 12 manual]",
                ])

    def test_menu_titles_describe_tracking_and_health_not_installation_or_assumed_damage(self):
        for graph_name, tracking_node, repair_node, check_node in (
            ("toolkit", "action__track_features", "action__repair_known", "action__repair_plan"),
            ("maintenance", "action__track", "action__repair", "action__repair_plan"),
        ):
            graph = parse(ROOT / f"menus/{graph_name}.mmd")
            self.assertEqual(graph.nodes[tracking_node].title.lower(), "refresh feature tracking")
            self.assertEqual(graph.nodes[repair_node].title.lower(), "repair tracked features")
            self.assertEqual(graph.nodes[check_node].title.lower(), "check tracked feature health")
            self.assertIn("automatically", graph.nodes[tracking_node].hint)
            self.assertIn("administrator verification", graph.nodes[check_node].hint)


if __name__ == "__main__":
    unittest.main()
