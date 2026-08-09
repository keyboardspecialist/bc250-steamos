import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MESH = ROOT / "bc250-mesh-shader.sh"
UPSTREAM_COMMIT = "d3e6dc062c34d2523db0abe5741d1f5b0dea00d9"


class MeshShaderTests(unittest.TestCase):
    def environment(self, root: Path):
        home = root / "home"
        state = home / ".local" / "share" / "bc250-mesh-shader"
        bindir = root / "bin"
        bindir.mkdir()
        for name, source in {
            "sudo": '#!/bin/sh\nexec "$@"\n',
            "flock": "#!/bin/sh\nexit 0\n",
            "sync": "#!/bin/sh\nexit 0\n",
            "journalctl": "#!/bin/sh\necho 'GFX1013/BC-250: PASID-only CPU type-0 invalidation'\n",
        }.items():
            path = bindir / name
            path.write_text(source, encoding="utf-8")
            path.chmod(0o755)
        install = bindir / "install"
        install.write_text(
            "#!/bin/sh\n"
            "while [ $# -gt 2 ]; do\n"
            "  case \"$1\" in -o|-g|-m) shift 2 ;; *) break ;; esac\n"
            "done\n"
            "cp \"$1\" \"$2\"\n",
            encoding="utf-8",
        )
        install.chmod(0o755)
        systemctl = bindir / "systemctl"
        systemctl.write_text(
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = --user ] && [ \"${2:-}\" = show-environment ]; then\n"
            "  [ \"${BC250_TEST_MANAGER_INACTIVE:-0}\" = 0 ] || exit 0\n"
            "  [ -f \"$BC250_GFX1013_GENERATOR\" ] || exit 0\n"
            "  printf 'VK_DRIVER_FILES=%s:%s\\n' \"$BC250_MESH_ICD\" \"$BC250_MESH_32BIT_ICD\"\n"
            "  printf 'VK_ICD_FILENAMES=%s:%s\\n' \"$BC250_MESH_ICD\" \"$BC250_MESH_32BIT_ICD\"\n"
            "fi\n",
            encoding="utf-8",
        )
        systemctl.chmod(0o755)
        sha256sum = bindir / "sha256sum"
        sha256sum.write_text(
            '#!/bin/sh\nexec shasum -a 256 "$@"\n', encoding="utf-8"
        )
        sha256sum.chmod(0o755)
        module = root / "modules" / "amdgpu.ko.zst"
        marker = root / "modules" / ".bc250-gfx1013-fix"
        active = root / "modules" / "bc250_gfx1013_fix"
        return {
            **os.environ,
            "HOME": str(home),
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "BC250_MESH_STATE_DIR": str(state),
            "BC250_MESH_DRIVER": str(root / "libvulkan_radeon_driconf.so"),
            "BC250_MESH_ICD": str(home / "radeon_driconf_icd.x86_64.json"),
            "BC250_MESH_32BIT_ICD": str(root / "radeon_icd.i686.json"),
            "BC250_MESH_DRIRC": str(home / ".drirc"),
            "BC250_GFX1013_GENERATOR": str(
                home
                / ".config/systemd/user-environment-generators/60-bc250-gfx1013"
            ),
            "BC250_GFX1013_MODULE": str(module),
            "BC250_GFX1013_MARKER": str(marker),
            "BC250_GFX1013_ACTIVE": str(active),
        }

    def install_runtime(self, env, commit=UPSTREAM_COMMIT):
        driver = Path(env["BC250_MESH_DRIVER"])
        icd = Path(env["BC250_MESH_ICD"])
        state = Path(env["BC250_MESH_STATE_DIR"])
        module = Path(env["BC250_GFX1013_MODULE"])
        marker = Path(env["BC250_GFX1013_MARKER"])
        active = Path(env["BC250_GFX1013_ACTIVE"])
        generator = Path(env["BC250_GFX1013_GENERATOR"])
        fallback_icd = Path(env["BC250_MESH_32BIT_ICD"])
        fallback_driver = fallback_icd.parent / "libvulkan_radeon.i686.so"
        for path in (driver, icd, module, active, generator):
            path.parent.mkdir(parents=True, exist_ok=True)
        state.mkdir(parents=True, exist_ok=True)
        module.write_bytes(b"patched amdgpu\n")
        marker.write_text(
            hashlib.sha256(module.read_bytes()).hexdigest() + "\n",
            encoding="ascii",
        )
        active.write_text(UPSTREAM_COMMIT + "\n", encoding="ascii")
        driver.write_bytes(b"driver\n")
        fallback_driver.write_bytes(b"\x7fELF\x01stock 32-bit driver\n")
        fallback_icd.write_text(
            json.dumps(
                {
                    "file_format_version": "1.0.1",
                    "ICD": {
                        "library_path": str(fallback_driver),
                        "api_version": "1.4.330",
                        "library_arch": "32",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        icd.write_text(
            '{"file_format_version": "1.0.1", "ICD": '
            '{"library_path": "%s", "library_arch": "64"}}\n' % driver,
            encoding="utf-8",
        )
        subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; output=$2; set -- help; source "$script" >/dev/null; render_generator > "$output"',
                "_",
                str(MESH),
                str(generator),
            ],
            check=True,
            env=env,
        )
        generator.chmod(0o755)
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        (state / "install.conf").write_text(
            f"{digest(driver)} {digest(icd)} mesa-26.2.0-rc3 {commit}\n",
            encoding="ascii",
        )
        driver_files = f'{icd}:{env["BC250_MESH_32BIT_ICD"]}'
        env["VK_DRIVER_FILES"] = driver_files
        env["VK_ICD_FILENAMES"] = driver_files

    def install_legacy_runtime(self, env):
        self.install_runtime(env)
        icd = Path(env["BC250_MESH_ICD"])
        driver = Path(env["BC250_MESH_DRIVER"])
        state = Path(env["BC250_MESH_STATE_DIR"])
        generator = Path(env["BC250_GFX1013_GENERATOR"])
        icd.write_text(
            '{\n  "file_format_version": "1.0.0",\n'
            '  "ICD": {"library_path": "%s", "api_version": "1.4.309"}\n}\n'
            % driver,
            encoding="utf-8",
        )
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        (state / "install.conf").write_text(
            f"{digest(driver)} {digest(icd)} mesa-26.2.0-rc3 {UPSTREAM_COMMIT}\n",
            encoding="ascii",
        )
        subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; output=$2; set -- help; source "$script" >/dev/null; '
                'render_legacy_generator > "$output"',
                "_",
                str(MESH),
                str(generator),
            ],
            check=True,
            env=env,
        )
        generator.chmod(0o755)
        env["VK_DRIVER_FILES"] = str(icd)
        env["VK_ICD_FILENAMES"] = str(icd)

    def run_status_json(self, env):
        result = subprocess.run(
            ["bash", str(MESH), "status-json"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        return json.loads(result.stdout)

    def test_status_is_read_only_when_not_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            result = subprocess.run(
                ["bash", str(MESH), "status"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("not installed", result.stdout)
            self.assertFalse(Path(env["BC250_MESH_STATE_DIR"]).exists())
            self.assertFalse(Path(env["BC250_GFX1013_GENERATOR"]).exists())

    def test_status_json_reports_global_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            status = self.run_status_json(env)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertEqual(status["mesaVersion"], "mesa-26.2.0-rc3")
            self.assertTrue(status["kernelReady"])
            self.assertTrue(status["globalEnabled"])
            self.assertFalse(status["restartRequired"])
            self.assertEqual(status["games"], [])
            generated = subprocess.run(
                ["bash", env["BC250_GFX1013_GENERATOR"]],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn("VK_DRIVER_FILES=", generated.stdout)
            self.assertIn("VK_ICD_FILENAMES=", generated.stdout)
            self.assertIn(env["BC250_MESH_32BIT_ICD"], generated.stdout)

    def test_missing_32bit_fallback_invalidates_global_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            Path(env["BC250_MESH_32BIT_ICD"]).unlink()
            status = self.run_status_json(env)
            self.assertEqual(status["runtimeState"], "invalid")
            generated = subprocess.run(
                ["bash", env["BC250_GFX1013_GENERATOR"]],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(generated.stdout, "")

    def test_non_32bit_fallback_invalidates_global_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            fallback = Path(env["BC250_MESH_32BIT_ICD"])
            fallback.write_text(
                fallback.read_text(encoding="utf-8").replace('"32"', '"64"'),
                encoding="utf-8",
            )
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")

    def test_generator_rejects_unqualified_64bit_icd(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            icd = Path(env["BC250_MESH_ICD"])
            icd.write_text(
                icd.read_text(encoding="utf-8").replace(
                    ', "library_arch": "64"', ""
                ),
                encoding="utf-8",
            )
            state = Path(env["BC250_MESH_STATE_DIR"])
            driver = Path(env["BC250_MESH_DRIVER"])
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (state / "install.conf").write_text(
                f"{digest(driver)} {digest(icd)} mesa-26.2.0-rc3 {UPSTREAM_COMMIT}\n",
                encoding="ascii",
            )
            generated = subprocess.run(
                ["bash", env["BC250_GFX1013_GENERATOR"]],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")
            self.assertEqual(generated.stdout, "")

    def test_global_activation_stops_when_kernel_gate_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            Path(env["BC250_GFX1013_MARKER"]).unlink()
            status = self.run_status_json(env)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertFalse(status["kernelReady"])
            self.assertFalse(status["globalEnabled"])
            self.assertFalse(status["restartRequired"])
            generated = subprocess.run(
                ["bash", env["BC250_GFX1013_GENERATOR"]],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(generated.stdout, "")

    def test_configured_runtime_requires_new_session_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            env["BC250_TEST_MANAGER_INACTIVE"] = "1"
            status = self.run_status_json(env)
            self.assertFalse(status["globalEnabled"])
            self.assertTrue(status["restartRequired"])

    def test_legacy_runtime_requires_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env, "b66203e012594204e5e3049856b28a2681112985")
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")

    def test_previous_global_runtime_can_be_uninstalled(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_legacy_runtime(env)
            result = subprocess.run(
                ["bash", str(MESH), "uninstall"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(env["BC250_MESH_DRIVER"]).exists())
            self.assertFalse(Path(env["BC250_MESH_ICD"]).exists())
            self.assertFalse(Path(env["BC250_GFX1013_GENERATOR"]).exists())

    def test_previous_global_runtime_passes_setup_ownership_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_legacy_runtime(env)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "preflight_runtime_ownership",
                    "_",
                    str(MESH),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_previous_generator_still_fails_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_legacy_runtime(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            generator.write_text(
                generator.read_text(encoding="utf-8") + "echo tampered\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "preflight_runtime_ownership",
                    "_",
                    str(MESH),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a recorded toolkit install", result.stderr)

    def test_tampered_generator_invalidates_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            Path(env["BC250_GFX1013_GENERATOR"]).write_text(
                "#!/bin/sh\necho unsafe\n", encoding="utf-8"
            )
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")

    def test_generator_rejects_tampered_runtime_attestations(self):
        for target in ("driver", "icd", "manifest", "active"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                paths = {
                    "driver": Path(env["BC250_MESH_DRIVER"]),
                    "icd": Path(env["BC250_MESH_ICD"]),
                    "manifest": Path(env["BC250_MESH_STATE_DIR"]) / "install.conf",
                    "active": Path(env["BC250_GFX1013_ACTIVE"]),
                }
                paths[target].write_text("tampered\n", encoding="utf-8")
                generated = subprocess.run(
                    ["bash", env["BC250_GFX1013_GENERATOR"]],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(generated.stdout, "")

    def test_per_game_commands_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            result = subprocess.run(
                ["bash", str(MESH), "game", "enable", "game.exe"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("global", result.stderr)

    def test_uninstall_removes_global_runtime_and_legacy_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            drirc = Path(env["BC250_MESH_DRIRC"])
            drirc.write_text(
                "<driconf>\n<!-- BEGIN BC250 MESH SHADER MANAGED -->\n"
                '<device driver="radv"><application name="Old" executable="old.exe" /></device>\n'
                "<!-- END BC250 MESH SHADER MANAGED -->\n</driconf>\n",
                encoding="utf-8",
            )
            blocked = subprocess.run(
                ["bash", str(MESH), "uninstall"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("legacy-clear", blocked.stderr)
            subprocess.run(
                ["bash", str(MESH), "legacy-clear"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            subprocess.run(
                ["bash", str(MESH), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertFalse(Path(env["BC250_MESH_DRIVER"]).exists())
            self.assertFalse(Path(env["BC250_MESH_ICD"]).exists())
            self.assertFalse(Path(env["BC250_GFX1013_GENERATOR"]).exists())
            self.assertNotIn("BC250 MESH SHADER MANAGED", drirc.read_text())

    def test_uninstall_recovers_generator_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            transaction = state / "install-transaction"
            transaction.mkdir()
            originals = {
                "driver": Path(env["BC250_MESH_DRIVER"]),
                "icd": Path(env["BC250_MESH_ICD"]),
                "manifest": state / "install.conf",
                "generator": Path(env["BC250_GFX1013_GENERATOR"]),
            }
            hashes = []
            for name, source in originals.items():
                backup = transaction / name
                backup.write_bytes(source.read_bytes())
                hashes.append(hashlib.sha256(backup.read_bytes()).hexdigest())
                source.write_text("interrupted\n", encoding="utf-8")
            (transaction / "transaction.conf").write_text(
                "2 1 %s 1 %s 1 %s 1 %s\n" % tuple(hashes),
                encoding="ascii",
            )

            subprocess.run(
                ["bash", str(MESH), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertFalse(transaction.exists())
            self.assertFalse(Path(env["BC250_GFX1013_GENERATOR"]).exists())

    def test_script_parses_and_menu_is_global(self):
        subprocess.run(["bash", "-n", str(MESH)], check=True)
        source = MESH.read_text(encoding="utf-8")
        self.assertIn("menu_select()", source)
        self.assertIn("global user RADV", source)
        self.assertNotIn("Enable one executable|", source)
        self.assertIn("DryhoppedIPA/bc250-gfx1013-fix", source)
        self.assertIn("/usr/lib/systemd/user-environment-generators", source)

    def test_setup_force_reinstalls_development_metadata_packages(self):
        source = MESH.read_text(encoding="utf-8")
        package_block = source.split("local development_packages=(", 1)[1].split(
            ")", 1
        )[0]
        for package in (
            "glibc",
            "linux-api-headers",
            "libdrm",
            "libffi",
            "libxau",
            "libxdmcp",
            "xorgproto",
            "libxcb",
            "wayland",
        ):
            self.assertIn(package, package_block.split())
        self.assertIn(
            'pacman -S --noconfirm "${development_packages[@]}"', source
        )
        self.assertIn("python-mako python-packaging python-yaml", source)
        self.assertEqual(source.count("import mako, packaging, yaml"), 2)
        self.assertEqual(source.count("#include <errno.h>"), 2)
        self.assertIn('LIBDRM_TARBALL="libdrm-2.4.133.tar.xz"', source)
        self.assertIn(
            'fetch_verified "$LIBDRM_TARBALL" "$LIBDRM_SHA256" "$LIBDRM_URL"',
            source,
        )
        self.assertIn('"$source/subprojects/packagecache/"', source)
        self.assertIn("-Dallow-fallback-for=libdrm", source)
        self.assertIn("-Dlibdrm:default_library=static", source)
        self.assertIn("-Dbuildtype=release", source)


if __name__ == "__main__":
    unittest.main()
