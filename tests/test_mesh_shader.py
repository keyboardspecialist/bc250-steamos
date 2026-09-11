import hashlib
import json
import os
import struct
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MESH = ROOT / "bc250-mesh-shader.sh"
FSR4 = ROOT / "bc250-fsr4.sh"
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
            "modinfo": '#!/bin/sh\nprintf "%s\\n" "$BC250_GFX1013_MODULE"\n',
            "stat": '#!/bin/sh\n[ "$2" = %u ] && { echo 0; exit; }\n[ "$2" = %a ] && { echo 644; exit; }\nexec /usr/bin/stat "$@"\n',
            "steamos-readonly": '#!/bin/sh\n[ "$1" != status ] || echo disabled\n',
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
        audio_marker = root / "modules" / ".bc250-audio-fix"
        metrics_marker = root / "modules" / ".bc250-metrics-fix"
        active = root / "modules" / "bc250_gfx1013_fix"
        policy = root / "modules" / "sched_policy"
        boot_config = root / "boot-config.sh"
        boot_config.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  configured) [ \"${BC250_TEST_POLICY_CONFIGURED:-1}\" = 1 ] ;;\n"
            "  present|policy-present) [ \"${BC250_TEST_POLICY_CONFIGURED:-1}\" = 1 ] ;;\n"
            "  active) [ -r \"$BC250_SCHED_POLICY_PARAM\" ] && [ \"$(cat \"$BC250_SCHED_POLICY_PARAM\")\" = 2 ] ;;\n"
            "  install|remove|policy-remove) exit 0 ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        boot_config.chmod(0o755)
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
            "BC250_AUDIO_MARKER": str(audio_marker),
            "BC250_METRICS_MARKER": str(metrics_marker),
            "BC250_GFX1013_ACTIVE": str(active),
            "BC250_SCHED_POLICY_PARAM": str(policy),
            "BC250_AMDGPU_BOOT_CONFIG": str(boot_config),
        }

    def install_runtime(self, env, commit=UPSTREAM_COMMIT):
        driver = Path(env["BC250_MESH_DRIVER"])
        icd = Path(env["BC250_MESH_ICD"])
        state = Path(env["BC250_MESH_STATE_DIR"])
        module = Path(env["BC250_GFX1013_MODULE"])
        marker = Path(env["BC250_GFX1013_MARKER"])
        audio_marker = Path(env["BC250_AUDIO_MARKER"])
        metrics_marker = Path(env["BC250_METRICS_MARKER"])
        active = Path(env["BC250_GFX1013_ACTIVE"])
        policy = Path(env["BC250_SCHED_POLICY_PARAM"])
        generator = Path(env["BC250_GFX1013_GENERATOR"])
        fallback_icd = Path(env["BC250_MESH_32BIT_ICD"])
        fallback_driver = fallback_icd.parent / "libvulkan_radeon.i686.so"
        for path in (driver, icd, module, active, policy, generator):
            path.parent.mkdir(parents=True, exist_ok=True)
        state.mkdir(parents=True, exist_ok=True)
        module.write_bytes(b"patched amdgpu\n")
        module_hash = hashlib.sha256(module.read_bytes()).hexdigest() + "\n"
        for path in (marker, audio_marker, metrics_marker):
            path.write_text(module_hash, encoding="ascii")
        active.write_text(UPSTREAM_COMMIT + "\n", encoding="ascii")
        policy.write_text("2\n", encoding="ascii")
        driver.write_bytes(b"driver\n")
        fallback_elf = bytearray(52 + 2 * 32)
        fallback_elf[:7] = b"\x7fELF\x01\x01\x01"
        struct.pack_into("<HHI", fallback_elf, 16, 3, 3, 1)
        struct.pack_into("<I", fallback_elf, 28, 52)
        struct.pack_into("<HHH", fallback_elf, 40, 52, 32, 2)
        struct.pack_into("<I", fallback_elf, 52, 1)
        struct.pack_into("<I", fallback_elf, 84, 2)
        fallback_driver.write_bytes(fallback_elf)
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
            f"{digest(driver)} {digest(icd)} mesa-26.2.0 {commit} compute-only-v2\n",
            encoding="ascii",
        )
        driver_files = f'{icd}:{env["BC250_MESH_32BIT_ICD"]}'
        env["VK_DRIVER_FILES"] = driver_files
        env["VK_ICD_FILENAMES"] = driver_files

    def install_fsr4_runtime(self, env):
        state = Path(env["BC250_MESH_STATE_DIR"])
        profile = state / "fsr4"
        profile.mkdir(parents=True)
        driver = profile / "libvulkan_radeon.so"
        icd = profile / "radeon_fsr4_icd.x86_64.json"
        runner = profile / "bc250-fsr4-run"
        driver.write_bytes(b"fsr4 driver\n")
        icd.write_text(
            '{"file_format_version":"1.0.1","ICD":'
            '{"library_path": "%s", "library_arch": "64"}}\n' % driver,
            encoding="utf-8",
        )
        subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; output=$2; set -- help; source "$script" >/dev/null; '
                'render_fsr4_runner > "$output"',
                "_",
                str(MESH),
                str(runner),
            ],
            check=True,
            env=env,
        )
        runner.chmod(0o755)
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        profile_digest = "835842eb8beccd6e0498a771c5ea4d8c9ac86ee994e4659045e9f3bf4321404d"
        (profile / "install.conf").write_text(
            f"{digest(driver)} {digest(icd)} {digest(runner)} mesa-26.2.0 {profile_digest}\n",
            encoding="ascii",
        )

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
            f"{digest(driver)} {digest(icd)} mesa-26.2.0 {UPSTREAM_COMMIT}\n",
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
            self.assertEqual(status["mesaVersion"], "mesa-26.2.0")
            self.assertEqual(status["fsr4State"], "not-installed")
            self.assertEqual(status["fsr4DllState"], "not-installed")
            self.assertEqual(status["fsr4DllInstallCount"], 0)
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
                f"{digest(driver)} {digest(icd)} mesa-26.2.0 {UPSTREAM_COMMIT} compute-only-v2\n",
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

    def test_global_activation_requires_every_module_attestation(self):
        for key in ("BC250_AUDIO_MARKER", "BC250_METRICS_MARKER"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                Path(env[key]).unlink()
                status = self.run_status_json(env)
                self.assertFalse(status["kernelReady"])
                generated = subprocess.run(
                    ["bash", env["BC250_GFX1013_GENERATOR"]],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(generated.stdout, "")

    def test_global_activation_stops_when_scheduler_policy_is_inactive(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            Path(env["BC250_SCHED_POLICY_PARAM"]).write_text("0\n", encoding="ascii")
            status = self.run_status_json(env)
            self.assertTrue(status["kernelReady"])
            self.assertFalse(status["schedulerActive"])
            self.assertFalse(status["globalEnabled"])
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

    def test_unconfigured_runtime_does_not_report_restart_required(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            env["BC250_TEST_POLICY_CONFIGURED"] = "0"
            env["BC250_TEST_MANAGER_INACTIVE"] = "1"
            status = self.run_status_json(env)
            self.assertFalse(status["schedulerConfigured"])
            self.assertFalse(status["restartRequired"])

    def test_legacy_runtime_requires_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env, "b66203e012594204e5e3049856b28a2681112985")
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")

    def test_previous_patch_composition_requires_upgrade_but_remains_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            manifest = state / "install.conf"
            manifest.write_text(
                " ".join(manifest.read_text(encoding="ascii").split()[:4]) + "\n",
                encoding="ascii",
            )
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; output=$2; set -- help; source "$script" >/dev/null; '
                    'render_previous_generator > "$output"; chmod 755 "$output"',
                    "_",
                    str(MESH),
                    env["BC250_GFX1013_GENERATOR"],
                ],
                check=True,
                env=env,
            )
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")
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

    def test_private_fsr4_profile_is_attested_and_not_global(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            status = self.run_status_json(env)
            self.assertEqual(status["fsr4State"], "ready")
            self.assertTrue(status["globalEnabled"])
            self.assertNotIn(status["fsr4IcdPath"], env["VK_DRIVER_FILES"])
            default_driver = Path(env["BC250_MESH_DRIVER"])
            fsr4_driver = (
                Path(env["BC250_MESH_STATE_DIR"]) / "fsr4/libvulkan_radeon.so"
            )
            self.assertNotEqual(
                default_driver.read_bytes(), fsr4_driver.read_bytes()
            )
            self.assertEqual(
                json.loads(Path(env["BC250_MESH_ICD"]).read_text())["ICD"][
                    "library_path"
                ],
                str(default_driver),
            )
            self.assertEqual(
                json.loads(Path(status["fsr4IcdPath"]).read_text())["ICD"][
                    "library_path"
                ],
                str(fsr4_driver),
            )

            result = subprocess.run(
                [status["fsr4RunnerPath"], "sh", "-c", "printf '%s' \"$VK_DRIVER_FILES\""],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn(status["fsr4IcdPath"], result.stdout)
            self.assertIn(env["BC250_MESH_32BIT_ICD"], result.stdout)

    def test_tampered_fsr4_profile_is_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            (state / "fsr4/libvulkan_radeon.so").write_bytes(b"tampered\n")
            self.assertEqual(self.run_status_json(env)["fsr4State"], "invalid")

    def test_fsr4_runner_refuses_inactive_scheduler(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            Path(env["BC250_SCHED_POLICY_PARAM"]).write_text("0\n", encoding="ascii")
            runner = Path(env["BC250_MESH_STATE_DIR"]) / "fsr4/bc250-fsr4-run"
            result = subprocess.run(
                [str(runner), "true"], capture_output=True, text=True, env=env
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sched_policy=2", result.stderr)

    def test_uninstall_fsr4_preserves_default_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            preserved = {
                path: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (
                    Path(env["BC250_MESH_DRIVER"]),
                    Path(env["BC250_MESH_ICD"]),
                    Path(env["BC250_GFX1013_GENERATOR"]),
                    state / "install.conf",
                )
            }
            subprocess.run(
                ["bash", str(MESH), "uninstall", "--fsr4-legacy"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            status = self.run_status_json(env)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertEqual(status["fsr4State"], "not-installed")
            self.assertTrue(Path(env["BC250_MESH_DRIVER"]).exists())
            for path, expected in preserved.items():
                self.assertEqual(
                    hashlib.sha256(path.read_bytes()).hexdigest(), expected
                )

    def test_fsr4_setup_bootstraps_and_incrementally_reuses_base_build(self):
        source = MESH.read_text(encoding="utf-8")
        setup = source.split("cmd_setup() (", 1)[1].split(
            "\n)\n\nmanage_games", 1
        )[0]
        ninja = 'ninja -C "$build" src/amd/vulkan/libvulkan_radeon.so'
        first_ninja = setup.index(ninja)
        fsr4_patch = setup.index(
            'patch -d "$source" -p1 --fuzz=0 -i "$FSR4_PATCH"'
        )
        reverse_base = setup.index(
            'patch -d "$source" -R -p1 --fuzz=0 --dry-run'
        )
        second_ninja = setup.index(ninja, first_ninja + len(ninja))

        self.assertLess(first_ninja, fsr4_patch)
        self.assertLess(reverse_base, fsr4_patch)
        self.assertLess(fsr4_patch, second_ninja)
        self.assertEqual(setup.count('meson setup "$build" "$source"'), 1)
        self.assertIn('source="$MESA_SOURCE"', setup)
        self.assertNotIn('${source}-fsr4', setup)
        self.assertIn(
            "legacy FSR4 V3 setup will install it first",
            setup,
        )
        self.assertIn('install_default_profile "$base_output" "$mesa_tag"', setup)
        self.assertIn("write_build_state base", setup)
        self.assertIn("write_build_state fsr4", setup)
        self.assertNotIn(
            "Install and validate the default Mesa / RADV profile before adding FSR4.",
            setup,
        )

    def test_async_setup_reuses_verified_fsr4_bootstrap_without_building(self):
        source = MESH.read_text(encoding="utf-8")
        setup = source.split("cmd_setup() (", 1)[1].split(
            "\n)\n\nmanage_games", 1
        )[0]
        guard = 'if [[ "$profile" == default ]] && verify_current_runtime; then'
        guard_index = setup.index(guard)
        message_index = setup.index(
            "already installed and verified; no Mesa rebuild is needed",
            guard_index,
        )
        return_index = setup.index("return 0", message_index)

        self.assertLess(return_index, setup.index('command -v curl', guard_index))
        self.assertLess(return_index, setup.index('work=$(mktemp', guard_index))
        self.assertLess(return_index, setup.index("stage_upstream", guard_index))
        self.assertIn("verify_scheduler_configured", setup[guard_index:return_index])
        self.assertIn("verify_scheduler_active", setup[guard_index:return_index])
        self.assertIn("report_fsr4_preserved", setup[guard_index:return_index])
        default_install = setup.index('install_default_profile "$output" "$mesa_tag"')
        preserve = setup.index("report_fsr4_preserved", default_install)
        self.assertLess(default_install, preserve)
        self.assertLess(preserve, setup.index("return 0", preserve))

    def test_fsr4_preservation_report_does_not_modify_private_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            profile = Path(env["BC250_MESH_STATE_DIR"]) / "fsr4"
            before = {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in profile.iterdir()
            }
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "report_fsr4_preserved",
                    "_",
                    str(MESH),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            after = {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in profile.iterdir()
            }
            self.assertEqual(after, before)
            self.assertIn("remains installed and verified", result.stdout)

    def test_recovery_keeps_a_verified_new_fsr4_profile(self):
        for had_previous, global_ready, current_metadata in (
            (0, True, True),
            (1, True, True),
            (0, False, True),
            (1, False, True),
            (0, False, False),
            (1, False, False),
        ):
            with self.subTest(
                had_previous=had_previous,
                global_ready=global_ready,
                current_metadata=current_metadata,
            ), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                self.install_fsr4_runtime(env)
                if not global_ready:
                    Path(env["BC250_MESH_DRIVER"]).unlink()
                state = Path(env["BC250_MESH_STATE_DIR"])
                profile = state / "fsr4"
                if not current_metadata:
                    manifest = profile / "install.conf"
                    fields = manifest.read_text(encoding="ascii").split()
                    fields[-1] = "0" * 64
                    manifest.write_text(" ".join(fields) + "\n", encoding="ascii")
                transaction = state / "fsr4-install-transaction"
                transaction.mkdir()
                if had_previous:
                    previous = transaction / "previous"
                    previous.mkdir()
                    (previous / "obsolete").write_bytes(b"old profile\n")
                (transaction / "transaction.conf").write_text(
                    f"swapping {had_previous}\n", encoding="ascii"
                )
                before = {
                    path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in profile.iterdir()
                }

                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        'script=$1; set -- help; source "$script" >/dev/null; '
                        "recover_fsr4_install_transaction",
                        "_",
                        str(MESH),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )

                after = {
                    path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in profile.iterdir()
                }
                self.assertEqual(after, before)
                self.assertFalse(transaction.exists())
                self.assertIn("intact FSR4 profile", result.stdout)

    def test_incremental_build_state_rejects_source_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            source = root / "mesa"
            build = source / "build/src/amd/vulkan"
            source.mkdir()
            tracked = source / "tracked.c"
            tracked.write_text("int value = 1;\n", encoding="ascii")
            (source / ".gitignore").write_text(
                "/build/\n/ignored-input\n", encoding="ascii"
            )
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(
                ["git", "-C", str(source), "add", "tracked.c", ".gitignore"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "user.name=BC250 Tests",
                    "-c",
                    "user.email=tests@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
            )
            build.mkdir(parents=True)
            output = build / "libvulkan_radeon.so"
            output.write_bytes(b"cached driver\n")
            cached_object = source / "build/cached-object.o"
            cached_object.write_bytes(b"cached object\n")
            ignored_input = source / "ignored-input"
            ignored_input.write_bytes(b"fallback source\n")
            ninja_file = source / "build/build.ninja"
            ninja_file.write_text("# generated build graph\n", encoding="ascii")
            coredata = source / "build/meson-private/coredata.dat"
            coredata.parent.mkdir()
            coredata.write_bytes(b"meson core data\n")
            state = root / "mesa.profile"
            command = (
                'script=$1; source_dir=$2; build_dir=$3; output=$4; state=$5; '
                'set -- help; source "$script" >/dev/null; '
                'MESA_SOURCE=$source_dir; MESA_BUILD=$build_dir; '
                'MESA_OUTPUT=$output; BUILD_STATE=$state; BUILD_ROOT=${state%/*}; '
                'MESA_NINJA=$MESA_BUILD/build.ninja; '
                'MESA_COREDATA=$MESA_BUILD/meson-private/coredata.dat; '
                'MESA_COMMIT=$(git -C "$MESA_SOURCE" rev-parse HEAD); '
                'write_build_state base; '
                'verify_cached_build base "$(sha256_file "$MESA_OUTPUT")"'
            )
            subprocess.run(
                [
                    "bash",
                    "-c",
                    command,
                    "_",
                    str(MESH),
                    str(source),
                    str(source / "build"),
                    str(output),
                    str(state),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            tracked.write_text("int value = 2;\n", encoding="ascii")
            subprocess.run(
                ["git", "-C", str(source), "add", "tracked.c"], check=True
            )
            verify = command.replace("write_build_state base; ", "")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    verify,
                    "_",
                    str(MESH),
                    str(source),
                    str(source / "build"),
                    str(output),
                    str(state),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)

            tracked.write_text("int value = 1;\n", encoding="ascii")
            subprocess.run(
                ["git", "-C", str(source), "add", "tracked.c"], check=True
            )
            ignored_input.write_bytes(b"tampered fallback source\n")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    verify,
                    "_",
                    str(MESH),
                    str(source),
                    str(source / "build"),
                    str(output),
                    str(state),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)

            ignored_input.write_bytes(b"fallback source\n")
            cached_object.write_bytes(b"tampered object\n")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    verify,
                    "_",
                    str(MESH),
                    str(source),
                    str(source / "build"),
                    str(output),
                    str(state),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)

            cached_object.write_bytes(b"cached object\n")
            ninja_file.write_text("# tampered build graph\n", encoding="ascii")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    verify,
                    "_",
                    str(MESH),
                    str(source),
                    str(source / "build"),
                    str(output),
                    str(state),
                ],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_interrupted_fsr4_replacement_restores_previous_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_fsr4_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            profile = state / "fsr4"
            transaction = state / "fsr4-install-transaction"
            transaction.mkdir()
            previous = transaction / "previous"
            previous.mkdir()
            for source in profile.iterdir():
                (previous / source.name).write_bytes(source.read_bytes())
                (previous / source.name).chmod(source.stat().st_mode)
            (transaction / "transaction.conf").write_text(
                "swapping 1\n", encoding="ascii"
            )
            (profile / "libvulkan_radeon.so").write_bytes(b"interrupted\n")
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "recover_fsr4_install_transaction",
                    "_",
                    str(MESH),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertFalse(transaction.exists())
            self.assertEqual(self.run_status_json(env)["fsr4State"], "ready")

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
        self.assertIn("Mesa / RADV async-compute patch", source)
        self.assertIn("Optional but highly recommended", source)
        self.assertIn("usually takes 3-5 minutes", source)
        self.assertIn("GFX1013 async compute", source)
        self.assertIn("require_production_kernel_paths", source)
        self.assertIn('ldd -r "$output"', source)
        self.assertIn('readelf -h "$output"', source)
        self.assertIn("undefined symbol:", source)
        self.assertIn("BC250_FORCE_GRUB_REGEN=1", source)
        self.assertIn("Reboot to deactivate it, then rerun uninstall", source)
        self.assertNotIn("20-40", source)
        self.assertNotIn("Enable one executable|", source)
        self.assertIn("DryhoppedIPA/bc250-gfx1013-fix", source)
        self.assertIn('DEFAULT_MESA_TAG="mesa-26.2.0"', source)
        self.assertIn("setup --fsr4", source)
        self.assertIn("render_fsr4_runner", source)
        self.assertIn("FSR4_PATCH_SHA256", source)
        self.assertIn("refs/heads/bc250-pinned-mesa", source)
        self.assertIn("recover_fsr4_install_transaction", source)
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

    def test_fsr4_patch_is_retained_as_pinned_legacy_v3(self):
        script = MESH.read_text(encoding="utf-8")
        self.assertIn(
            'FSR4_UPSTREAM_COMMIT="741ff3e369026f34820c41a846cf5e55d08e2a61"',
            script,
        )
        self.assertIn('FSR4_PATCH_NAME="bc250-fsr4-v3.patch"', script)
        self.assertIn(
            'FSR4_PATCH_SHA256="7fde37fad572b4ba4dcac6052792d10d8d3df65982b01236c63a3eff0a25d225"',
            script,
        )
        self.assertIn(
            'fetch_verified "$FSR4_PATCH_NAME" "$FSR4_PATCH_SHA256" "$FSR4_PATCH_URL"',
            script,
        )
        self.assertIn("grep -qF bc250_lower_dense_sdot4x8", script)
        self.assertIn("setup --fsr4-legacy", script)
        self.assertFalse(
            (ROOT / "bc250-mesa-patches/0004-gfx1013-fsr4-sdot-lowering.patch").exists()
        )

    def test_unsafe_mesh_task_patches_are_not_fetched_or_applied(self):
        script = MESH.read_text(encoding="utf-8")
        stage = script[script.index("stage_upstream() {") : script.index("verify_fsr4_patch() {")]
        setup = script[script.index("cmd_setup() (") : script.index("manage_games() {")]
        for patch in (
            "0002-gfx1013-mesh-task-shaders.patch",
            "0003-gfx1013-taskmesh-queries.patch",
        ):
            self.assertNotIn(patch, stage)
            self.assertNotIn(patch, setup)

    def test_purge_serializes_with_fsr4_dll_rollback_state(self):
        script = MESH.read_text(encoding="utf-8")
        purge = script[script.index("cmd_purge() (") : script.index("menu_select() {")]
        self.assertIn('exec 8> "$FSR4_DLL_LOCK"', purge)
        self.assertIn('flock 8', purge)
        self.assertIn('FSR4 DLL rollback state exists but its helper is unavailable', purge)

    def test_rc8_helper_is_executable_and_in_toolkit_release_glob(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        self.assertTrue(os.access(FSR4, os.X_OK))
        self.assertIn("cp README.md bc250-*.sh", workflow)

    def test_rc8_dll_install_is_pinned_transactional_and_reversible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload"
            (payload / "notices").mkdir(parents=True)
            dll = payload / "amd_fidelityfx_upscaler_dx12.dll"
            dll.write_bytes(b"MZ synthetic rc8 payload\n")
            (payload / "README.md").write_text("test release\n", encoding="utf-8")
            (payload / "notices/PROVENANCE.md").write_text(
                "test provenance\n", encoding="utf-8"
            )
            archive = root / "rc8.tar.xz"
            with tarfile.open(archive, "w:xz") as output:
                for path in sorted(payload.rglob("*")):
                    output.add(path, arcname=path.relative_to(payload))

            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            target = root / "game with spaces/OptiScaler/amd_fidelityfx_upscaler_dx12.dll"
            target.parent.mkdir(parents=True)
            original = b"MZ original game DLL\n"
            target.write_bytes(original)
            env = {
                **os.environ,
                "HOME": str(root / "home"),
                "BC250_FSR4_STATE_DIR": str(root / "state"),
                "BC250_FSR4_LOCK_FILE": str(root / "lock"),
                "BC250_FSR4_ARCHIVE": str(archive),
                "BC250_FSR4_ARCHIVE_SHA256": digest(archive),
                "BC250_FSR4_DLL_SHA256": digest(dll),
            }

            subprocess.run(
                ["bash", str(FSR4), "install", str(target)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(target.read_bytes(), dll.read_bytes())
            status = subprocess.run(
                ["bash", str(FSR4), "status"],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertIn("state: installed", status.stdout)

            target.write_bytes(b"externally changed\n")
            refused = subprocess.run(
                ["bash", str(FSR4), "uninstall", str(target)],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("changed outside the toolkit", refused.stderr)
            target.write_bytes(dll.read_bytes())
            upgrade_env = {
                **env,
                "BC250_FSR4_RELEASE": "v4.0.0-rc9",
            }
            subprocess.run(
                ["bash", str(FSR4), "install", str(target)],
                check=True,
                env=upgrade_env,
                capture_output=True,
                text=True,
            )
            upgraded = subprocess.run(
                ["bash", str(FSR4), "status"],
                check=True,
                env=upgrade_env,
                capture_output=True,
                text=True,
            )
            self.assertIn("v4.0.0-rc9", upgraded.stdout)
            future_env = {
                **upgrade_env,
                "BC250_FSR4_RELEASE": "v4.0.0-rc10",
                "BC250_FSR4_DLL_SHA256": "0" * 64,
            }
            subprocess.run(
                ["bash", str(FSR4), "uninstall", str(target)],
                check=True,
                env=future_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(list((root / "state/installs").glob("[0-9a-f]*")), [])

            source = FSR4.read_text(encoding="utf-8")
            record_commit = source.index('mv "$record_tmp" "$record"')
            record_sync = source.index('fsync_paths "$INSTALLS_DIR"', record_commit)
            target_write = source.index(
                'copy_atomic "$RELEASE_DIR/$DLL_NAME" "$REAL_TARGET"', record_sync
            )
            self.assertLess(record_commit, record_sync)
            self.assertLess(record_sync, target_write)

    def test_rc8_helper_rejects_unsafe_release_and_symlink_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad_release = subprocess.run(
                ["bash", str(FSR4), "status"],
                env={**os.environ, "BC250_FSR4_RELEASE": "../escape"},
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(bad_release.returncode, 0)
            self.assertIn("Invalid release identifier", bad_release.stderr)

            target = root / "target.dll"
            target.write_bytes(b"original\n")
            link = root / "linked.dll"
            link.symlink_to(target)
            refused = subprocess.run(
                ["bash", str(FSR4), "install", str(link)],
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "BC250_FSR4_STATE_DIR": str(root / "state"),
                    "BC250_FSR4_LOCK_FILE": str(root / "lock"),
                },
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("must not be a symlink", refused.stderr)
            self.assertEqual(target.read_bytes(), b"original\n")

            real_state = root / "real-state"
            real_state.mkdir()
            linked_state = root / "linked-state"
            linked_state.symlink_to(real_state, target_is_directory=True)
            invalid_count = subprocess.run(
                ["bash", str(FSR4), "count"],
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "BC250_FSR4_STATE_DIR": str(linked_state),
                },
                capture_output=True,
                text=True,
            )
            self.assertEqual(invalid_count.returncode, 2)
            self.assertEqual(invalid_count.stdout, "1\n")


if __name__ == "__main__":
    unittest.main()
