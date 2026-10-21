import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "video-codec/bc250-video-codec.sh"
SOURCE_ROOT = "bc250-encoding-decoding-fix-bc1191850fa521ceb3345986c59c1a882ed757fc"
SHADERS = (
    "color_convert", "dct_transform", "deblock_filter", "entropy_encode",
    "hevc_motion_estimation", "hevc_pred", "hevc_quant", "hevc_reconstruct_sao",
    "hevc_transform", "intra_wavefront", "motion_estimation", "quantize",
    "reconstruct", "residual_predict", "video_proc", "video_proc10",
    "video_proc_tonemap",
)


class VideoCodecTests(unittest.TestCase):
    def run_script(self, *arguments, data_dir, env_file):
        environment = os.environ.copy()
        environment.update(
            {
                "BC250_VIDEO_DATA_DIR": str(data_dir),
                "BC250_VIDEO_COMPAT_DIR": str(data_dir.parent / "bc250"),
                "BC250_VIDEO_ENV_FILE": str(env_file),
                "BC250_VIDEO_PROFILE_FILE": str(
                    env_file.parent.parent / "profile.d/zz-bc250-video-codec.sh"
                ),
                "BC250_VIDEO_KEEP_FILE": str(
                    env_file.parent.parent
                    / "atomic-update.conf.d/bc250-video-codec.conf"
                ),
                "BC250_VIDEO_LOCK_FILE": str(data_dir.parent / "codec.lock"),
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_status_distinguishes_absent_and_partial_installations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            environment = root / "environment.d/90-bc250-video-codec.conf"

            absent = self.run_script(
                "status", data_dir=data, env_file=environment
            )
            self.assertEqual(absent.returncode, 1)
            self.assertIn("state: not-installed", absent.stdout)
            self.assertIn("release: v0.5.4", absent.stdout)

            environment.parent.mkdir()
            environment.write_text(
                "# BC-250 toolkit managed VA-API video codec\n",
                encoding="utf-8",
            )
            partial = self.run_script(
                "status", data_dir=data, env_file=environment
            )
            self.assertEqual(partial.returncode, 2)
            self.assertIn("state: incomplete", partial.stdout)
            self.assertIn("driver: missing-or-invalid", partial.stdout)

    def test_source_commit_and_archive_digest_are_pinned(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("RELEASE=v0.5.4", source)
        self.assertIn(
            "SOURCE_COMMIT=bc1191850fa521ceb3345986c59c1a882ed757fc",
            source,
        )
        self.assertIn(
            "SOURCE_ARCHIVE_SHA256=6659bc48c4a8914385e869b4824f04257936e9d8e03574242409c05f2f819720",
            source,
        )
        self.assertIn("codeload.github.com/simpmix/bc250-encoding-decoding-fix/tar.gz/$SOURCE_COMMIT", source)
        self.assertEqual(source.count("-DBC250_WITH_X264=ON"), 2)
        self.assertEqual(source.count("-DBC250_WITH_X265=ON"), 2)
        self.assertNotIn("-DBC250_WITH_X265=OFF", source)
        self.assertIn('"$output" != *"libx264"*', source)
        self.assertIn('"$output" != *"libx265"*', source)
        self.assertIn("build=local-source", source)
        self.assertIn("write_runtime_manifest", source)
        self.assertEqual(
            re.findall(r"^    ([a-z0-9_]+)\.comp\.spv$", source, re.MULTILINE),
            list(SHADERS),
        )

    def test_shader_inventory_rejects_missing_and_unreviewed_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shaders = root / "approach1-compute-encoder/shaders"
            shaders.mkdir(parents=True)
            for shader in SHADERS:
                (shaders / f"{shader}.comp").write_text("shader\n")
            command = (
                'helper=$1; source_dir=$2; set -- help; source "$helper" >/dev/null; '
                'source_shader_inventory_valid "$source_dir"'
            )
            def valid():
                return subprocess.run(
                    ["bash", "-c", command, "_", str(SCRIPT), str(root)],
                    capture_output=True,
                ).returncode == 0
            self.assertTrue(valid())
            extra = shaders / "unreviewed.comp"
            extra.write_text("shader\n")
            self.assertFalse(valid())
            extra.unlink()
            (shaders / "video_proc_tonemap.comp").unlink()
            self.assertFalse(valid())

    def test_manifests_cover_all_shaders_for_both_architectures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for dual in (False, True):
                runtime = root / ("dual" if dual else "native")
                paths = ["dri/bc250_drv_video.so"]
                if dual:
                    paths.append("dri32/bc250_drv_video.so")
                paths += [f"shaders/{shader}.comp.spv" for shader in SHADERS]
                paths += ["LICENSE.upstream", "README.upstream.md"]
                for relative in paths:
                    target = runtime / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"fixture\n")
                result = subprocess.run(
                    ["bash", "-c",
                     'helper=$1; runtime=$2; set -- help; source "$helper" >/dev/null; '
                     'write_runtime_manifest "$runtime"; '
                     'manifest_layout_valid "$runtime/manifest.sha256"; '
                     '(cd "$runtime" && sha256sum -c --quiet manifest.sha256)',
                     "_", str(SCRIPT), str(runtime)],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = runtime / "manifest.sha256"
                self.assertEqual(
                    [line.split("  ")[1] for line in manifest.read_text().splitlines()],
                    paths,
                )
                manifest.write_text(manifest.read_text().replace(
                    "shaders/hevc_pred.comp.spv", "shaders/unreviewed.comp.spv"
                ))
                invalid = subprocess.run(
                    ["bash", "-c",
                     'helper=$1; manifest=$2; set -- help; source "$helper" >/dev/null; '
                     'manifest_layout_valid "$manifest"',
                     "_", str(SCRIPT), str(manifest)], capture_output=True,
                )
                self.assertNotEqual(invalid.returncode, 0)

    def test_runtime_dependency_check_rejects_hard_codec_links(self):
        for output, expected in (
            ("libva.so => /usr/lib/libva.so", 0),
            ("libx264.so.164 => /usr/lib/libx264.so.164", 1),
            ("libx265.so.215 => /usr/lib/libx265.so.215", 1),
            ("libvulkan.so => not found", 1),
            ("undefined symbol: hevc_x265_create", 1),
        ):
            with self.subTest(output=output):
                result = subprocess.run(
                    ["bash", "-c",
                     'helper=$1; fixture_output=$2; set -- help; source "$helper" >/dev/null; '
                     'ldd() { printf "%s\\n" "$fixture_output"; }; '
                     'runtime_dependencies_valid fixture.so',
                     "_", str(SCRIPT), output], capture_output=True,
                )
                self.assertEqual(result.returncode, expected)

    def test_dual_build_uses_separate_architectures_and_runtime_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            shaders = source / "approach1-compute-encoder/shaders"
            shaders.mkdir(parents=True)
            for shader in SHADERS:
                (shaders / f"{shader}.comp").write_text("shader\n")
            (source / "LICENSE").write_text("license\n")
            (source / "README.md").write_text("readme\n")
            result = subprocess.run(
                ["bash", "-c",
                 'helper=$1; root=$2; set -- help; source "$helper" >/dev/null; '
                 'cmake() { printf "%s\\n" "$*" >> "$root/cmake.log"; '
                 'if [[ "$1" == -S ]]; then local build=$4 arch=64 shader; '
                 '[[ " $* " != *" -DBUILD_32BIT=ON "* ]] || arch=32; '
                 'mkdir -p "$build"; printf "ELF%s fixture" "$arch" > "$build/bc250_drv_video.so"; '
                 'for shader in "${SHADER_NAMES[@]}"; do printf shader > "$build/$shader"; done; fi; }; '
                 'build_runtime "$root/source" "$root/build" "$root/build32" "$root/runtime" 1; '
                 'manifest_layout_valid "$root/runtime/manifest.sha256"',
                 "_", str(SCRIPT), str(root)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            runtime = root / "runtime"
            self.assertEqual((runtime / "dri/bc250_drv_video.so").read_bytes(), b"ELF64 fixture")
            self.assertEqual((runtime / "dri32/bc250_drv_video.so").read_bytes(), b"ELF32 fixture")
            commands = (root / "cmake.log").read_text().splitlines()
            configure = [line for line in commands if line.startswith("-S ")]
            self.assertEqual(len(configure), 2)
            self.assertNotIn("-DBUILD_32BIT=ON", configure[0])
            self.assertIn("-DBUILD_32BIT=ON", configure[1])
            for line in configure:
                self.assertIn("-DBC250_WITH_X264=ON", line)
                self.assertIn("-DBC250_WITH_X265=ON", line)
                self.assertIn("-DBUILD_TESTS=OFF", line)
            self.assertEqual(len(list((runtime / "shaders").iterdir())), 17)

    def test_new_environment_keeps_compute_backends_and_needs_session_reload(self):
        result = subprocess.run(
            ["bash", "-c",
             'helper=$1; set -- help; source "$helper" >/dev/null; '
             'LIBVA_DRIVER_NAME=bc250; LIBVA_DRIVERS_PATH=$(configured_driver_path); '
             'BC250_SHADER_DIR=$COMPAT_DIR/shaders; '
             'unset BC250_H264_BACKEND BC250_HEVC_BACKEND; '
             'if shell_environment_active; then exit 3; fi; '
             'BC250_H264_BACKEND=compute; BC250_HEVC_BACKEND=compute; '
             'shell_environment_active; environment_config; profile_config',
             "_", str(SCRIPT)], capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for variable in ("BC250_H264_BACKEND=compute", "BC250_HEVC_BACKEND=compute"):
            self.assertIn(f"\n{variable}\n", result.stdout)
            self.assertIn(f"\nexport {variable}\n", result.stdout)

    def test_legacy_runtime_removal_does_not_require_current_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            runtime = data / "runtime"
            runtime.mkdir(parents=True)
            (runtime / ".bc250-toolkit-managed").write_text(
                "bc250-toolkit-video-codec-v1\nrelease=v0.5.1\n"
            )
            (runtime / "old-shader.comp.spv").write_bytes(b"legacy")
            (root / "bc250").symlink_to(runtime)
            environment = root / "environment.d/90-bc250-video-codec.conf"
            environment.parent.mkdir()
            environment.write_text("# BC-250 toolkit managed VA-API video codec\n")
            result = subprocess.run(
                ["bash", "-c",
                 'helper=$1; root=$2; set -- help; source "$helper" >/dev/null; '
                 'DATA_DIR=$root/data; RUNTIME_DIR=$DATA_DIR/runtime; '
                 'COMPAT_DIR=$root/bc250; ENV_FILE=$root/environment.d/90-bc250-video-codec.conf; '
                 'PROFILE_FILE=$root/profile; LEGACY_PROFILE_FILE=$root/legacy-profile; '
                 'KEEP_FILE=$root/keep; LOCK_FILE=$root/lock; '
                 'require_root() { :; }; uninstall_codec',
                 "_", str(SCRIPT), str(root)], capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(runtime.exists())
            self.assertFalse((root / "bc250").is_symlink())
            self.assertFalse(environment.exists())

    def test_installer_uses_safe_verified_persistent_layout(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for required in (
            "curl --proto '=https' --tlsv1.2 --fail --location",
            '[[ "$actual" == "$SOURCE_ARCHIVE_SHA256" ]]',
            "unsafe source archive path",
            "unsafe source archive entry type",
            "duplicate source archive entry",
            "sha256sum -c --quiet manifest.sha256",
            "validate_elf64",
            "runtime_dependencies_valid",
            "unavailable runtime dependencies",
            "ldd -r",
            "verify_vaapi_initialization",
            "vainfo --display drm --device",
            "verify_ffmpeg_pipeline",
            "verify_vaapi_initialization_32",
            "-DBUILD_32BIT=ON",
            "validate_elf32",
            "elf_machine_is_i386",
            "no_text_relocations",
            "-Wl,-z,text",
            "-c:v h264_vaapi",
            "-hwaccel vaapi",
            "hwdownload,format=nv12",
            "FFmpeg VA-API H.264 encode and decode",
            "pacman -S --needed --noconfirm",
            "pacman -S --noconfirm",
            "cmake make gcc binutils glibc linux-api-headers pkgconf libva libdrm ffmpeg",
            "lib32-glibc lib32-gcc-libs lib32-libva lib32-libdrm",
            "lib32-vulkan-icd-loader lib32-vulkan-radeon",
            "header:/usr/include/linux/types.h",
            "compiler-link-probe:libva+libdrm+vulkan+openmp",
            "Still missing:",
            "steamos-readonly disable",
            "steamos-readonly enable",
            "/var/lib/bc250-control/video-codec",
            "/var/lib/bc250",
            "/etc/environment.d/90-bc250-video-codec.conf",
            "/etc/profile.d/zz-bc250-video-codec.sh",
            "/etc/atomic-update.conf.d/bc250-video-codec.conf",
            "Refusing to replace an unrecognized runtime",
            "Refusing to remove an unrecognized runtime",
            "Refusing to replace an unrecognized SteamOS runtime path",
            "Refusing to remove an unrecognized SteamOS runtime path",
            "Refusing to replace an unrecognized atomic-update keep list",
            "Refusing to remove an unrecognized atomic-update keep list",
        ):
            self.assertIn(required, source)
        self.assertNotIn("radeonsi_drv_video.so", source)

    def test_shell_profile_loads_after_steamos_libva_profile(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("PROFILE_FILE=\"${BC250_VIDEO_PROFILE_FILE:-/etc/profile.d/zz-bc250-video-codec.sh}\"", source)
        self.assertIn("LEGACY_PROFILE_FILE=/etc/profile.d/90-bc250-video-codec.sh", source)
        self.assertGreater("zz-bc250-video-codec.sh", "libva.sh")

    def test_status_distinguishes_environment_conflict_from_restart(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'helper=$1; set -- help; source "$helper" >/dev/null; '
                "LIBVA_DRIVER_NAME=radeonsi; export LIBVA_DRIVER_NAME; "
                "session_environment_conflicted",
                "_",
                str(SCRIPT),
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0)

    def test_previous_managed_architecture_path_is_restart_not_conflict(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'helper=$1; set -- help; source "$helper" >/dev/null; '
                'LIBVA_DRIVER_NAME=bc250; export LIBVA_DRIVER_NAME; '
                'LIBVA_DRIVERS_PATH="$COMPAT_DIR/dri:$COMPAT_DIR/dri32"; '
                'export LIBVA_DRIVERS_PATH; '
                'BC250_SHADER_DIR="$COMPAT_DIR/shaders"; export BC250_SHADER_DIR; '
                "systemctl() { return 1; }; "
                "! session_environment_conflicted",
                "_",
                str(SCRIPT),
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0)

    def test_environment_uses_standard_steamos_runtime_path(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('COMPAT_DIR="${BC250_VIDEO_COMPAT_DIR:-/var/lib/bc250}"', source)
        self.assertIn('path="$COMPAT_DIR/dri"', source)
        self.assertIn('path="$path:$COMPAT_DIR/dri32"', source)
        self.assertIn("BC250_SHADER_DIR=$COMPAT_DIR/shaders", source)
        self.assertIn('ln -s -- "$RUNTIME_DIR" "$COMPAT_DIR"', source)
        self.assertIn('[[ "$(readlink "$COMPAT_DIR")" == "$RUNTIME_DIR" ]]', source)
        self.assertIn("$COMPAT_DIR\n$ENV_FILE\n$PROFILE_FILE", source)

    def test_environment_adds_32bit_path_only_when_companion_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            environment = root / "environment.d/90-bc250-video-codec.conf"
            runtime = data / "runtime"
            runtime.mkdir(parents=True)
            command = (
                'helper=$1; set -- help; source "$helper" >/dev/null; '
                "environment_config"
            )
            env = os.environ.copy()
            env.update(
                {
                    "BC250_VIDEO_DATA_DIR": str(data),
                    "BC250_VIDEO_COMPAT_DIR": str(root / "bc250"),
                    "BC250_VIDEO_ENV_FILE": str(environment),
                }
            )
            native = subprocess.run(
                ["bash", "-c", command, "_", str(SCRIPT)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn(f"LIBVA_DRIVERS_PATH={root / 'bc250/dri'}\n", native.stdout)
            self.assertNotIn("dri32", native.stdout)

            companion = runtime / "dri32/bc250_drv_video.so"
            companion.parent.mkdir()
            companion.write_bytes(b"ELF32 placeholder")
            dual = subprocess.run(
                ["bash", "-c", command, "_", str(SCRIPT)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn(
                f"LIBVA_DRIVERS_PATH={root / 'bc250/dri'}:{root / 'bc250/dri32'}\n",
                dual.stdout,
            )

    def test_source_extraction_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                for relative, content in (
                    ("LICENSE", b"license\n"),
                    ("README.md", b"readme\n"),
                    ("approach1-compute-encoder/CMakeLists.txt", b"cmake\n"),
                ):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                    bundle.add(path, arcname=f"{SOURCE_ROOT}/{relative}")
                traversal = tarfile.TarInfo(f"{SOURCE_ROOT}/../escape")
                traversal.size = 1
                import io

                bundle.addfile(traversal, io.BytesIO(b"x"))

            destination = root / "extract"
            destination.mkdir()
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'helper=$1; archive=$2; destination=$3; set -- help; '
                    'source "$helper" >/dev/null; extract_source "$archive" "$destination"',
                    "_",
                    str(SCRIPT),
                    str(archive),
                    str(destination),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe source archive path", result.stderr)
            self.assertFalse((root / "escape").exists())

    def test_toolkit_release_and_maintenance_include_component(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        toolkit = (ROOT / "bc250-toolkit.sh").read_text(encoding="utf-8")
        maintenance = (ROOT / "bc250-maintenance.sh").read_text(encoding="utf-8")
        self.assertIn("nct6687d video-codec", workflow)
        self.assertIn("video-codec) echo \"VA-API video codec\"", maintenance)
        self.assertIn("/etc/profile.d/zz-bc250-video-codec.sh", maintenance)
        self.assertIn("/var/lib/bc250", maintenance)
        self.assertIn("/etc/profile.d/90-bc250-video-codec.sh", maintenance)
        self.assertIn(
            "/etc/atomic-update.conf.d/bc250-video-codec.conf", maintenance
        )
        self.assertIn("sudo bash \"$script\" uninstall", maintenance)
        self.assertIn("Include the optional 32-bit companion", toolkit)
        self.assertIn("mode=--with-32bit", toolkit)
        self.assertIn("install --without-32bit", toolkit)

    def test_help_is_non_privileged(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("install", result.stdout)
        self.assertIn("status", result.stdout)
        self.assertIn("test", result.stdout)
        self.assertIn("uninstall", result.stdout)


if __name__ == "__main__":
    unittest.main()
