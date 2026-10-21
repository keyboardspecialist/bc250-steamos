#!/usr/bin/env python3
"""Mock-only Plasma parity contracts; no service or hardware mutations."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "desktop-control/plasmoid/contents/ui"


class PlasmaParityTests(unittest.TestCase):
    def test_production_javascript_and_backend_validation(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node.js is unavailable")
        result = subprocess.run(
            [node, str(UI / "tests/test_parity.cjs")], cwd=ROOT,
            text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_methods_are_allowlisted_with_correct_wire_signatures(self):
        backend = (UI / "Backend.qml").read_text()
        command = backend.split("function _command(", 1)[1].split("function _enqueue(", 1)[0]
        for method in ("SetTemperatureTarget", "GpuVoltageAction", "ResetGpuRamp", "GetCliCatalog", "OpenCliSection"):
            self.assertIn('"' + method + '"', command)
        self.assertIn('"y"', command)
        self.assertIn('"siii"', command)
        self.assertIn('_startMutation("GpuVoltageAction", "siii", change.args', backend)
        self.assertIn('_startMutation("ResetGpuRamp", "", []', backend)
        self.assertIn('_command("GetCliCatalog", "", []', backend)
        self.assertIn('_startMutation("OpenCliSection", "s", [id]', backend)
        self.assertIn("operationCancellable = operationCancellable && operation.cancellable !== false", backend)
        self.assertIn('Utils.safeOperationId(operationId)', backend)
        self.assertIn('"CancelOperation"', command)

    def test_overview_uses_live_labels_and_generic_sensor_inventory(self):
        overview = (UI / "tabs/OverviewTab.qml").read_text()
        for key in ("cpuClock", "gpuClock", "cpuTemp", "gpuTemp"):
            self.assertIn('latestTelemetry("' + key + '")', overview)
        self.assertNotIn("value: Utils.valueOrDash(root.snapshot", overview)
        self.assertIn("model: root.backend.latestSensors()", overview)
        self.assertIn("Utils.sensorValue(modelData)", overview)

    def test_risky_workflows_require_confirmation_and_service_guards(self):
        catalog = (UI / "tabs/CliTab.qml").read_text()
        self.assertIn('section.modelData.risk === "read-only"', catalog)
        self.assertIn("confirmation.ask(", catalog)
        self.assertIn("root.catalog.reason", catalog)
        self.assertIn("successful launch does not mean", catalog)
        self.assertNotIn("connectSource", catalog)
        cpu = (UI / "tabs/CpuTab.qml").read_text()
        for action in ("metrics-enable", "uninstall"):
            self.assertIn('root.unlockActionEnabled("' + action + '")', cpu)
            self.assertIn('root.backend.cpuUnlockAction("' + action + '")', cpu)
        self.assertIn("unlockActionState(action).available === true", cpu)
        curve = (UI / "components/VoltageCurveEditor.qml").read_text()
        self.assertIn("!root.preview.error", curve)
        self.assertIn("confirmation.ask(", curve)
        self.assertIn("Utils.voltageChange(", curve)

    def test_mock_qml_all_tabs(self):
        qml = shutil.which("qml6") or shutil.which("qmlscene6")
        if not qml:
            self.skipTest("Qt 6 QML runtime is unavailable")
        result = subprocess.run(
            [qml, "-I", str(UI), str(UI / "tests/SmokeHarness.qml")],
            cwd=ROOT, env=dict(os.environ, QT_QPA_PLATFORM="offscreen"),
            text=True, capture_output=True, timeout=20,
        )
        output = result.stdout + result.stderr
        if re.search(r'module "[^"]+" is not installed', output):
            self.skipTest("Qt/KDE QML modules are unavailable: " + output.strip())
        self.assertEqual(result.returncode, 0, output)
        self.assertNotRegex(output, r"TypeError|ReferenceError|Binding loop|Cannot assign|Unable to assign")


if __name__ == "__main__":
    unittest.main()
