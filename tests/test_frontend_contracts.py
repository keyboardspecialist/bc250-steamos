"""Cross-frontend transport checks independent of Qt, KDE, and the Decky host."""

import ast
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def assignment(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            if any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
                return ast.literal_eval(node.value)
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name:
            return ast.literal_eval(node.value)
    raise AssertionError("Missing literal assignment: " + name)


class FrontendContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adapter = ast.parse((ROOT / "desktop-control/service/bc250_control_service/dbus_adapter.py").read_text())
        cls.methods = assignment(cls.adapter, "_METHODS")
        cls.control = ast.parse((ROOT / "desktop-control/service/bc250_control_service/control.py").read_text())
        cls.backend = ast.parse((ROOT / "backend/bc250_control/backend.py").read_text())

    def test_dbus_introspection_matches_dispatch_and_service_handlers(self):
        xml = ET.fromstring(assignment(self.adapter, "INTROSPECTION_XML"))
        interface = xml.find("interface[@name='io.github.keyboardspecialist.BC250Control1']")
        declared = {}
        for method in interface.findall("method"):
            declared[method.attrib["name"]] = tuple(
                "".join(arg.attrib["type"] for arg in method.findall("arg")
                        if arg.attrib.get("direction", "in") == direction)
                for direction in ("in", "out")
            )
        self.assertEqual(set(declared), set(self.methods))
        handlers = {node.name for node in ast.walk(self.control) if isinstance(node, ast.AsyncFunctionDef)}
        for name, (inputs, outputs, handler) in self.methods.items():
            with self.subTest(method=name):
                self.assertEqual(declared[name], (inputs, outputs))
                self.assertIn(handler, handlers)

    def test_decky_exports_resolve_to_plugin_handlers(self):
        source = (ROOT / "decky-plugin/src/api.ts").read_text()
        exports = re.findall(r'export const \w+ = callable[\s\S]*?\("([^"\n]+)"\);', source)
        self.assertGreater(len(exports), 20)
        plugin = ast.parse((ROOT / "decky-plugin/main.py").read_text())
        handlers = {node.name for node in ast.walk(plugin) if isinstance(node, ast.AsyncFunctionDef)}
        for method in exports:
            with self.subTest(method=method):
                self.assertIn(method, handlers)

    def test_plasma_command_allowlist_has_only_real_service_methods(self):
        source = (ROOT / "desktop-control/plasmoid/contents/ui/Backend.qml").read_text()
        match = re.search(r'Utils\.allowed\(method,\s*(\[[\s\S]*?\])\)', source)
        self.assertIsNotNone(match)
        methods = json.loads(match.group(1))
        self.assertEqual(len(methods), len(set(methods)))
        self.assertFalse(set(methods) - set(self.methods))
        self.assertIn("SetTemperatureTarget", methods)

    def test_trainer_fixed_dbus_calls_have_service_routes(self):
        source = (ROOT / "trainer/src/Bc250Bridge.cpp").read_text()
        methods = re.findall(
            r'(?:requestJson\(JsonRequest::\w+,\s*|startMutation\(\s*)QStringLiteral\("(\w+)"\)',
            source,
        )
        self.assertGreater(len(methods), 10)
        self.assertFalse(set(methods) - set(self.methods))

    def test_parity_extensions_are_present_on_all_live_clients(self):
        required = {
            "GpuVoltageAction": "gpu_voltage_action",
            "ResetGpuRamp": "reset_gpu_ramp",
            "GetCliCatalog": "get_cli_catalog",
            "OpenCliSection": "open_cli_section",
        }
        backend_methods = {node.name for node in ast.walk(self.backend) if isinstance(node, ast.AsyncFunctionDef)}
        decky = (ROOT / "decky-plugin/src/api.ts").read_text()
        plasma = (ROOT / "desktop-control/plasmoid/contents/ui/Backend.qml").read_text()
        trainer = (ROOT / "trainer/src/Bc250Bridge.cpp").read_text()
        for dbus, backend in required.items():
            with self.subTest(method=dbus):
                self.assertIn(dbus, self.methods)
                self.assertIn(backend, backend_methods)
                self.assertIn('"' + backend + '"', decky)
                self.assertIn('"' + dbus + '"', plasma)
                self.assertIn('"' + dbus + '"', trainer)

    def test_core_unlock_removal_uses_the_real_action_and_full_scope(self):
        trainer = (ROOT / "trainer/src/Bc250Bridge.cpp").read_text()
        cpu = (ROOT / "trainer/qml/pages/CpuPage.qml").read_text()
        backend = (ROOT / "backend/bc250_control/backend.py").read_text()
        self.assertNotIn("metrics-uninstall", trainer)
        self.assertNotIn("metrics-uninstall", cpu)
        self.assertIn('model: ["metrics-enable", "uninstall"]', cpu)
        self.assertIn('QStringLiteral("uninstall")', trainer)
        self.assertIn('"uninstall"', backend)
        self.assertIn("complete managed core-unlock and metrics integration", cpu)

    def test_recorded_cmos_requests_are_not_presented_as_current_readbacks(self):
        trainer = (ROOT / "trainer/qml/pages/RamPage.qml").read_text()
        plasma = (ROOT / "desktop-control/plasmoid/contents/ui/tabs/RamTab.qml").read_text()
        self.assertIn('label: "LAST CMOS REQUEST"', trainer)
        self.assertIn("last requested, not read back", plasma)

    def test_fixed_cli_catalog_matches_both_native_allowlists_and_real_routes(self):
        parity = ast.parse((ROOT / "backend/bc250_control/parity.py").read_text())
        expected = {section[0] for section in assignment(parity, "CLI_SECTIONS")}
        plasma = (ROOT / "desktop-control/plasmoid/contents/ui/Utils.js").read_text()
        body = plasma.split("function cliSection(value)", 1)[1].split("\n}", 1)[0]
        actual = set(json.loads(re.search(r'allowed\(value,\s*(\[[\s\S]*?\])\)', body).group(1)))
        self.assertEqual(actual, expected)
        trainer = (ROOT / "trainer/src/Bc250Bridge.cpp").read_text()
        body = trainer.split("const QStringList CliSections =", 1)[1].split("};", 1)[0]
        self.assertEqual(set(re.findall(r'QStringLiteral\("([^"\n]+)"\)', body)), expected)
        toolkit = (ROOT / "bc250-toolkit.sh").read_text().split('case "$command_name" in', 1)[1]
        routes = set()
        for label in re.findall(r"^    ([a-z][a-z|\-]*)\)", toolkit, re.MULTILINE):
            routes.update(label.split("|"))
        self.assertFalse(expected - routes)


if __name__ == "__main__":
    unittest.main()
