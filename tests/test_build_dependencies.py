#!/usr/bin/env python3
"""Offline build-toolchain contracts; never install into the real home directory."""

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
    def test_installer_and_ci_share_the_pinned_toolchain(self):
        manager, version = PACKAGE["packageManager"].split("@")
        self.assertEqual(manager, "pnpm")
        self.assertEqual(version, PACKAGE["engines"]["pnpm"])
        self.assertIn('PNPM_VERSION="{}"'.format(version), INSTALLER)
        self.assertIn('NODE_MAJOR="24"', INSTALLER)
        self.assertIn('NODE_MIN_MINOR="12"', INSTALLER)
        self.assertEqual(PACKAGE["engines"]["node"], ">=24.12 <25")
        self.assertIn("pnpm_build install --frozen-lockfile", INSTALLER)
        self.assertNotIn("get.pnpm.io/install.sh", INSTALLER)
        self.assertNotIn('cat >>"$rc"', INSTALLER)
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            workflow = path.read_text(encoding="utf-8")
            with self.subTest(workflow=path.name):
                self.assertIn("package_json_file: decky-plugin/package.json", workflow)
                self.assertIn("node-version: 24", workflow)
                self.assertIn("pnpm --ignore-workspace install --frozen-lockfile", workflow)
                self.assertNotRegex(workflow, r"pnpm (install|run) ")
                for action, version in (
                    ("actions/checkout", "v7.0.1"),
                    ("actions/setup-python", "v7.0.0"),
                    ("actions/setup-node", "v7.1.0"),
                    ("actions/upload-artifact", "v7.0.2"),
                    ("pnpm/action-setup", "v6.1.0"),
                ):
                    for actual in re.findall(re.escape(action) + r"@(\S+)", workflow):
                        self.assertEqual(actual, version)

    def test_lock_uses_compatible_compiler_and_maintenance_security_fixes(self):
        lock = (ROOT / "decky-plugin/pnpm-lock.yaml").read_text(encoding="utf-8")
        self.assertTrue(lock.startswith("lockfileVersion: '9.0'\n"))
        # @decky/rollup 1.0.2 needs the pre-native TypeScript compiler API.
        self.assertEqual(PACKAGE["devDependencies"]["typescript"], "~5.9.3")
        self.assertEqual(set(re.findall(r"^  typescript@([^:]+):", lock, re.M)), {"5.9.3"})
        self.assertEqual(
            set(re.findall(r"^  brace-expansion@([^:]+):", lock, re.M)),
            {"1.1.21", "2.1.7"},
        )
        # No forced major upgrade or audit suppression for the unfixed braces advisory.
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

    def run_toolchain(self, root, node_major="24", download=False):
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

        executable(bindir / "node", "exit {}\n".format(0 if node_major == "24" else 1))
        # If the installer tries a download, the stub supplies invalid bytes offline.
        executable(bindir / "curl", 'while (($#)); do\n  if [[ "$1" == --output ]]; then printf invalid > "$2"; exit 0; fi\n  shift\ndone\nexit 1\n')
        if not download:
            executable(
                private / "pnpm",
                'printf "%s\\n" "$*" >> "$HOME/pnpm-calls"\n'
                'if [[ "$1" == --version ]]; then echo 9.15.9; fi\n'
                'if [[ "$1" == env ]]; then\n'
                '  printf "#!/bin/sh\\nexit 0\\n" > "$PNPM_HOME/node"\n'
                '  chmod +x "$PNPM_HOME/node"\n'
                'fi\n',
            )
        environment = os.environ.copy()
        environment.update(HOME=str(home), PNPM_HOME=str(user_pnpm), PATH=str(bindir) + ":" + environment["PATH"])
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; ensure_build_toolchain; pnpm_build install --frozen-lockfile', "test", str(functions)],
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
            self.assertIn("--ignore-workspace install --frozen-lockfile\n", calls)
            self.assertNotIn("env use", calls)

    def test_installer_replaces_eol_node_only_in_private_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, home, private = self.run_toolchain(Path(temporary), node_major="20")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("env use --global 24\n", (home / "pnpm-calls").read_text(encoding="utf-8"))
            self.assertTrue((private / "node").is_file())

    def test_installer_rejects_unverified_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, _, private = self.run_toolchain(Path(temporary), download=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pnpm download checksum mismatch", result.stderr)
            self.assertFalse((private / "pnpm").exists())
            self.assertEqual(list(private.glob(".pnpm-download.*")), [])


if __name__ == "__main__":
    unittest.main()
