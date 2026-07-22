#!/usr/bin/env python3
"""Tests for the standalone desktop-control release artifact."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STAGER = ROOT / "scripts/stage-desktop-runtime.py"


class DesktopReleaseTests(unittest.TestCase):
    def test_plasma_six_package_contract(self):
        plasmoid = ROOT / "desktop-control/plasmoid"
        metadata = json.loads((plasmoid / "metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(
            metadata["KPlugin"]["Id"],
            "io.github.keyboardspecialist.bc250control",
        )
        self.assertEqual(metadata["X-Plasma-API-Minimum-Version"], "6.0")

        main = (plasmoid / "contents/ui/main.qml").read_text(encoding="utf-8")
        self.assertIn("switchWidth: 720", main)
        self.assertIn("toolTipMainText:", main)
        self.assertIn("Backend { id: backendController }", main)
        self.assertIn("backend: backendController", main)
        self.assertNotIn("backend: backend\n", main)
        self.assertNotIn("Plasmoid.switchWidth", main)
        self.assertNotIn("Plasmoid.toolTipMainText", main)

        control = (plasmoid / "contents/ui/ControlView.qml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(control.count('text: "Open Full Controls"'), 1)
        self.assertNotIn("Kirigami.MessageType.Positive", control)
        self.assertNotIn("Kirigami.MessageType.Error", control)
        self.assertIn("opacity: root.backend.busy ? 1 : 0", control)

        cu_tab = (plasmoid / "contents/ui/tabs/CuTab.qml").read_text(
            encoding="utf-8"
        )
        self.assertIn("readonly property color stateColor", cu_tab)
        self.assertIn("Layout.preferredWidth: 80", cu_tab)
        self.assertIn("Flickable {\n            id: cuScroll", cu_tab)
        self.assertNotIn("GridLayout {\n                id: cuGrid", cu_tab)

        cec_tab = (plasmoid / "contents/ui/tabs/CecTab.qml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(cec_tab.count("onClicked: root.backend.setCecToggle"), 4)
        self.assertNotIn("onToggled: root.backend.setCecToggle", cec_tab)

        icon = (plasmoid / "contents/ui/components/HealthIcon.qml").read_text(
            encoding="utf-8"
        )
        self.assertIn("Kirigami.Icon", icon)
        self.assertIn('Qt.resolvedUrl("../../icons/bc250-control.svg")', icon)
        self.assertNotIn("PlasmaCore.IconItem", icon)

        tray_icon = plasmoid / "contents/icons/bc250-control.svg"
        self.assertTrue(tray_icon.is_file())

    def test_archive_is_deterministic_and_independent_from_decky(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            output = temporary_path / "runtime"
            first = temporary_path / "first.zip"
            second = temporary_path / "second.zip"

            for archive in (first, second):
                subprocess.run(
                    [
                        sys.executable,
                        str(STAGER),
                        "--output",
                        str(output),
                        "--archive",
                        str(archive),
                    ],
                    cwd=str(ROOT),
                    check=True,
                )

            self.assertEqual(
                hashlib.sha256(first.read_bytes()).digest(),
                hashlib.sha256(second.read_bytes()).digest(),
            )

            with zipfile.ZipFile(str(first)) as archive:
                names = set(archive.namelist())
                prefix = "bc250-desktop-control/"
                for expected in (
                    "backend/bc250_control/backend.py",
                    "desktop-control/install.sh",
                    "desktop-control/plasmoid/contents/icons/bc250-control.svg",
                    "desktop-control/plasmoid/metadata.json",
                    "desktop-control/service/bc250-control-service",
                    "desktop-control/vendor/dbus_next/__init__.py",
                ):
                    self.assertIn(prefix + expected, names)
                self.assertFalse(any("decky-plugin" in name for name in names))
                self.assertFalse(any("__pycache__" in name for name in names))
                self.assertFalse(any(name.endswith((".pyc", ".pyo")) for name in names))


if __name__ == "__main__":
    unittest.main()
