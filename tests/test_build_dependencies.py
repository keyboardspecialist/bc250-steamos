#!/usr/bin/env python3
"""Offline build-toolchain contracts; never install into the real home directory."""

import ast
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = json.loads((ROOT / "decky-plugin/package.json").read_text(encoding="utf-8"))
INSTALLER = (ROOT / "decky-plugin/install.sh").read_text(encoding="utf-8")


class BuildDependencyTests(unittest.TestCase):
    def test_ci_pins_the_python38_and_native_qt_runner_baseline(self):
        for name in ("trainer-checks.yml", "trainer-release.yml", "release-artifacts.yml"):
            with self.subTest(workflow=name):
                source = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
                runners = re.findall(r"^\s*runs-on:\s*(\S+)", source, re.M)
                self.assertTrue(runners)
                self.assertEqual(set(runners), {"ubuntu-24.04"})

    def test_native_and_release_jobs_install_archive_tools_for_package_fixtures(self):
        for name in ("trainer-checks.yml", "trainer-release.yml", "release-artifacts.yml"):
            with self.subTest(workflow=name):
                source = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
                packages = source.split("sudo apt-get install -y", 1)[1].split("\n\n", 1)[0]
                self.assertIn("zstd", packages.split())
                self.assertIn("p7zip-full", packages.split())

    def test_installer_and_ci_share_the_pinned_toolchain(self):
        manager, version = PACKAGE["packageManager"].split("@")
        self.assertEqual(manager, "pnpm")
        self.assertEqual(version, PACKAGE["engines"]["pnpm"])
        self.assertIn('PNPM_VERSION="{}"'.format(version), INSTALLER)
        self.assertIn('NODE_MAJOR="26"', INSTALLER)
        self.assertIn('NODE_MIN_MINOR="13"', INSTALLER)
        self.assertIn('NODE_MIN_PATCH="1"', INSTALLER)
        self.assertEqual(PACKAGE["engines"]["node"], ">=26.13.1 <27")
        self.assertNotIn("pnpm", PACKAGE)  # pnpm 12 no longer reads this field.
        self.assertIn("pnpm_build install --frozen-lockfile", INSTALLER)
        self.assertNotIn("get.pnpm.io/install.sh", INSTALLER)
        self.assertNotIn('cat >>"$rc"', INSTALLER)
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            workflow = path.read_text(encoding="utf-8")
            with self.subTest(workflow=path.name):
                self.assertIn("package_json_file: decky-plugin/package.json", workflow)
                self.assertIn("node-version: 26.13.1", workflow)
                self.assertIn("bash pnpm-build.sh install --frozen-lockfile", workflow)
                self.assertNotRegex(workflow, r"pnpm (install|run) ")
                for action, version in (
                    ("actions/checkout", "v7.0.1"),
                    ("actions/setup-python", "v7.1.0"),
                    ("actions/setup-node", "v7.1.0"),
                    ("actions/upload-artifact", "v7.0.2"),
                    ("pnpm/action-setup", "v6.1.1"),
                ):
                    for actual in re.findall(re.escape(action) + r"@(\S+)", workflow):
                        self.assertEqual(actual, version)

    def test_lock_uses_compatible_compiler_and_maintenance_security_fixes(self):
        lock = (ROOT / "decky-plugin/pnpm-lock.yaml").read_text(encoding="utf-8")
        self.assertIn("lockfileVersion: '9.0'\n", lock)
        # @decky/rollup 1.0.2 needs the pre-native TypeScript compiler API.
        self.assertEqual(PACKAGE["devDependencies"]["typescript"], "~5.9.3")
        self.assertEqual(set(re.findall(r"^  typescript@([^:]+):", lock, re.M)), {"5.9.3"})
        self.assertEqual(
            set(re.findall(r"^  brace-expansion@([^:]+):", lock, re.M)),
            {"1.1.22", "2.1.8"},
        )
        # No forced major upgrades or suppression of remaining build advisories.
        self.assertNotIn("overrides", PACKAGE.get("pnpm", {}))
        self.assertNotIn("auditConfig", PACKAGE.get("pnpm", {}))
        self.assertEqual(
            PACKAGE["devDependencies"]["rollup"],
            PACKAGE["devDependencies"]["@rollup/rollup-linux-x64-musl"],
        )

    def test_supported_python_and_flatpak_baselines(self):
        workflow = (ROOT / ".github/workflows/trainer-checks.yml").read_text(encoding="utf-8")
        self.assertIn('python: ["3.8", "3.14"]', workflow)
        self.assertIn('- "decky-plugin/**"', workflow)
        manifest = (ROOT / "trainer/packaging/io.github.keyboardspecialist.bc250trainer.yml").read_text(encoding="utf-8")
        self.assertIn("runtime-version: '6.11'", manifest)
        self.assertNotIn("--filesystem=host", manifest)
        self.assertNotIn("--share=network", manifest)

    def test_tomli_fallback_version_license_and_python38_grammar(self):
        vendor = ROOT / "backend/vendor"
        self.assertIn('__version__ = "2.5.0"', (vendor / "tomli/__init__.py").read_text())
        self.assertTrue((vendor / "tomli-2.5.0.dist-info/licenses/LICENSE").is_file())
        for path in (vendor / "tomli").glob("*.py"):
            ast.parse(path.read_text(), feature_version=8)
        for path in ("scripts/stage-decky-runtime.py", "desktop-control/shared-service-install.sh"):
            source = (ROOT / path).read_text()
            self.assertIn("tomli-2.5.0.dist-info", source)
            self.assertNotIn("tomli-2.0.1.dist-info", source)

    def run_toolchain(self, root, node_major="26", download=False):
        home = root / "home"
        bindir = root / "bin"
        private = home / ".local/share/bc250-control/toolchain"
        private.mkdir(parents=True)
        bindir.mkdir()
        user_pnpm = home / "user-pnpm"
        user_pnpm.mkdir()
        (user_pnpm / "pnpm").write_text("user-owned pnpm\n", encoding="utf-8")
        (home / ".bashrc").write_text("user shell settings\n", encoding="utf-8")
        workspace = root / "pnpm-workspace.yaml"
        workspace.write_text("user workspace settings\n", encoding="utf-8")
        functions = root / "installer-functions.sh"
        functions.write_text(INSTALLER.split('\ncase "${1:-install}" in\n')[0], encoding="utf-8")

        def executable(path, source):
            path.write_text("#!/bin/bash\n" + source, encoding="utf-8")
            path.chmod(0o755)

        executable(bindir / "node", "exit {}\n".format(0 if node_major == "26" else 1))
        # If the installer tries a download, the stub supplies invalid bytes offline.
        executable(bindir / "curl", 'while (($#)); do\n  if [[ "$1" == --output ]]; then printf invalid > "$2"; exit 0; fi\n  shift\ndone\nexit 1\n')
        if not download:
            executable(
                private / "pnpm",
                'printf "%s\\n" "$*" >> "$HOME/pnpm-calls"\n'
                'if [[ "$1" == --version ]]; then echo 12.21.0; fi\n'
                'if [[ "$*" == *"runtime set node"* ]]; then\n'
                '  mkdir -p "$PNPM_HOME/bin"\n'
                '  printf "#!/bin/sh\\nexit 0\\n" > "$PNPM_HOME/bin/node"\n'
                '  chmod +x "$PNPM_HOME/bin/node"\n'
                'fi\n',
            )
        environment = os.environ.copy()
        environment.update(HOME=str(home), PNPM_HOME=str(user_pnpm), PATH=str(bindir) + ":" + environment["PATH"])
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; SRC_DIR=$2; ensure_build_toolchain; pnpm_build install --frozen-lockfile',
             "test", str(functions), str(ROOT / "decky-plugin")],
            cwd=str(root), env=environment, text=True, capture_output=True,
        )
        self.assertEqual((user_pnpm / "pnpm").read_text(encoding="utf-8"), "user-owned pnpm\n")
        self.assertEqual((home / ".bashrc").read_text(encoding="utf-8"), "user shell settings\n")
        self.assertEqual(workspace.read_text(encoding="utf-8"), "user workspace settings\n")
        return result, home, private

    def test_installer_reuses_private_pnpm_without_touching_user_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, home, _ = self.run_toolchain(Path(temporary))
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (home / "pnpm-calls").read_text(encoding="utf-8")
            self.assertIn("--ignore-workspace --config.minimumReleaseAgeExclude[]=", calls)
            self.assertIn(" install --frozen-lockfile\n", calls)
            self.assertNotIn("runtime set", calls)

    def test_installer_replaces_eol_node_only_in_private_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, home, private = self.run_toolchain(Path(temporary), node_major="20")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--ignore-workspace runtime set node 26 -g\n", (home / "pnpm-calls").read_text(encoding="utf-8"))
            self.assertTrue((private / "bin/node").is_file())

    def test_installer_rejects_unverified_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, _, private = self.run_toolchain(Path(temporary), download=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pnpm download checksum mismatch", result.stderr)
            self.assertFalse((private / "pnpm").exists())
            self.assertEqual(list(private.glob(".pnpm-download.*")), [])

    def test_loader_upgrade_preserves_unknown_newer_and_prerelease_installs(self):
        for version, upgrade in (
            ("v3.2.8", True), ("v3.3.0", True), ("v3.3.1", False),
            ("v3.4.0", False), ("v3.3.1-pre1", False), ("custom", False), ("", False),
        ):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                services = root / "homebrew/services"
                services.mkdir(parents=True)
                (services / ".loader.version").write_text(version)
                functions = root / "functions.sh"
                functions.write_text(INSTALLER.split('\ncase "${1:-install}" in\n')[0])
                result = subprocess.run(
                    ["bash", "-c",
                     'source "$1"; decky_loader_installed() { return 0; }; '
                     'DECKY_INSTALLER_SHA256=$(printf fixture | sha256sum | cut -d" " -f1); '
                     'curl() { while (($#)); do if [[ "$1" == --output ]]; then '
                     'printf fixture > "$2"; return; fi; shift; done; return 1; }; '
                     'sudo() { [[ "$1" == bash && -f "$2" ]] || return 1; '
                     'touch "$HOME/upgraded"; }; ensure_decky_loader',
                     "_", str(functions)],
                    env={**os.environ, "HOME": str(root)},
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((root / "upgraded").exists(), upgrade)


if __name__ == "__main__":
    unittest.main()
