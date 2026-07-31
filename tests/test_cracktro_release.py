#!/usr/bin/env python3
"""Tests for Cracktro packaging and shared-service lifecycle contracts."""

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STAGER = ROOT / "scripts/stage-cracktro-runtime.py"
INSTALLER = ROOT / "cracktro/install.sh"
SHARED = ROOT / "desktop-control/shared-service-install.sh"


class CracktroReleaseTests(unittest.TestCase):
    def test_distrobox_checks_qml_and_multimedia_runtime_packages(self):
        helper = (ROOT / "cracktro/build-distrobox.sh").read_text(encoding="utf-8")
        for expected in (
            "dpkg-query -W",
            "qml6-module-qtquick-dialogs",
            "gstreamer1.0-plugins-base",
            "gstreamer1.0-plugins-good",
            "gstreamer1.0-pulseaudio",
        ):
            self.assertIn(expected, helper)

    def test_archive_and_checksum_are_deterministic_and_standalone(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "bc250-cracktro"
            binary.write_bytes(b"#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            output = root / "runtime"
            archives = (root / "first.zip", root / "second.zip")
            checksums = (root / "first.zip.sha256", root / "second.zip.sha256")
            environment = os.environ.copy()
            environment["SOURCE_DATE_EPOCH"] = "1700000000"

            for archive, checksum in zip(archives, checksums):
                subprocess.run(
                    [
                        sys.executable,
                        str(STAGER),
                        "--binary",
                        str(binary),
                        "--output",
                        str(output),
                        "--archive",
                        str(archive),
                        "--sha256",
                        str(checksum),
                    ],
                    cwd=str(ROOT),
                    env=environment,
                    check=True,
                )

            first_digest = hashlib.sha256(archives[0].read_bytes()).hexdigest()
            self.assertEqual(first_digest, hashlib.sha256(archives[1].read_bytes()).hexdigest())
            self.assertEqual(
                checksums[0].read_text(encoding="ascii"),
                f"{first_digest}  first.zip\n",
            )
            self.assertTrue(
                checksums[1].read_text(encoding="ascii").endswith("  second.zip\n")
            )

            with zipfile.ZipFile(archives[0]) as archive:
                names = set(archive.namelist())
                prefix = "bc250-cracktro/"
                for expected in (
                    "cracktro/bc250-cracktro",
                    "cracktro/install.sh",
                    "cracktro/ASSET-LICENSE",
                    "cracktro/tracks/Neon Bootloader.mp3",
                    "cracktro/tracks/Neon Mirage.mp3",
                    "cracktro/tracks/Neon Void.mp3",
                    "cracktro/tracks/Static Horizon.mp3",
                    "cracktro/tracks/System Override.mp3",
                    "cracktro/packaging/io.github.keyboardspecialist.bc250cracktro.desktop.in",
                    "desktop-control/shared-service-install.sh",
                    "desktop-control/service/bc250-control-service",
                    "backend/bc250_control/backend.py",
                    "bc250-power.sh",
                    "bc250-ram-split.sh",
                    "bc250-storage.sh",
                    "bc250-update-persistence.sh",
                    "core-unlock/bc250-unlock-cores.py",
                    "core-unlock/LICENSE",
                    "topology.sh",
                ):
                    self.assertIn(prefix + expected, names)
                self.assertFalse(any("__pycache__" in name for name in names))
                self.assertFalse(any(name.endswith(".DS_Store") for name in names))
                mode = archive.getinfo(prefix + "cracktro/bc250-cracktro").external_attr >> 16
                self.assertEqual(mode & 0o777, 0o755)

    def test_installer_uses_absolute_exec_and_recognized_ownership(self):
        source = INSTALLER.read_text(encoding="utf-8")
        template = (
            ROOT
            / "cracktro/packaging/io.github.keyboardspecialist.bc250cracktro.desktop.in"
        ).read_text(encoding="utf-8")
        self.assertIn('APP_BIN="$APP_DIR/bc250-cracktro"', source)
        self.assertIn('grep -Fxq "Exec=$APP_BIN"', source)
        self.assertIn("user_install_owned", source)
        self.assertIn("Refusing to replace files not recognized", source)
        self.assertIn("Refusing to remove files not recognized", source)
        self.assertIn("Exec=@EXEC@", template)
        self.assertIn(
            "X-BC250-Installer-Owner=io.github.keyboardspecialist.bc250cracktro",
            template,
        )
        result = subprocess.run(
            ["bash", str(INSTALLER), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("{install|status|uninstall|help}", result.stdout)

    def test_shared_payload_and_client_registry_contract(self):
        source = SHARED.read_text(encoding="utf-8")
        for expected in (
            '"$SHARED_REPO_DIR/bc250-power.sh"',
            '"$SHARED_REPO_DIR/bc250-storage.sh"',
            '"$SHARED_REPO_DIR/bc250-update-persistence.sh"',
            '"$SHARED_REPO_DIR/core-unlock/bc250-unlock-cores.py"',
            '"$SHARED_REPO_DIR/core-unlock/LICENSE"',
        ):
            self.assertIn(expected, source)
        self.assertIn("/var/lib/bc250-control/service-clients", source)
        self.assertIn("plasma|cracktro", source)
        self.assertIn("shared_migrate_markerless_install", source)
        self.assertIn("Preserved markerless service install as legacy.0", source)
        self.assertIn("SHARED_CORE_UNLOCK_LIFECYCLE_LOCK", source)
        self.assertIn("Claimed markerless Plasma service install before release", source)
        self.assertIn("Replaced the legacy preservation marker with plasma.${uid}", source)
        self.assertLess(
            source.index("shared_acquire_unlock_lifecycle\n    systemctl stop"),
            source.index("shared_replace_payload", source.index("shared_service_install()")),
        )
        release = source[source.index("shared_service_release()") :]
        self.assertLess(release.index("remaining=$((SHARED_CLIENT_COUNT - 1))"), release.index("shared_remove_service"))
        self.assertIn("if [[ $remaining -gt 0 ]]", release)

    def test_uid_marker_validation_runs_without_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            registry = Path(temporary) / "clients"
            registry.mkdir(mode=0o755)
            marker = registry / "cracktro.1000"
            marker.write_text("schema=1\nclient=cracktro\nuid=1000\n", encoding="ascii")
            marker.chmod(0o644)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; registry=$2; set -- help; source "$script" >/dev/null; '
                    'SHARED_CLIENT_DIR=$registry; SHARED_ROOT_UID=$(id -u); '
                    "shared_validate_client_registry; printf '%s\\n' \"$SHARED_CLIENT_COUNT\"",
                    "_",
                    str(SHARED),
                    str(registry),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout.strip(), "1")

    def test_frontend_release_removes_service_only_after_last_client(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            registry = root / "clients"
            registry.mkdir(mode=0o755)
            uid = os.getuid()
            self.assertGreater(uid, 0)
            for client in ("plasma", "cracktro"):
                marker = registry / f"{client}.{uid}"
                marker.write_text(
                    f"schema=1\nclient={client}\nuid={uid}\n", encoding="ascii"
                )
                marker.chmod(0o644)
            removed = root / "service-removed"
            command = (
                'script=$1; registry=$2; removed=$3; client=$4; uid=$5; '
                'set -- help; source "$script" >/dev/null; '
                'SHARED_CLIENT_DIR=$registry; SHARED_ROOT_UID=$(id -u); '
                'SHARED_PAYLOAD_DIR="$registry/payload"; '
                'shared_require_root() { :; }; shared_acquire_install_lock() { :; }; '
                'shared_acquire_unlock_lifecycle() { :; }; '
                'shared_remove_service() { printf removed > "$removed"; }; '
                'shared_service_release "$client" "$uid"'
            )
            subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(SHARED),
                    str(registry),
                    str(removed),
                    "cracktro",
                    str(uid),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertFalse((registry / f"cracktro.{uid}").exists())
            self.assertTrue((registry / f"plasma.{uid}").exists())
            self.assertFalse(removed.exists())

            subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(SHARED),
                    str(registry),
                    str(removed),
                    "plasma",
                    str(uid),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertTrue(removed.exists())
            self.assertFalse(registry.exists())

    def test_release_workflow_builds_tests_stages_and_gates_assets(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        for expected in (
            "qt6-base-dev",
            "qt6-declarative-dev",
            "qt6-multimedia-dev",
            "qml6-module-qtquick-dialogs",
            "gstreamer1.0-plugins-good",
            "ctest --test-dir build/cracktro --output-on-failure",
            "--target qml-lint",
            "--mock --smoke-test",
            "scripts/stage-cracktro-runtime.py",
            "CRACKTRO_ARTIFACT_BASENAME",
            "cracktro core-unlock backend scripts topology.sh",
            "Cracktro asset redistribution is not yet cleared",
            "Main release tags must point to commits on master",
        ):
            self.assertIn(expected, workflow)

    def test_cracktro_release_has_isolated_branch_and_tag_namespace(self):
        workflow = (ROOT / ".github/workflows/cracktro-release.yml").read_text(
            encoding="utf-8"
        )
        for expected in (
            '"cracktro-v*"',
            "Cracktro release tags must point to commits on the cracktro branch",
            "CRACKTRO_PROJECT_VERSION",
            "scripts/stage-cracktro-runtime.py",
            "Cracktro asset redistribution is not yet cleared",
            "must be an annotated tag",
            "--prerelease",
        ):
            self.assertIn(expected, workflow)
        self.assertNotIn('tags:\n      - "v*"', workflow)
        self.assertNotIn("workflow_dispatch", workflow)

        cmake = (ROOT / "cracktro/CMakeLists.txt").read_text(encoding="utf-8")
        self.assertIn("CRACKTRO_PROJECT_VERSION", cmake)

        assets = (ROOT / "cracktro/ASSETS.md").read_text(encoding="utf-8")
        self.assertIn("ASSET-LICENSE", assets)
        self.assertIn("Cleared for inclusion", assets)
        self.assertNotIn("Do not publish either asset in a release", assets)


if __name__ == "__main__":
    unittest.main()
