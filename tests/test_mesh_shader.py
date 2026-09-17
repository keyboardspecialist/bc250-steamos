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
AMDGPU_REVISION = "smu-8core-metrics-r1"
MESA_TAG = "mesa-26.2.2"
RADV_PROFILE_REVISION = "production-fsr4-v4"
NATIVE_MESH_COMMIT = "d67c00d4aad5797364abc3401d419e76afb04edd"
NATIVE_MESH_REBASE_SHA256 = (
    "2dabe48622732d9761efefc1a655909ee775cc36efb49deeaccda585d0fab0ea"
)


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
        revision_active = root / "modules" / "bc250_amdgpu_revision"
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
            "BC250_AMDGPU_REVISION_ACTIVE": str(revision_active),
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
        revision_active = Path(env["BC250_AMDGPU_REVISION_ACTIVE"])
        policy = Path(env["BC250_SCHED_POLICY_PARAM"])
        generator = Path(env["BC250_GFX1013_GENERATOR"])
        fallback_icd = Path(env["BC250_MESH_32BIT_ICD"])
        fallback_driver = fallback_icd.parent / "libvulkan_radeon.i686.so"
        for path in (driver, icd, module, active, revision_active, policy, generator):
            path.parent.mkdir(parents=True, exist_ok=True)
        state.mkdir(parents=True, exist_ok=True)
        module.write_bytes(b"patched amdgpu\n")
        module_hash = hashlib.sha256(module.read_bytes()).hexdigest()
        for path in (marker, audio_marker, metrics_marker):
            path.write_text(
                f"{module_hash} {AMDGPU_REVISION}\n", encoding="ascii"
            )
        active.write_text(UPSTREAM_COMMIT + "\n", encoding="ascii")
        revision_active.write_text(AMDGPU_REVISION + "\n", encoding="ascii")
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
            f"{digest(driver)} {digest(icd)} {MESA_TAG} {commit} "
            f"{RADV_PROFILE_REVISION} {digest(generator)}\n",
            encoding="ascii",
        )
        driver_files = f'{icd}:{env["BC250_MESH_32BIT_ICD"]}'
        env["VK_DRIVER_FILES"] = driver_files
        env["VK_ICD_FILENAMES"] = driver_files

    def make_generator_unrecorded(self, env):
        generator = Path(env["BC250_GFX1013_GENERATOR"])
        subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; output=$2; set -- help; source "$script" >/dev/null; '
                'render_unrecorded_generator > "$output"',
                "_",
                str(MESH),
                str(generator),
            ],
            check=True,
            env=env,
        )
        generator.chmod(0o755)
        manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
        manifest.write_text(
            " ".join(manifest.read_text(encoding="ascii").split()[:5]) + "\n",
            encoding="ascii",
        )

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
            f"{digest(driver)} {digest(icd)} {digest(runner)} {MESA_TAG} "
            f"{profile_digest}\n",
            encoding="ascii",
        )

    def install_native_mesh_runtime(self, env):
        state = Path(env["BC250_MESH_STATE_DIR"])
        profile = state / "native-mesh"
        profile.mkdir(parents=True)
        driver = profile / "libvulkan_radeon.so"
        icd = profile / "radeon_native_mesh_icd.x86_64.json"
        runner = profile / "bc250-native-mesh-run"
        license_file = profile / "LONEWOLF-LICENSE.md"
        readme = profile / "LONEWOLF-README.md"
        limitations = profile / "LONEWOLF-KNOWN_LIMITATIONS.md"
        driver.write_bytes(b"native mesh driver\n")
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
                'render_native_mesh_runner > "$output"',
                "_",
                str(MESH),
                str(runner),
            ],
            check=True,
            env=env,
        )
        runner.chmod(0o755)
        license_file.write_text("LoneWolf license\n", encoding="utf-8")
        readme.write_text("LoneWolf README\n", encoding="utf-8")
        limitations.write_text("LoneWolf limitations\n", encoding="utf-8")
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        (profile / "install.conf").write_text(
            f"{digest(driver)} {digest(icd)} {digest(runner)} "
            f"{digest(license_file)} {digest(readme)} {digest(limitations)} {MESA_TAG} "
            f"3281a69a8bfd9f997e91c15ed0e6290cae12dd32 {NATIVE_MESH_COMMIT} "
            f"{NATIVE_MESH_REBASE_SHA256}\n",
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
            self.assertEqual(status["mesaVersion"], MESA_TAG)
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
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (state / "install.conf").write_text(
                f"{digest(driver)} {digest(icd)} {MESA_TAG} {UPSTREAM_COMMIT} "
                f"{RADV_PROFILE_REVISION} {digest(generator)}\n",
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

    def test_generator_digest_is_required_for_ready_runtime(self):
        for case in ("missing", "mismatch"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
                fields = manifest.read_text(encoding="ascii").split()
                if case == "missing":
                    fields.pop()
                else:
                    fields[-1] = "0" * 64
                manifest.write_text(" ".join(fields) + "\n", encoding="ascii")

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

    def test_global_activation_requires_active_amdgpu_revision(self):
        for target in ("mismatch", "symlink"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                revision = Path(env["BC250_AMDGPU_REVISION_ACTIVE"])
                if target == "mismatch":
                    revision.write_text("wrong-revision\n", encoding="ascii")
                else:
                    replacement = revision.with_name("revision-target")
                    replacement.write_text(AMDGPU_REVISION + "\n", encoding="ascii")
                    revision.unlink()
                    revision.symlink_to(replacement)
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

    def test_prior_kernel_generator_passes_setup_ownership_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            old_env = {
                **env,
                "BC250_GFX1013_MODULE": "/usr/lib/modules/6.16.12-valve24.5-1-neptune-616/updates/amdgpu.ko.zst",
                "BC250_GFX1013_MARKER": "/usr/lib/modules/6.16.12-valve24.5-1-neptune-616/updates/.bc250-gfx1013-fix",
                "BC250_AUDIO_MARKER": "/usr/lib/modules/6.16.12-valve24.5-1-neptune-616/updates/.bc250-audio-fix",
                "BC250_METRICS_MARKER": "/usr/lib/modules/6.16.12-valve24.5-1-neptune-616/updates/.bc250-metrics-fix",
            }
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; output=$2; set -- help; source "$script" >/dev/null; '
                    'render_generator > "$output"; chmod 755 "$output"',
                    "_",
                    str(MESH),
                    env["BC250_GFX1013_GENERATOR"],
                ],
                check=True,
                env=old_env,
            )
            current_env = {
                **env,
                "BC250_GFX1013_MODULE": "/usr/lib/modules/7.2.0-valve1-1-neptune-72/updates/amdgpu.ko.zst",
                "BC250_GFX1013_MARKER": "/usr/lib/modules/7.2.0-valve1-1-neptune-72/updates/.bc250-gfx1013-fix",
                "BC250_AUDIO_MARKER": "/usr/lib/modules/7.2.0-valve1-1-neptune-72/updates/.bc250-audio-fix",
                "BC250_METRICS_MARKER": "/usr/lib/modules/7.2.0-valve1-1-neptune-72/updates/.bc250-metrics-fix",
            }
            command = (
                'script=$1; set -- help; source "$script" >/dev/null; '
                "preflight_runtime_ownership"
            )
            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=current_env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            with Path(env["BC250_GFX1013_GENERATOR"]).open(
                "a", encoding="utf-8"
            ) as generator:
                generator.write("echo tampered\n")
            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=current_env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a recorded toolkit install", result.stderr)

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

    def test_recorded_generator_digest_survives_template_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            generator.write_text(
                generator.read_text(encoding="utf-8").replace(
                    "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\n# older toolkit revision\n"
                ),
                encoding="utf-8",
            )
            manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
            fields = manifest.read_text(encoding="ascii").split()
            fields[-1] = hashlib.sha256(generator.read_bytes()).hexdigest()
            manifest.write_text(" ".join(fields) + "\n", encoding="ascii")
            command = (
                'script=$1; set -- help; source "$script" >/dev/null; '
                "preflight_runtime_ownership"
            )

            recorded = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(recorded.returncode, 0, recorded.stderr)

            with generator.open("a", encoding="utf-8") as stream:
                stream.write("echo tampered\n")
            tampered = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("not a recorded toolkit install", tampered.stderr)

    def test_unrecorded_current_generator_is_refreshed_without_mesa(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.make_generator_unrecorded(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
            command = (
                'script=$1; set -- help; source "$script" >/dev/null; '
                "refresh_current_generator"
            )

            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("without rebuilding Mesa", result.stdout)
            fields = manifest.read_text(encoding="ascii").split()
            self.assertEqual(len(fields), 6)
            self.assertEqual(fields[-1], hashlib.sha256(generator.read_bytes()).hexdigest())
            self.assertEqual(self.run_status_json(env)["runtimeState"], "ready")

    def test_setup_repairs_fallback_then_refreshes_generator_without_mesa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            self.make_generator_unrecorded(env)
            fallback = Path(env["BC250_MESH_32BIT_ICD"])
            valid_fallback = root / "valid-fallback.json"
            valid_fallback.write_bytes(fallback.read_bytes())
            fallback.write_text("{}\n", encoding="ascii")
            actions = root / "setup-actions.log"
            env["BC250_TEST_MANAGER_INACTIVE"] = "1"
            command = r'''
script=$1
set -- help
source "$script" >/dev/null
require_normal_user() { :; }
require_production_kernel_paths() { :; }
ensure_compute_kernel_prerequisite() { :; }
ensure_radv_core_tools() { :; }
ensure_radv_prerequisites() {
    printf 'prerequisites\n' >> "$BC250_TEST_ACTIONS"
    cp "$BC250_TEST_VALID_FALLBACK" "$FALLBACK_ICD"
}
stage_upstream() {
    printf 'mesa-build\n' >> "$BC250_TEST_ACTIONS"
    return 91
}
cmd_setup default 0
'''

            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={
                    **env,
                    "BC250_TEST_ACTIONS": str(actions),
                    "BC250_TEST_VALID_FALLBACK": str(valid_fallback),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(actions.read_text(encoding="utf-8").splitlines(), ["prerequisites"])
            self.assertIn("without rebuilding Mesa", result.stdout)
            self.assertIn("no Mesa rebuild is needed", result.stdout)
            self.assertIn("Sign out and back in", result.stdout)
            status = self.run_status_json(env)
            self.assertEqual(status["runtimeState"], "ready")
            self.assertTrue(status["restartRequired"])

    def test_generator_refresh_failure_restores_readonly_and_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            self.make_generator_unrecorded(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
            generator_before = generator.read_bytes()
            manifest_before = manifest.read_bytes()
            readonly_state = root / "readonly-state"
            readonly_state.write_text("enabled\n", encoding="ascii")
            actions = root / "readonly-actions.log"
            command = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
steamos-readonly() {
    printf '%s\n' "$1" >> "$BC250_TEST_ACTIONS"
    case "$1" in
        status) cat "$BC250_TEST_READONLY_STATE" ;;
        disable)
            printf 'disabled\n' > "$BC250_TEST_READONLY_STATE"
            return 23
            ;;
        enable) printf 'enabled\n' > "$BC250_TEST_READONLY_STATE" ;;
    esac
}
refresh_current_generator
'''

            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={
                    **env,
                    "BC250_TEST_ACTIONS": str(actions),
                    "BC250_TEST_READONLY_STATE": str(readonly_state),
                },
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(readonly_state.read_text(encoding="ascii").strip(), "enabled")
            self.assertEqual(actions.read_text(encoding="utf-8").splitlines()[-1], "enable")
            self.assertEqual(generator.read_bytes(), generator_before)
            self.assertEqual(manifest.read_bytes(), manifest_before)
            self.assertFalse((Path(env["BC250_MESH_STATE_DIR"]) / "install-transaction").exists())

    def test_recovery_restores_recorded_readonly_state_in_new_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            self.make_generator_unrecorded(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
            generator_before = generator.read_bytes()
            manifest_before = manifest.read_bytes()
            readonly_state = root / "readonly-state"
            readonly_state.write_text("disabled\n", encoding="ascii")
            actions = root / "readonly-actions.log"
            arm = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
arm_install_transaction 1
printf 'interrupted generator\n' > "$GENERATOR"
printf 'interrupted manifest\n' > "$MANIFEST"
'''
            subprocess.run(
                ["bash", "-c", arm, "_", str(MESH)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            recover = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
steamos-readonly() {
    printf '%s\n' "$1" >> "$BC250_TEST_ACTIONS"
    case "$1" in
        status) cat "$BC250_TEST_READONLY_STATE" ;;
        disable) printf 'disabled\n' > "$BC250_TEST_READONLY_STATE" ;;
        enable) printf 'enabled\n' > "$BC250_TEST_READONLY_STATE" ;;
    esac
}
recover_install_transaction
'''

            result = subprocess.run(
                ["bash", "-c", recover, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={
                    **env,
                    "BC250_TEST_ACTIONS": str(actions),
                    "BC250_TEST_READONLY_STATE": str(readonly_state),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(readonly_state.read_text(encoding="ascii").strip(), "enabled")
            self.assertEqual(actions.read_text(encoding="utf-8").splitlines(), ["status", "enable"])
            self.assertEqual(generator.read_bytes(), generator_before)
            self.assertEqual(manifest.read_bytes(), manifest_before)
            self.assertFalse((Path(env["BC250_MESH_STATE_DIR"]) / "install-transaction").exists())

    def test_generator_refresh_signal_rolls_back_and_returns_signal_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            self.make_generator_unrecorded(env)
            generator = Path(env["BC250_GFX1013_GENERATOR"])
            manifest = Path(env["BC250_MESH_STATE_DIR"]) / "install.conf"
            generator_before = generator.read_bytes()
            manifest_before = manifest.read_bytes()
            signal_marker = root / "signal-sent"
            command = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
install() {
    while (( $# > 2 )); do
        case "$1" in
            -o|-g|-m) shift 2 ;;
            *) break ;;
        esac
    done
    cp "$1" "$2"
    if [[ ! -e "$BC250_TEST_SIGNAL_MARKER" ]]; then
        touch "$BC250_TEST_SIGNAL_MARKER"
        kill -TERM "$BASHPID"
    fi
}
refresh_current_generator
'''

            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={**env, "BC250_TEST_SIGNAL_MARKER": str(signal_marker)},
            )

            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(generator.read_bytes(), generator_before)
            self.assertEqual(manifest.read_bytes(), manifest_before)
            self.assertFalse((Path(env["BC250_MESH_STATE_DIR"]) / "install-transaction").exists())

    def test_unmanaged_runtime_requires_explicit_safe_override(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            driver = Path(env["BC250_MESH_DRIVER"])
            driver.write_bytes(b"unmanaged driver\n")
            command = (
                'script=$1; override=$2; set -- help; source "$script" >/dev/null; '
                'preflight_runtime_ownership "$override"'
            )
            refused = subprocess.run(
                ["bash", "-c", command, "_", str(MESH), "0"],
                capture_output=True,
                text=True,
                env=env,
            )
            allowed = subprocess.run(
                ["bash", "-c", command, "_", str(MESH), "1"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("install manifest is missing", refused.stderr)
            self.assertIn("setup --replace-unmanaged", refused.stderr)
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            self.assertIn("Replacing unmanaged alternate runtime", allowed.stdout)

    def test_unmanaged_runtime_override_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            driver = Path(env["BC250_MESH_DRIVER"])
            target = driver.with_name("foreign-driver")
            target.write_bytes(b"foreign driver\n")
            driver.symlink_to(target)
            command = (
                'script=$1; set -- help; source "$script" >/dev/null; '
                "preflight_runtime_ownership 1"
            )
            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to replace an unmanaged symlink", result.stderr)

    def test_tampered_generator_invalidates_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            Path(env["BC250_GFX1013_GENERATOR"]).write_text(
                "#!/bin/sh\necho unsafe\n", encoding="utf-8"
            )
            self.assertEqual(self.run_status_json(env)["runtimeState"], "invalid")

    def test_generator_rejects_tampered_runtime_attestations(self):
        for target in ("driver", "icd", "manifest", "active", "revision"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                paths = {
                    "driver": Path(env["BC250_MESH_DRIVER"]),
                    "icd": Path(env["BC250_MESH_ICD"]),
                    "manifest": Path(env["BC250_MESH_STATE_DIR"]) / "install.conf",
                    "active": Path(env["BC250_GFX1013_ACTIVE"]),
                    "revision": Path(env["BC250_AMDGPU_REVISION_ACTIVE"]),
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

    def test_fsr4_runner_refuses_inactive_scheduler_or_wrong_revision(self):
        for target in ("policy", "revision"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                self.install_fsr4_runtime(env)
                if target == "policy":
                    Path(env["BC250_SCHED_POLICY_PARAM"]).write_text(
                        "0\n", encoding="ascii"
                    )
                else:
                    Path(env["BC250_AMDGPU_REVISION_ACTIVE"]).write_text(
                        "wrong-revision\n", encoding="ascii"
                    )
                runner = Path(env["BC250_MESH_STATE_DIR"]) / "fsr4/bc250-fsr4-run"
                result = subprocess.run(
                    [str(runner), "true"], capture_output=True, text=True, env=env
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "sched_policy=2" if target == "policy" else "AMDGPU revision",
                    result.stderr,
                )

    def test_native_mesh_runner_is_private_attested_and_uses_exact_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_native_mesh_runtime(env)
            status = self.run_status_json(env)
            self.assertEqual(status["nativeMeshState"], "ready")
            self.assertNotIn(status["nativeMeshIcdPath"], env["VK_DRIVER_FILES"])

            command = "printf '%s|%s|%s|%s' \"$RADV_EXPERIMENTAL\" \"${RADV_BC250_ADVERTISE_TASK-unset}\" \"${RADV_BC250_EXPOSE_FSR-unset}\" \"$VK_DRIVER_FILES\""
            inherited = {
                **env,
                "RADV_EXPERIMENTAL": "foreign,flags",
                "RADV_BC250_ADVERTISE_TASK": "9",
                "RADV_BC250_EXPOSE_FSR": "9",
            }
            default = subprocess.run(
                [status["nativeMeshRunnerPath"], "sh", "-c", command],
                check=True,
                capture_output=True,
                text=True,
                env=inherited,
            )
            fields = default.stdout.split("|")
            self.assertEqual(fields[:3], ["bc250_mesh", "unset", "unset"])
            self.assertIn(status["nativeMeshIcdPath"], fields[3])
            self.assertIn(env["BC250_MESH_32BIT_ICD"], fields[3])

            ff7 = subprocess.run(
                [
                    status["nativeMeshRunnerPath"],
                    "--ff7-capabilities",
                    "sh",
                    "-c",
                    command,
                ],
                check=True,
                capture_output=True,
                text=True,
                env=inherited,
            )
            self.assertEqual(ff7.stdout.split("|")[:3], ["bc250_mesh", "1", "1"])

    def test_native_mesh_runner_requires_current_kernel_and_scheduler(self):
        for target in ("active", "revision", "policy"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                self.install_native_mesh_runtime(env)
                state = Path(env["BC250_MESH_STATE_DIR"])
                if target == "active":
                    Path(env["BC250_GFX1013_ACTIVE"]).write_text(
                        "wrong\n", encoding="ascii"
                    )
                elif target == "revision":
                    Path(env["BC250_AMDGPU_REVISION_ACTIVE"]).write_text(
                        "wrong-revision\n", encoding="ascii"
                    )
                else:
                    Path(env["BC250_SCHED_POLICY_PARAM"]).write_text(
                        "0\n", encoding="ascii"
                    )
                result = subprocess.run(
                    [str(state / "native-mesh/bc250-native-mesh-run"), "true"],
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_native_mesh_notices_are_attested_by_status_and_runner(self):
        for name in (
            "LONEWOLF-LICENSE.md",
            "LONEWOLF-README.md",
            "LONEWOLF-KNOWN_LIMITATIONS.md",
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                env = self.environment(Path(directory))
                self.install_runtime(env)
                self.install_native_mesh_runtime(env)
                profile = Path(env["BC250_MESH_STATE_DIR"]) / "native-mesh"
                (profile / name).write_text("tampered\n", encoding="utf-8")
                self.assertEqual(self.run_status_json(env)["nativeMeshState"], "invalid")
                result = subprocess.run(
                    [str(profile / "bc250-native-mesh-run"), "true"],
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("failed hash verification", result.stderr)

    def test_uninstall_native_mesh_preserves_global_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_native_mesh_runtime(env)
            preserved = {
                path: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (
                    Path(env["BC250_MESH_DRIVER"]),
                    Path(env["BC250_MESH_ICD"]),
                    Path(env["BC250_GFX1013_GENERATOR"]),
                    Path(env["BC250_MESH_STATE_DIR"]) / "install.conf",
                )
            }
            subprocess.run(
                ["bash", str(MESH), "uninstall", "--native-mesh"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(self.run_status_json(env)["nativeMeshState"], "not-installed")
            for path, expected in preserved.items():
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected)

    def test_native_mesh_rebase_is_pinned_and_never_uses_fuzzy_setup(self):
        script = MESH.read_text(encoding="utf-8")
        setup = script.split("cmd_setup_native_mesh() (", 1)[1].split(
            "\n)\n\nmanage_games", 1
        )[0]
        patch = ROOT / "bc250-mesa-patches/0010-lonewolf-native-mesh-mesa-26.2.2-rebase.patch"
        self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(), NATIVE_MESH_REBASE_SHA256)
        self.assertIn(f'NATIVE_MESH_COMMIT="{NATIVE_MESH_COMMIT}"', script)
        self.assertIn("0001-gfx1013-compute-queue-fix.patch", setup)
        for number in range(5, 10):
            self.assertIn(f"000{number}-", setup)
        self.assertIn('git -C "$source" apply --check "$NATIVE_MESH_REBASE"', setup)
        self.assertNotIn("--3way", setup)
        self.assertNotIn("--3-way", setup)
        self.assertNotIn("--fuzz", setup[setup.index('git -C "$source" apply --check'):])
        runner = script.split("render_native_mesh_runner() {", 1)[1].split(
            "\n}\n\nread_native_mesh_manifest", 1
        )[0]
        self.assertNotIn("GENERATOR", runner)
        self.assertIn("export RADV_EXPERIMENTAL=bc250_mesh", runner)
        for notice in (
            "LONEWOLF-LICENSE.md",
            "LONEWOLF-README.md",
            "LONEWOLF-KNOWN_LIMITATIONS.md",
        ):
            self.assertIn(f'sha256_file "$profile_stage/{notice}"', setup)

    def test_all_generated_activation_scripts_attest_amdgpu_revision(self):
        script = MESH.read_text(encoding="utf-8")
        for renderer in (
            "render_previous_generator",
            "render_generator",
            "render_pre_policy_generator",
            "render_legacy_generator",
            "render_fsr4_runner",
            "render_native_mesh_runner",
        ):
            body = script.split(f"{renderer}() {{", 1)[1].split("\nEOF\n}", 1)[0]
            with self.subTest(renderer=renderer):
                self.assertIn('shell_word "$AMDGPU_REVISION_ACTIVE"', body)
                self.assertIn('shell_word "$AMDGPU_REVISION"', body)
                self.assertIn('! -L "\\$REVISION_ACTIVE"', body)
                self.assertIn('cat "\\$REVISION_ACTIVE"', body)
        production_paths = script.split("require_production_kernel_paths() {", 1)[
            1
        ].split("\n}", 1)[0]
        self.assertIn("DEFAULT_AMDGPU_REVISION_ACTIVE", production_paths)

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
            "\n)\n\ncmd_setup_native_mesh", 1
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
            "\n)\n\ncmd_setup_native_mesh", 1
        )[0]
        guard = 'if [[ "$profile" == default ]] && verify_current_runtime; then'
        guard_index = setup.index(guard)
        message_index = setup.index(
            "already installed and verified; no Mesa rebuild is needed",
            guard_index,
        )
        return_index = setup.index("return 0", message_index)

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

    def test_interrupted_native_mesh_replacement_restores_attested_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_native_mesh_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            profile = state / "native-mesh"
            transaction = state / "native-mesh-install-transaction"
            previous = transaction / "previous"
            previous.mkdir(parents=True)
            expected = {}
            for source in profile.iterdir():
                backup = previous / source.name
                backup.write_bytes(source.read_bytes())
                backup.chmod(source.stat().st_mode)
                expected[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
            (transaction / "transaction.conf").write_text(
                "swapping 1\n", encoding="ascii"
            )
            (profile / "LONEWOLF-README.md").write_text(
                "interrupted\n", encoding="utf-8"
            )

            subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "recover_native_mesh_install_transaction",
                    "_",
                    str(MESH),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertFalse(transaction.exists())
            self.assertEqual(self.run_status_json(env)["nativeMeshState"], "ready")
            self.assertEqual(
                {
                    path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in profile.iterdir()
                },
                expected,
            )

    def test_native_mesh_recovery_rejects_tampered_notice_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            self.install_runtime(env)
            self.install_native_mesh_runtime(env)
            state = Path(env["BC250_MESH_STATE_DIR"])
            profile = state / "native-mesh"
            transaction = state / "native-mesh-install-transaction"
            previous = transaction / "previous"
            previous.mkdir(parents=True)
            for source in profile.iterdir():
                backup = previous / source.name
                backup.write_bytes(source.read_bytes())
                backup.chmod(source.stat().st_mode)
            (transaction / "transaction.conf").write_text(
                "swapping 1\n", encoding="ascii"
            )
            (previous / "LONEWOLF-KNOWN_LIMITATIONS.md").write_text(
                "tampered backup\n", encoding="utf-8"
            )
            current = profile / "libvulkan_radeon.so"
            current.write_bytes(b"interrupted current profile\n")

            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'script=$1; set -- help; source "$script" >/dev/null; '
                    "recover_native_mesh_install_transaction",
                    "_",
                    str(MESH),
                ],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("backup failed attestation", result.stderr)
            self.assertEqual(current.read_bytes(), b"interrupted current profile\n")
            self.assertTrue(transaction.exists())

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
        self.assertIn("Install FSR4 RC9 game DLL (recommended)", source)
        self.assertIn("Install / resume FSR4 RADV", source)
        self.assertIn("not required for the portable FSR4 RC9 route", source)
        self.assertIn("Older per-game setup cleanup", source)
        self.assertIn("Usually takes 3-5 minutes", source)
        self.assertIn("GFX1013 async-compute marker", source)
        self.assertIn("require_production_kernel_paths", source)
        self.assertIn('LC_ALL=C ldd -r "$output"', source)
        self.assertIn('LC_ALL=C readelf -h "$output"', source)
        self.assertIn("undefined symbol:", source)
        self.assertIn("BC250_FORCE_GRUB_REGEN=1", source)
        self.assertIn("Reboot to deactivate it, then rerun uninstall", source)
        self.assertNotIn("20-40", source)
        self.assertNotIn("Enable one executable|", source)
        self.assertIn("DryhoppedIPA/bc250-gfx1013-fix", source)
        self.assertIn('DEFAULT_MESA_TAG="mesa-26.2.2"', source)
        self.assertIn("Legacy FSR4 V3 RADV setup has been retired", source)
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

    def test_radv_prerequisite_repair_follows_active_kernel_gate(self):
        source = MESH.read_text(encoding="utf-8")
        setup = source.split("cmd_setup() (", 1)[1].split(
            "\n)\n\ncmd_setup_native_mesh", 1
        )[0]
        kernel_gate = setup.index("ensure_compute_kernel_prerequisite")
        core_tools = setup.index("ensure_radv_core_tools")
        prerequisites = setup.index("ensure_radv_prerequisites")
        generator_refresh = setup.index("runtime_generator_can_refresh")
        ownership = setup.index("preflight_runtime_ownership")
        locked_ownership = setup.index(
            "preflight_runtime_ownership", setup.index("recover_install_transaction")
        )
        package_repair = source.split("ensure_radv_prerequisites() {", 1)[1].split(
            "\n}\n\nmanager_environment_active", 1
        )[0]

        self.assertLess(setup.index("command -v systemctl"), kernel_gate)
        self.assertLess(kernel_gate, ownership)
        self.assertLess(ownership, core_tools)
        self.assertLess(core_tools, setup.index("flock 9"))
        self.assertLess(setup.index("recover_install_transaction"), locked_ownership)
        self.assertLess(locked_ownership, prerequisites)
        self.assertLess(prerequisites, generator_refresh)
        self.assertNotIn("systemctl", package_repair)
        self.assertIn("verify_32bit_fallback", package_repair)
        self.assertIn(
            "install_signed_steamos_packages", package_repair
        )
        self.assertIn('pacman -S --noconfirm "$@"', source)
        for package in ("curl", "lib32-vulkan-radeon"):
            self.assertIn(package, package_repair)
        core_repair = source.split("ensure_radv_core_tools() {", 1)[1].split(
            "\n}\n\nensure_radv_prerequisites", 1
        )[0]
        for package in ("python", "util-linux"):
            self.assertIn(package, core_repair)
        self.assertIn(
            "Signed SteamOS package lib32-vulkan-radeon",
            package_repair,
        )
        self.assertLess(
            setup.index("preflight_runtime_ownership"),
            setup.index('install_default_profile "$output" "$mesa_tag"'),
        )

    def test_radv_prerequisites_install_and_strictly_revalidate_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            fallback = Path(env["BC250_MESH_32BIT_ICD"])
            valid_fallback = root / "valid-fallback.json"
            valid_fallback.write_bytes(fallback.read_bytes())
            fallback.write_text("{}\n", encoding="ascii")
            log = root / "packages.log"
            available = root / "available"
            available.mkdir()
            command = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
command() {
    if [[ "${1:-}" == -v ]]; then
        case "${2:-}" in
            curl|python3|flock) [[ -e "$BC250_TEST_AVAILABLE/${2}" ]]; return ;;
        esac
    fi
    builtin command "$@"
}
steamos-readonly() {
    printf 'readonly %s\n' "$1" >> "$BC250_TEST_PACKAGE_LOG"
    [[ "$1" != status ]] || printf 'enabled\n'
}
pacman-key() { printf 'pacman-key %s\n' "$*" >> "$BC250_TEST_PACKAGE_LOG"; }
pacman() {
    printf 'pacman %s\n' "$*" >> "$BC250_TEST_PACKAGE_LOG"
    for package; do
        case "$package" in
            curl) touch "$BC250_TEST_AVAILABLE/curl" ;;
            python) touch "$BC250_TEST_AVAILABLE/python3" ;;
            util-linux) touch "$BC250_TEST_AVAILABLE/flock" ;;
            lib32-vulkan-radeon) cp "$BC250_TEST_VALID_FALLBACK" "$FALLBACK_ICD" ;;
        esac
    done
}
ensure_radv_core_tools
ensure_radv_prerequisites
'''
            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={
                    **env,
                    "BC250_TEST_AVAILABLE": str(available),
                    "BC250_TEST_PACKAGE_LOG": str(log),
                    "BC250_TEST_VALID_FALLBACK": str(valid_fallback),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            package_log = log.read_text(encoding="utf-8")
            pacman_lines = [
                line for line in package_log.splitlines() if line.startswith("pacman -S")
            ]
            for package in ("curl", "python", "util-linux", "lib32-vulkan-radeon"):
                self.assertTrue(
                    any(package in line.split() for line in pacman_lines), package
                )
            self.assertLess(
                package_log.index("readonly disable"),
                package_log.index("pacman -S"),
            )
            self.assertLess(
                package_log.index("pacman -S"),
                package_log.rindex("readonly enable"),
            )

            fallback.write_text("{}\n", encoding="ascii")
            previous_log_size = len(log.read_text(encoding="utf-8"))
            failed = subprocess.run(
                [
                    "bash",
                    "-c",
                    command.replace(
                        'lib32-vulkan-radeon) cp "$BC250_TEST_VALID_FALLBACK" "$FALLBACK_ICD"',
                        "lib32-vulkan-radeon) :",
                    ),
                    "_",
                    str(MESH),
                ],
                capture_output=True,
                text=True,
                env={
                    **env,
                    "BC250_TEST_AVAILABLE": str(available),
                    "BC250_TEST_PACKAGE_LOG": str(log),
                    "BC250_TEST_VALID_FALLBACK": str(valid_fallback),
                },
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("did not provide a valid 32-bit RADV ICD", failed.stderr)
            retry_log = log.read_text(encoding="utf-8")[previous_log_size:]
            self.assertLess(
                retry_log.index("readonly disable"), retry_log.index("pacman -S")
            )
            self.assertLess(
                retry_log.index("pacman -S"), retry_log.index("readonly enable")
            )

    def test_radv_package_failure_restores_readonly_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.environment(root)
            self.install_runtime(env)
            Path(env["BC250_MESH_32BIT_ICD"]).write_text("{}\n", encoding="ascii")
            log = root / "readonly.log"
            command = r'''
script=$1
set -- help
source "$script" >/dev/null
as_root() { "$@"; }
steamos-readonly() {
    printf '%s\n' "$1" >> "$BC250_TEST_READONLY_LOG"
    [[ "$1" != status ]] || printf 'enabled\n'
}
pacman-key() { :; }
pacman() { return 23; }
ensure_radv_prerequisites
'''
            result = subprocess.run(
                ["bash", "-c", command, "_", str(MESH)],
                capture_output=True,
                text=True,
                env={**env, "BC250_TEST_READONLY_LOG": str(log)},
            )
            self.assertNotEqual(result.returncode, 0)
            actions = log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(actions, ["status", "disable", "enable"])

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

    def test_new_legacy_fsr4_builds_are_refused_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.environment(Path(directory))
            result = subprocess.run(
                ["bash", str(MESH), "setup", "--fsr4-legacy"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Legacy FSR4 V3 builds are retired", result.stderr)
            self.assertFalse(Path(env["BC250_MESH_STATE_DIR"]).exists())

    def test_production_fsr4_radv_patch_series_is_pinned_and_validated(self):
        script = MESH.read_text(encoding="utf-8")
        self.assertIn(
            'FSR4_RADV_COMMIT="db49878af40551b481f511053201fcf1e1bd5d90"',
            script,
        )
        for patch in (
            "0001-gfx1013-compute-queue-fix.patch",
            "0005-bc250-fsr4-v3.patch",
            "0006-bc250-fsr4-combined-unroll.patch",
            "0007-bc250-fsr4-imageprep-texture.patch",
            "0008-bc250-fsr4-resolution-variants.patch",
            "0009-bc250-fsr4-production-defaults.patch",
        ):
            self.assertIn(patch, script)
        self.assertIn(
            'patch -d "$source" -p1 --fuzz=0 --no-backup-if-mismatch',
            script,
        )
        for marker in (
            "bc250-fsr4-integrated-v3",
            "BC250_FSR4_DISABLE",
            "BC250_FSR4_IMAGEPREP",
            "BC250_FSR4_TEXTURE",
            "BC250_FSR4_RESOLUTION_VARIANTS",
            "BC250_FSR4_RESOLUTION_GUARD",
        ):
            self.assertIn(marker, script)

    def test_unsafe_mesh_task_patches_are_not_fetched_or_applied(self):
        script = MESH.read_text(encoding="utf-8")
        stage = script[script.index("stage_upstream() {") : script.index("verify_fsr4_patch() {")]
        setup = script[script.index("cmd_setup() (") : script.index("manage_games() {")]
        for patch in (
            "0002-gfx1013-mesh-task-shaders.patch",
            "0003-gfx1013-taskmesh-queries.patch",
            "0004-radv-gfx103.patch",
        ):
            self.assertNotIn(patch, stage)
            self.assertNotIn(patch, setup)

    def test_purge_serializes_with_fsr4_dll_rollback_state(self):
        script = MESH.read_text(encoding="utf-8")
        purge = script[script.index("cmd_purge() (") : script.index("menu_select() {")]
        self.assertIn('exec 8> "$FSR4_DLL_LOCK"', purge)
        self.assertIn('flock 8', purge)
        self.assertIn('FSR4 DLL rollback state exists but its helper is unavailable', purge)

    def test_interactive_menu_can_remove_only_native_mesh(self):
        script = MESH.read_text(encoding="utf-8")
        graph = (ROOT / "menus/mesh-shader.mmd").read_text(encoding="utf-8")
        self.assertIn("Remove private LoneWolf native mesh", graph)
        self.assertIn(
            "action__native_mesh_remove)", script
        )
        self.assertIn("uninstall --native-mesh", script)

    def test_rc9_helper_is_executable_and_in_toolkit_release_glob(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        self.assertTrue(os.access(FSR4, os.X_OK))
        self.assertIn("cp README.md bc250-*.sh", workflow)
        helper = FSR4.read_text(encoding="utf-8")
        self.assertIn('RELEASE="${BC250_FSR4_RELEASE:-v4.0.0-rc9}"', helper)
        self.assertIn(
            'ARCHIVE_NAME="${BC250_FSR4_ARCHIVE_NAME:-bc250-fsr4-dll-${RELEASE#v}-docs2.tar.xz}"',
            helper,
        )
        self.assertIn(
            "063e23e0a56605b63deef2c03100432eb75d991c68eb04c6eb9b4a8444fd4f06",
            helper,
        )
        self.assertIn(
            "eefcac03ab17b04a29a5bb16e3f3e9c3181ba9ea46b05a61cb49a5003e1516ef",
            helper,
        )

    def test_rc9_dll_install_is_pinned_transactional_and_reversible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload"
            (payload / "notices").mkdir(parents=True)
            dll = payload / "amd_fidelityfx_upscaler_dx12.dll"
            dll.write_bytes(b"MZ synthetic rc9 payload\n")
            (payload / "README.md").write_text("test release\n", encoding="utf-8")
            (payload / "notices/PROVENANCE.md").write_text(
                "test provenance\n", encoding="utf-8"
            )
            archive = root / "rc9.tar.xz"
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
            records = json.loads(subprocess.run(
                ["bash", str(FSR4), "records-json"],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            ).stdout)
            self.assertEqual(records["schemaVersion"], 1)
            self.assertEqual(records["state"], "ready")
            self.assertEqual(records["invalidRecordCount"], 0)
            self.assertEqual(len(records["records"]), 1)
            self.assertEqual(records["records"][0]["targetPath"], str(target.resolve()))
            self.assertEqual(records["records"][0]["state"], "ready")

            target.write_bytes(b"externally changed\n")
            modified = json.loads(subprocess.run(
                ["bash", str(FSR4), "records-json"],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            ).stdout)
            self.assertEqual(modified["state"], "invalid")
            self.assertEqual(modified["records"][0]["state"], "modified")
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

    def test_rc9_helper_rejects_unsafe_release_and_symlink_inputs(self):
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
            invalid_records = subprocess.run(
                ["bash", str(FSR4), "records-json"],
                check=True,
                env={
                    **os.environ,
                    "HOME": str(root / "home"),
                    "BC250_FSR4_STATE_DIR": str(linked_state),
                    "BC250_FSR4_LOCK_FILE": str(root / "records.lock"),
                },
                capture_output=True,
                text=True,
            )
            payload = json.loads(invalid_records.stdout)
            self.assertEqual(payload["state"], "invalid")
            self.assertEqual(payload["invalidRecordCount"], 1)
            self.assertEqual(payload["records"][0]["targetId"], "unsafe-state")


if __name__ == "__main__":
    unittest.main()
