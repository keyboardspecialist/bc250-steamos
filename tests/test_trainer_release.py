#!/usr/bin/env python3
"""Tests for BC250 Trainer packaging and shared-service lifecycle contracts."""

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STAGER = ROOT / "scripts/stage-trainer-runtime.py"
INSTALLER = ROOT / "trainer/install.sh"
FLATPAK_INSTALLER = ROOT / "trainer/install-flatpak.sh"
SHARED = ROOT / "desktop-control/shared-service-install.sh"


class TrainerReleaseTests(unittest.TestCase):
    def test_distrobox_checks_qml_and_multimedia_runtime_packages(self):
        helper = (ROOT / "trainer/build-distrobox.sh").read_text(encoding="utf-8")
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
            binary = root / "bc250-trainer"
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
                prefix = "bc250-trainer/"
                for expected in (
                    "trainer/bc250-trainer",
                    "trainer/install.sh",
                    "trainer/ASSET-LICENSE",
                    "trainer/tracks/Neon Bootloader.mp3",
                    "trainer/tracks/Neon Mirage.mp3",
                    "trainer/tracks/Neon Void.mp3",
                    "trainer/tracks/Rust in the Static.mp3",
                    "trainer/tracks/Static Horizon.mp3",
                    "trainer/tracks/System Override.mp3",
                    "trainer/packaging/io.github.keyboardspecialist.bc250trainer.desktop.in",
                    "desktop-control/shared-service-install.sh",
                    "desktop-control/service/bc250-control-service",
                    "backend/bc250_control/backend.py",
                    "bc250-power.sh",
                    "bc250-ram-split.sh",
                    "bc250-storage.sh",
                    "bc250-update-persistence.sh",
                    "core-unlock/bc250-unlock-cores.py",
                    "core-unlock/bc250-unlock-cores-efi.c",
                    "core-unlock/EFI-LICENSE",
                    "core-unlock/EFI-HEADERS-LICENSE",
                    "core-unlock/LICENSE",
                    "topology.sh",
                ):
                    self.assertIn(prefix + expected, names)
                self.assertFalse(any("__pycache__" in name for name in names))
                self.assertFalse(any(name.endswith(".DS_Store") for name in names))
                self.assertFalse(any(name.endswith("bc250-core-unlock.efi") for name in names))
                mode = archive.getinfo(prefix + "trainer/bc250-trainer").external_attr >> 16
                self.assertEqual(mode & 0o777, 0o755)
                for name in (
                    "core-unlock/bc250-unlock-cores-efi.c",
                    "core-unlock/EFI-LICENSE",
                    "core-unlock/EFI-HEADERS-LICENSE",
                ):
                    mode = archive.getinfo(prefix + name).external_attr >> 16
                    self.assertEqual(mode & 0o777, 0o644)

    def test_installer_uses_absolute_exec_and_recognized_ownership(self):
        source = INSTALLER.read_text(encoding="utf-8")
        template = (
            ROOT
            / "trainer/packaging/io.github.keyboardspecialist.bc250trainer.desktop.in"
        ).read_text(encoding="utf-8")
        self.assertIn('APP_BIN="$APP_DIR/bc250-trainer"', source)
        self.assertIn('grep -Fxq "Exec=$APP_BIN"', source)
        self.assertIn("user_install_owned", source)
        self.assertIn("Refusing to replace files not recognized", source)
        self.assertIn("Refusing to remove files not recognized", source)
        self.assertIn("uninstall-legacy", source)
        self.assertIn("LEGACY_OWNER_VALUE", source)
        self.assertIn("Exec=@EXEC@", template)
        self.assertIn(
            "X-BC250-Installer-Owner=io.github.keyboardspecialist.bc250trainer",
            template,
        )
        result = subprocess.run(
            ["bash", str(INSTALLER), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("{install|status|uninstall|uninstall-legacy|help}", result.stdout)

    def test_legacy_uninstall_accepts_pre_media_owned_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            app = home / ".local/libexec/bc250-cracktro"
            desktop = home / ".local/share/applications/io.github.keyboardspecialist.bc250cracktro.desktop"
            icon = home / ".local/share/icons/hicolor/scalable/apps/io.github.keyboardspecialist.bc250cracktro.svg"
            app.mkdir(parents=True)
            desktop.parent.mkdir(parents=True)
            icon.parent.mkdir(parents=True)
            (app / ".bc250-cracktro-owner").write_text(
                "schema=1;owner=io.github.keyboardspecialist.bc250cracktro\n",
                encoding="ascii",
            )
            (app / "bc250-cracktro").write_bytes(b"legacy executable")
            desktop.write_text(
                "[Desktop Entry]\n"
                "X-BC250-Installer-Owner=io.github.keyboardspecialist.bc250cracktro\n"
                f"Exec={app}/bc250-cracktro\n",
                encoding="utf-8",
            )
            icon.write_text("legacy icon\n", encoding="ascii")
            bindir = Path(temporary) / "bin"
            bindir.mkdir()
            sudo = bindir / "sudo"
            sudo.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            sudo.chmod(0o755)
            environment = os.environ.copy()
            environment["HOME"] = str(home)
            environment["PATH"] = f"{bindir}:{environment['PATH']}"

            subprocess.run(
                ["bash", str(INSTALLER), "uninstall-legacy"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertFalse(app.exists())
            self.assertFalse(desktop.exists())
            self.assertFalse(icon.exists())

    def test_flatpak_installation_kit_contains_gui_and_host_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "trainer.flatpak"
            bundle.write_bytes(b"flatpak bundle placeholder")
            output = root / "runtime"
            archive_path = root / "flatpak-installer.zip"
            subprocess.run(
                [
                    sys.executable,
                    str(STAGER),
                    "--flatpak",
                    str(bundle),
                    "--output",
                    str(output),
                    "--archive",
                    str(archive_path),
                ],
                cwd=str(ROOT),
                check=True,
            )

            prefix = "bc250-trainer-flatpak-installer/"
            with zipfile.ZipFile(archive_path) as archive:
                names = set(archive.namelist())
                for expected in (
                    "trainer/install-flatpak.sh",
                    "trainer/install.sh",
                    "trainer/io.github.keyboardspecialist.bc250trainer.flatpak",
                    "desktop-control/shared-service-install.sh",
                    "desktop-control/service/bc250-control-service",
                    "backend/bc250_control/backend.py",
                    "bc250-storage.sh",
                    "bc250-update-persistence.sh",
                    "core-unlock/bc250-unlock-cores-efi.c",
                    "core-unlock/EFI-LICENSE",
                    "core-unlock/EFI-HEADERS-LICENSE",
                ):
                    self.assertIn(prefix + expected, names)
                self.assertNotIn(prefix + "trainer/bc250-trainer", names)
                self.assertFalse(any(name.endswith("bc250-core-unlock.efi") for name in names))
                mode = archive.getinfo(prefix + "trainer/install-flatpak.sh").external_attr >> 16
                self.assertEqual(mode & 0o777, 0o755)

        installer = FLATPAK_INSTALLER.read_text(encoding="utf-8")
        self.assertIn("CLIENT=trainer-flatpak", installer)
        self.assertIn("flatpak install --user --noninteractive --or-update", installer)
        self.assertIn('sudo bash "$SOURCE_DIR/install-flatpak.sh" _install-root', installer)
        self.assertIn('bash "$LEGACY_INSTALLER" uninstall-legacy', installer)
        result = subprocess.run(
            ["bash", str(FLATPAK_INSTALLER), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("privileged BC-250 host service", result.stdout)

    def test_flatpak_manifest_has_narrow_permissions_and_desktop_exports(self):
        manifest = (
            ROOT
            / "trainer/packaging/io.github.keyboardspecialist.bc250trainer.yml"
        ).read_text(encoding="utf-8")
        cmake = (ROOT / "trainer/CMakeLists.txt").read_text(encoding="utf-8")
        for expected in (
            "runtime: org.kde.Platform",
            "runtime-version: '6.10'",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--system-talk-name=io.github.keyboardspecialist.BC250Control1",
        ):
            self.assertIn(expected, manifest)
        self.assertNotIn("--filesystem=host", manifest)
        self.assertNotIn("org.freedesktop.Flatpak", manifest)
        self.assertIn("share/applications", cmake)
        self.assertIn("share/metainfo", cmake)
        self.assertIn("share/bc250-trainer", cmake)

    def test_shared_payload_and_client_registry_contract(self):
        source = SHARED.read_text(encoding="utf-8")
        for expected in (
            '"$SHARED_REPO_DIR/bc250-power.sh"',
            '"$SHARED_REPO_DIR/bc250-storage.sh"',
            '"$SHARED_REPO_DIR/bc250-update-persistence.sh"',
            '"$SHARED_REPO_DIR/core-unlock/bc250-unlock-cores.py"',
            '"$SHARED_REPO_DIR/core-unlock/bc250-unlock-cores-efi.c"',
            '"$SHARED_REPO_DIR/core-unlock/EFI-LICENSE"',
            '"$SHARED_REPO_DIR/core-unlock/EFI-HEADERS-LICENSE"',
            '"$SHARED_REPO_DIR/core-unlock/LICENSE"',
        ):
            self.assertIn(expected, source)
        self.assertIn("/var/lib/bc250-control/service-clients", source)
        self.assertIn("plasma|trainer|trainer-flatpak|cracktro", source)
        self.assertIn('|| "$1" == cracktro', source)
        self.assertNotIn("Migrated cracktro.${uid} registration", source)
        self.assertIn("shared_migrate_markerless_install", source)
        self.assertIn("Preserved markerless service install as legacy.0", source)
        self.assertIn('"$client" == trainer-flatpak', source)
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
            marker = registry / "trainer.1000"
            marker.write_text("schema=1\nclient=trainer\nuid=1000\n", encoding="ascii")
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
            for client in ("plasma", "trainer"):
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
                    "trainer",
                    str(uid),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertFalse((registry / f"trainer.{uid}").exists())
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

    def test_markerless_flatpak_release_preserves_unknown_service_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            registry = root / "clients"
            payload = root / "payload"
            payload.mkdir()
            uid = os.getuid()
            command = (
                'script=$1; registry=$2; payload=$3; uid=$4; '
                'set -- help; source "$script" >/dev/null; '
                'SHARED_CLIENT_DIR=$registry; SHARED_PAYLOAD_DIR=$payload; '
                'SHARED_ROOT_UID=$(id -u); '
                'SHARED_ROOT_GID=$(id -g); '
                'shared_require_root() { :; }; shared_acquire_install_lock() { :; }; '
                'shared_service_release trainer-flatpak "$uid"'
            )
            subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(SHARED),
                    str(registry),
                    str(payload),
                    str(uid),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            marker = registry / "legacy.0"
            self.assertEqual(
                marker.read_text(encoding="ascii"),
                "schema=1\nclient=legacy\nuid=0\n",
            )
            self.assertFalse((registry / f"plasma.{uid}").exists())
            self.assertTrue(payload.exists())

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
            "ctest --test-dir build/trainer --output-on-failure",
            "--target qml-lint",
            "--mock --smoke-test",
            "scripts/stage-trainer-runtime.py",
            "TRAINER_ARTIFACT_BASENAME",
            "trainer core-unlock backend scripts topology.sh",
            "install -m 0755 build/trainer/bc250-trainer",
            "BC250 Trainer asset redistribution is not yet cleared",
            "Main release tags must point to commits on master",
            "flatpak-builder",
            'TRAINER_PROJECT_VERSION="$VERSION"',
            "--flatpak",
            "-flatpak-installer.zip",
        ):
            self.assertIn(expected, workflow)
        self.assertLess(
            workflow.index("git archive --format=tar HEAD"),
            workflow.index('"$package_dir/trainer/bc250-trainer"'),
        )

    def test_trainer_release_has_isolated_tag_namespace(self):
        workflow = (ROOT / ".github/workflows/trainer-release.yml").read_text(
            encoding="utf-8"
        )
        for expected in (
            '"trainer-v*"',
            "BC250 Trainer release tags must point to commits on master",
            "TRAINER_PROJECT_VERSION",
            "scripts/stage-trainer-runtime.py",
            "BC250 Trainer asset redistribution is not yet cleared",
            "must be an annotated tag",
            "--prerelease",
            "flatpak-builder",
            'TRAINER_PROJECT_VERSION="$VERSION"',
            "-flatpak-installer.zip",
        ):
            self.assertIn(expected, workflow)
        self.assertNotIn('tags:\n      - "v*"', workflow)
        self.assertNotIn("workflow_dispatch", workflow)
        self.assertNotIn("origin/trainer", workflow)

        cmake = (ROOT / "trainer/CMakeLists.txt").read_text(encoding="utf-8")
        self.assertIn("TRAINER_PROJECT_VERSION", cmake)

        assets = (ROOT / "trainer/ASSETS.md").read_text(encoding="utf-8")
        self.assertIn("ASSET-LICENSE", assets)
        self.assertIn("Cleared for inclusion", assets)
        self.assertNotIn("Do not publish either asset in a release", assets)


if __name__ == "__main__":
    unittest.main()
