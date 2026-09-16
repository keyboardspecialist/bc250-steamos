import importlib.util
import json
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
from menu_targets import MANIFEST_PATH, load_targets  # noqa: E402


ANALYZER_SPEC = importlib.util.spec_from_file_location("menu_analyzer", ANALYZER)
assert ANALYZER_SPEC is not None and ANALYZER_SPEC.loader is not None
MENU_ANALYZER = importlib.util.module_from_spec(ANALYZER_SPEC)
ANALYZER_SPEC.loader.exec_module(MENU_ANALYZER)


class MenuGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.graph = parse(GRAPH_PATH)
        cls.targets = load_targets()
        cls.graphs = {target.name: parse(target.graph_path) for target in cls.targets}

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
        for target in self.targets:
            graph = self.graphs[target.name]
            source = target.bash_path.read_text(encoding="utf-8")
            adapter = source[
                source.index(f"{target.symbol}_activate() {{") : source.index(
                    target.begin
                )
            ]
            for node in graph.nodes.values():
                if node.kind != "menu":
                    with self.subTest(target=target.name, node=node.id):
                        self.assertRegex(
                            adapter,
                            rf"(?m)^\s*{re.escape(node.id)}\)",
                        )

    def test_generated_bash_is_current_and_valid(self):
        subprocess.run(
            [sys.executable, str(GENERATOR), "--check"], cwd=ROOT, check=True
        )
        for target in self.targets:
            subprocess.run(["bash", "-n", str(target.bash_path)], check=True)
            source = target.bash_path.read_text(encoding="utf-8")
            self.assertIn(
                f'{target.symbol}_activate "$target" "${{badges[$MENU_CHOICE]}}"',
                source,
            )
            self.assertIn('"$title" == *[[:cntrl:]]*', source)

    def test_manifest_entries_reference_menus_and_expose_each_root(self):
        for target in self.targets:
            graph = self.graphs[target.name]
            entries = dict(target.entries)
            with self.subTest(target=target.name):
                self.assertEqual(graph.root.id, entries.get("root"))
                self.assertTrue(
                    all(graph.nodes[node].kind == "menu" for node in entries.values())
                )

    def test_manifest_cannot_omit_a_supported_target(self):
        payload = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        payload["targets"] = payload["targets"][1:]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "targets.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(MenuGraphError, "target set is incomplete"):
                load_targets(path)

    def test_analyzer_enforces_depth_budget(self):
        result = subprocess.run(
            [sys.executable, str(ANALYZER), "--check", "--depth-budget", "3"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("Selectable nodes: 51", result.stdout)

    def test_documented_aggregate_metrics_are_current(self):
        graphs = self.graphs.values()
        self.assertEqual(
            (40, 211, 227, 8),
            (
                sum(node.kind == "menu" for graph in graphs for node in graph.nodes.values()),
                sum(
                    len({edge.target for edge in graph.edges if not edge.dependency})
                    for graph in self.graphs.values()
                ),
                sum(
                    not edge.dependency
                    for graph in self.graphs.values()
                    for edge in graph.edges
                ),
                sum(
                    edge.dependency
                    for graph in self.graphs.values()
                    for edge in graph.edges
                ),
            ),
        )

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

    def test_menu_title_directive_preserves_contextual_screen_heading(self):
        source = """%% menu-flow-v1
flowchart TD
%% menu-title menu__root "Contextual root heading"
menu__root["Short root label<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__root --> action__done
"""
        graph = self.parse_source(source)
        self.assertEqual("Short root label", graph.root.title)
        self.assertEqual("Contextual root heading", graph.display_title(graph.root.id))

    def test_parser_rejects_malformed_menu_title_directives(self):
        source = """%% menu-flow-v1
flowchart TD
%% menu-title
menu__root["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__root --> action__done
"""
        with self.assertRaisesRegex(MenuGraphError, "malformed menu-title"):
            self.parse_source(source)

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
        self.assertTrue(MENU_ANALYZER.graph_violates_policy(graph, 3))
        report = MENU_ANALYZER.report(graph, 3)
        self.assertIn("Deepest shortest route: 4 links", report)
        self.assertIn("Beyond depth budget (3 links): 1", report)

    def test_entry_routes_are_included_in_detour_analysis(self):
        source = """%% menu-flow-v1
flowchart TD
menu__root["Root<br/>Root hint."]:::root
action__done["Done<br/>Done hint."]:::read_only
menu__direct["Direct<br/>Direct hint."]:::entry
menu__first["First<br/>First hint."]:::menu
action__direct["Direct Action<br/>Direct action hint."]:::read_only
menu__root --> action__done
menu__direct --> menu__first
menu__direct --> action__direct
menu__first --> action__direct
"""
        graph = self.parse_source(source)
        self.assertTrue(MENU_ANALYZER.graph_violates_policy(graph, 3))
        self.assertIn(
            "Detour links (a shorter supported-entry route exists): 1",
            MENU_ANALYZER.report(graph, 3),
        )


if __name__ == "__main__":
    unittest.main()
