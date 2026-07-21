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
        self.assertNotIn("Plasmoid.switchWidth", main)
        self.assertNotIn("Plasmoid.toolTipMainText", main)

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
