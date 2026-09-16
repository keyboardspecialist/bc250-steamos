import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
GRAPH_PATH = ROOT / "menus/toolkit.mmd"
GENERATOR = SCRIPTS / "generate-menus.py"
ANALYZER = SCRIPTS / "analyze-menu-graph.py"
sys.path.insert(0, str(SCRIPTS))

from menu_graph import MenuGraphError, parse, reachable  # noqa: E402


GENERATOR_SPEC = importlib.util.spec_from_file_location("menu_generator", GENERATOR)
assert GENERATOR_SPEC is not None and GENERATOR_SPEC.loader is not None
MENU_GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(MENU_GENERATOR)
ANALYZER_SPEC = importlib.util.spec_from_file_location("menu_analyzer", ANALYZER)
assert ANALYZER_SPEC is not None and ANALYZER_SPEC.loader is not None
MENU_ANALYZER = importlib.util.module_from_spec(ANALYZER_SPEC)
ANALYZER_SPEC.loader.exec_module(MENU_ANALYZER)


class MenuGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.graph = parse(GRAPH_PATH)

    @staticmethod
    def parse_source(source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.mmd"
            path.write_text(source, encoding="utf-8")
            return parse(path)

    def test_root_uses_the_new_domain_taxonomy_in_order(self):
        self.assertEqual(
            [
                "Auto Base Toolkit Installation",
                "Manual Guided Setup",
                "Core System",
                "Power & Thermals",
                "Graphics Stack",
                "Hardware Unlocks",
                "Devices & Connectivity",
                "Control Interfaces",
                "Maintenance & Recovery",
                "System Health",
            ],
            [node.title for node in self.graph.choices(self.graph.root.id)],
        )

    def test_guided_setup_links_to_tasks_not_sibling_categories(self):
        choices = self.graph.choices("menu__cmd_guided_setup_menu")
        self.assertTrue(choices)
        self.assertTrue(all(node.kind in {"action", "child"} for node in choices))
        self.assertIn("child__power_foundation", {node.id for node in choices})
        self.assertIn("action__graphics_setup", {node.id for node in choices})

    def test_graph_is_shallow_and_legacy_entries_are_explicit(self):
        depths = reachable(self.graph)
        self.assertLessEqual(max(depths.values()), 3)
        self.assertNotIn("menu__cmd_drivers_menu", depths)
        self.assertEqual("entry", self.graph.nodes["menu__cmd_drivers_menu"].style)
        self.assertNotIn("menu__cmd_storage_updates_menu", depths)

    def test_dependencies_are_not_navigation(self):
        dependencies = {
            (edge.source, edge.target)
            for edge in self.graph.edges
            if edge.dependency
        }
        self.assertIn(("action__graphics_setup", "action__amdgpu"), dependencies)
        self.assertIn(("action__proton_install", "action__graphics_setup"), dependencies)
        self.assertEqual([], self.graph.navigation()["action__graphics_setup"])

    def test_every_terminal_node_has_a_fixed_bash_adapter(self):
        toolkit = (ROOT / "bc250-toolkit.sh").read_text(encoding="utf-8")
        adapter = toolkit[
            toolkit.index("menu_graph_activate() {") : toolkit.index(
                "# BEGIN GENERATED TOOLKIT MENUS"
            )
        ]
        for node in self.graph.nodes.values():
            if node.kind != "menu":
                with self.subTest(node=node.id):
                    self.assertRegex(
                        adapter,
                        rf"(?m)^\s*{re.escape(node.id)}\)",
                    )

    def test_generated_bash_is_current_and_valid(self):
        subprocess.run(
            [sys.executable, str(GENERATOR), "--check"], cwd=ROOT, check=True
        )
        subprocess.run(["bash", "-n", str(ROOT / "bc250-toolkit.sh")], check=True)

    def test_analyzer_enforces_depth_budget(self):
        result = subprocess.run(
            [sys.executable, str(ANALYZER), "--check", "--depth-budget", "3"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("Selectable nodes: 51", result.stdout)

    def test_parser_rejects_navigation_cycles(self):
        source = """%% menu-flow-v1
flowchart TD
menu__root[\"Root<br/>Root hint.\"]:::root
menu__child[\"Child<br/>Child hint.\"]:::menu
action__done[\"Done<br/>Done hint.\"]:::read_only
menu__root --> menu__child
menu__child --> menu__root
menu__child --> action__done
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.mmd"
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(MenuGraphError, "navigation into the root|cycle"):
                parse(path)

    def test_parser_rejects_duplicate_navigation_edges(self):
        source = """%% menu-flow-v1
flowchart TD
menu__root["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__root --> action__done
menu__root --> action__done
"""
        with self.assertRaisesRegex(MenuGraphError, "duplicate navigation edge"):
            self.parse_source(source)

    def test_entry_menu_may_own_entry_only_actions(self):
        source = """%% menu-flow-v1
flowchart TD
menu__root["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__direct["Direct<br/>Direct hint."]:::entry
action__direct["Direct Action<br/>Direct action hint."]:::read_only
menu__root --> action__done
menu__direct --> action__direct
"""
        graph = self.parse_source(source)
        self.assertNotIn("action__direct", reachable(graph))
        self.assertEqual(["action__direct"], [node.id for node in graph.choices("menu__direct")])

    def test_parser_rejects_decoded_menu_delimiters_and_controls(self):
        template = """%% menu-flow-v1
flowchart TD
menu__root["Root<br/>Root hint."]:::root
action__done["{title}<br/>Done hint."]:::read_only
menu__root --> action__done
"""
        for encoded in ("Bad&#124;Title", "Bad&#10;Title"):
            with self.subTest(encoded=encoded):
                with self.assertRaisesRegex(MenuGraphError, "menu delimiters or control"):
                    self.parse_source(template.format(title=encoded))

    def test_parser_rejects_malformed_class_definitions(self):
        source = """%% menu-flow-v1
flowchart TD
menu__root["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__root --> action__done
classDef this is not valid mermaid !!!
"""
        with self.assertRaisesRegex(MenuGraphError, "unsupported classDef"):
            self.parse_source(source)

    def test_generator_rejects_wrapper_function_collisions(self):
        source = """%% menu-flow-v1
flowchart TD
menu__cmd_custom_menu["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__cmd_custom_menu --> action__done
"""
        graph = self.parse_source(source)
        with self.assertRaisesRegex(MenuGraphError, "collides with existing Bash"):
            MENU_GENERATOR.validate_wrapper_names(
                graph, "    cmd_custom_menu() {\n        :\n    }\n"
            )

    def test_generator_rejects_non_command_wrapper_names(self):
        source = """%% menu-flow-v1
flowchart TD
menu__printf["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__printf --> action__done
"""
        graph = self.parse_source(source)
        with self.assertRaisesRegex(MenuGraphError, "must use cmd_ names"):
            MENU_GENERATOR.validate_wrapper_names(graph, "")

    def test_generator_excludes_the_replaceable_legacy_menu_region(self):
        source = """%% menu-flow-v1
flowchart TD
menu__cmd_custom_menu["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__cmd_custom_menu --> action__done
"""
        legacy_toolkit = """cmd_guided_setup_menu() {
    :
}
cmd_custom_menu() {
    :
}
cmd_help() {
    :
}
"""
        graph = self.parse_source(source)
        MENU_GENERATOR.validate_wrapper_names(graph, legacy_toolkit)

    def test_entry_routes_are_included_in_depth_analysis(self):
        source = """%% menu-flow-v1
flowchart TD
menu__cmd_menu["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__cmd_direct_menu["Direct<br/>Direct hint."]:::entry
menu__cmd_first_menu["First<br/>First hint."]:::menu
menu__cmd_second_menu["Second<br/>Second hint."]:::menu
menu__cmd_third_menu["Third<br/>Third hint."]:::menu
action__direct["Direct Action<br/>Direct action hint."]:::read_only
menu__cmd_menu --> action__done
menu__cmd_direct_menu --> menu__cmd_first_menu
menu__cmd_first_menu --> menu__cmd_second_menu
menu__cmd_second_menu --> menu__cmd_third_menu
menu__cmd_third_menu --> action__direct
"""
        graph = self.parse_source(source)
        entry_paths = {
            start: depths
            for start, depths, _ in MENU_ANALYZER.supported_entry_paths(graph)
        }
        self.assertEqual(4, max(entry_paths["menu__cmd_direct_menu"].values()))
        report = MENU_ANALYZER.report(graph, 3)
        self.assertIn("Deepest shortest route: 4 links", report)
        self.assertIn("Beyond depth budget (3 links): 1", report)


if __name__ == "__main__":
    unittest.main()
