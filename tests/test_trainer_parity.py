#!/usr/bin/env python3
"""Read-only Trainer parity contracts runnable without a Qt SDK or hardware."""

import ast
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
TRAINER = ROOT / "trainer"
BRIDGE = (TRAINER / "src/Bc250Bridge.cpp").read_text()
HEADER = (TRAINER / "src/Bc250Bridge.h").read_text()


class TrainerParityTests(unittest.TestCase):
    def test_optional_bus_contracts_match_service(self):
        module = ast.parse((ROOT / "desktop-control/service/bc250_control_service/dbus_adapter.py").read_text())
        xml = next(ast.literal_eval(node.value) for node in module.body
                   if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "INTROSPECTION_XML" for target in node.targets))
        methods = {method.attrib["name"]: (
            "".join(arg.attrib["type"] for arg in method.findall("arg") if arg.attrib.get("direction") == "in"),
            "".join(arg.attrib["type"] for arg in method.findall("arg") if arg.attrib.get("direction") == "out"),
        ) for method in ET.fromstring(xml).findall("interface/method")}
        contracts = {
            "GpuVoltageAction": ("siii", "s"), "ResetGpuRamp": ("", "s"),
            "GetFsr4Inventory": ("", "s"), "InstallFsr4Dll": ("s", "s"),
            "UninstallFsr4Dll": ("s", "s"), "PrepareHelixsr": ("", "s"),
            "InstallHelixsr": ("s", "s"), "UninstallHelixsr": ("s", "s"),
            "InstallOptiscaler": ("ss", "s"), "UninstallOptiscaler": ("s", "s"),
            "CecAction": ("s", "s"), "SetCecToggle": ("sb", "s"),
            "SetCecName": ("s", "s"), "GetCliCatalog": ("", "s"),
            "OpenCliSection": ("s", "s"),
        }
        for name, contract in contracts.items():
            with self.subTest(method=name):
                self.assertEqual(methods[name], contract)
                self.assertIn(f'QStringLiteral("{name}")', BRIDGE)

    def test_invokables_have_native_implementations(self):
        for method in re.findall(r"Q_INVOKABLE void (\w+)\(", HEADER):
            self.assertRegex(BRIDGE, rf"void Bc250Bridge::{method}\(")

    def test_all_qml_is_packaged_and_resources_exist(self):
        resources = ET.parse(TRAINER / "resources.qrc")
        aliases = {entry.attrib.get("alias") for entry in resources.findall("qresource/file")}
        for qml in (TRAINER / "qml").rglob("*.qml"):
            self.assertIn(qml.relative_to(TRAINER).as_posix(), aliases)
        for entry in resources.findall("qresource/file"):
            self.assertTrue((TRAINER / entry.text).is_file(), entry.text)

    def test_mock_json_is_valid_and_game_ids_are_opaque(self):
        documents = [json.loads(raw) for raw in re.findall(r'R"json\((.*?)\)json"', BRIDGE, re.S)]
        self.assertGreaterEqual(len(documents), 4)
        inventory = next(document for document in documents if "games" in document)
        self.assertTrue(inventory["available"])
        game = inventory["games"][0]
        self.assertTrue(game["fullyInstalled"])
        self.assertEqual(game["scanState"], "complete")
        for target in game["targets"]:
            self.assertRegex(target["targetId"], r"^[0-9a-f]{64}$")
        for candidate in game["optiscalerCandidates"]:
            self.assertRegex(candidate["candidateId"], r"^[0-9a-f]{64}$")
        self.assertIn("discoveredId(id, candidate)", BRIDGE)

    def test_sampling_is_read_only_and_sensors_have_fallback(self):
        sample = BRIDGE.split("void Bc250Bridge::sampleTelemetry()", 1)[1].split("void Bc250Bridge::requestJson", 1)[0]
        self.assertNotIn("startMutation", sample)
        self.assertNotIn("metrics-enable", sample)
        self.assertIn('QStringLiteral("GetTelemetry")', sample)
        status = (TRAINER / "qml/pages/StatusPage.qml").read_text()
        self.assertIn("Array.isArray(telemetry.sensors)", status)
        self.assertIn("Array.isArray(power.sensors)", status)
        self.assertIn('typeof modelData.value === "number"', status)
        for name in ("cpuClock", "gpuClock", "cpuTemp", "gpuTemp"):
            self.assertIn(name, status)

    def test_flatpak_stays_unprivileged_and_handoff_is_blocked(self):
        manifest = (TRAINER / "packaging/io.github.keyboardspecialist.bc250trainer.yml").read_text()
        for permission in ("--filesystem=host", "--filesystem=home", "--talk-name=org.freedesktop.Flatpak", "flatpak-spawn"):
            self.assertNotIn(permission, manifest)
        handoff = BRIDGE.split("void Bc250Bridge::openCliSection", 1)[1].split("void Bc250Bridge::cpuOcAction", 1)[0]
        self.assertIn("if (sandboxed())", handoff)
        self.assertIn("CliSections.contains(section)", handoff)
        self.assertIn('value(QStringLiteral("sections"))', handoff)
        self.assertNotIn("QProcess", BRIDGE)
        self.assertNotIn("system(", BRIDGE)

    def test_native_catalog_matches_fixed_backend_sections(self):
        module = ast.parse((ROOT / "backend/bc250_control/parity.py").read_text())
        sections = next(ast.literal_eval(node.value) for node in module.body
                        if isinstance(node, ast.Assign)
                        and any(isinstance(target, ast.Name) and target.id == "CLI_SECTIONS" for target in node.targets))
        native = BRIDGE.split("const QStringList CliSections =", 1)[1].split("};", 1)[0]
        self.assertEqual(set(re.findall(r'QStringLiteral\("([^"]+)"\)', native)), {section[0] for section in sections})

    def test_voltage_wire_arguments_are_signed_and_unused_zero(self):
        curve = BRIDGE.split("void Bc250Bridge::gpuVoltageAction", 1)[1].split("bool Bc250Bridge::discoveredId", 1)[0]
        self.assertIn("{action, frequency, voltage, newFrequency}", curve)
        self.assertNotIn("fromValue<uint>", curve)
        self.assertIn('action == QStringLiteral("reset")) { frequency = 0; voltage = 0; }', curve)
        self.assertIn('action == QStringLiteral("offset")) frequency = 0;', curve)
        self.assertIn('action == QStringLiteral("remove")) voltage = 0;', curve)
        self.assertIn('action != QStringLiteral("edit")) newFrequency = 0;', curve)
        self.assertIn("points.size() >= 2", curve)
        self.assertIn("entry.second >= 700 && entry.second <= 1050", curve)

    def test_game_ui_preserves_safety_and_rollback_blockers(self):
        for filename in ("GameTarget.qml", "OptiscalerTarget.qml"):
            source = (TRAINER / "qml/components" / filename).read_text()
            with self.subTest(component=filename):
                for expected in ("anti-cheat", "rollback", '"modified", "invalid"', "discovered === true", "ConfirmDialog"):
                    self.assertIn(expected, source)
        game = (TRAINER / "qml/components/GameTarget.qml").read_text()
        self.assertIn("hasManagedOptiscaler()", game)
        self.assertIn('game.scanState === "complete"', game)
        self.assertIn("helixsrPayloadState", game)
        self.assertIn("orphanedOptiscaler", (TRAINER / "qml/pages/GamesPage.qml").read_text())

    def test_optiscaler_proxy_allowlist_matches_service(self):
        module = ast.parse((ROOT / "desktop-control/service/bc250_control_service/control.py").read_text())
        proxies = next(ast.literal_eval(node.value.args[0]) for node in module.body
                       if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == "OPTISCALER_PROXIES" for target in node.targets))
        bridge = BRIDGE.split("void Bc250Bridge::installOptiscaler", 1)[1].split("void Bc250Bridge::uninstallOptiscaler", 1)[0]
        self.assertEqual(set(re.findall(r'QStringLiteral\("([^"/]+\.dll)"\)', bridge)), proxies)
        qml = (TRAINER / "qml/components/OptiscalerTarget.qml").read_text()
        self.assertEqual(set(re.findall(r'"([^"/]+\.dll)"', qml)), proxies)


if __name__ == "__main__":
    unittest.main()
