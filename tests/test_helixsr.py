import hashlib
import json
import os
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bc250-helixsr.sh"
FSR4 = ROOT / "bc250-fsr4.sh"
DLL = b"fixture helix dll\n"
WEIGHTS = b"fixture generated weights\n"

ARCHIVE_FILES = (
    "LICENSE", "README.md", "SOURCE.md", "THIRD_PARTY_NOTICES.md",
    "amd_fidelityfx_dx12.dll", "helixsr-setup.bat", "helixsr-setup.ps1",
    "helixsr-setup.sh", "helixsr.ini", "setup/helixsr_setup.py",
    "setup/kernels/common/fp16.h", "setup/kernels/common/port_cpp.h",
    "setup/kernels/common/port_hlsl.hlsli", "setup/kernels/rt/px_common.h",
    "setup/kernels/rt/px_cpp.h", "setup/kernels/rt/px_hlsl.h",
    "setup/kernels/u5/u5_memory.h", "setup/lib/compact_hlsl.py",
    "setup/lib/compact_u5.py", "setup/lib/extract_ptx.py",
    "setup/lib/extract_weights.py", "setup/lib/family_hlsl.py",
    "setup/lib/fast_tiles.py", "setup/lib/kernels.py", "setup/lib/load_fence.py",
    "setup/lib/ptx2hlsl.py", "setup/lib/ptxsim.py", "setup/lib/regen_kernels.py",
    "setup/lib/samplers.py", "setup/lib/trace_tables.py", "setup/lib/u5_roll.py",
    "setup/lib/u5_rows.py", "setup/lib/family_k/gen_helper.py",
    "setup/lib/family_k/trace_frags.py", "setup/lib/family_k/two_sites.json",
    "setup/lib/family_k/validate.py", "setup/lib/family_u/gen_helper.py",
    "setup/lib/family_u/ptxsim_up.py", "setup/lib/family_u/trace_frags.py",
    "setup/lib/family_u/two_sites.json", "setup/lib/family_u/validate.py",
    "setup/lib/model/launch_synth", "setup/lib/model/launch_synth.cpp",
    "setup/lib/model/launch_synth.exe", "setup/lib/model/model.cpp",
    "setup/lib/model/model.h", "setup/lib/model/model_gen.inc",
)
PINNED_ARCHIVE_EXTRA_FILES = (
    "LICENSE-APACHE-2.0", "helixsr-install.bat", "helixsr-install.sh",
    "setup/helixsr_install.py", "setup/lib/splitk_hlsl.py",
)
# Path inventory only; all contents in these ZIPs are synthetic, never upstream
# binaries or NVIDIA-derived data. The digest is also checked independently.
V2_ARCHIVE_FILES = tuple("""
HelixSR-fsrfg/amd_fidelityfx_dx12.dll
HelixSR-fsrfg/helixsr-fg/nvexec64.dll
HelixSR-fsrfg/helixsr.ini
LICENSE
README.md
SOURCE.md
THIRD_PARTY_NOTICES.md
helixsr-scaler/HelixSR-Scaler-package.txt
helixsr-scaler/Licenses/DirectX_LICENSE.txt
helixsr-scaler/Licenses/FidelityFX_v2_LICENSE.md
helixsr-scaler/Licenses/OptiScaler_LICENSE.txt
helixsr-scaler/Licenses/XeSS_LICENSE.txt
helixsr-scaler/OptiScaler/D3D12_OptiScaler/D3D12Core.dll
helixsr-scaler/OptiScaler/amd_fidelityfx_framegeneration_dx12.dll
helixsr-scaler/OptiScaler/amd_fidelityfx_loader_dx12.dll
helixsr-scaler/OptiScaler/amd_fidelityfx_upscaler_dx12.dll
helixsr-scaler/OptiScaler/amd_fidelityfx_vk.dll
helixsr-scaler/OptiScaler/libxell.dll
helixsr-scaler/OptiScaler/libxess.dll
helixsr-scaler/OptiScaler/libxess_dx11.dll
helixsr-scaler/OptiScaler/libxess_fg.dll
helixsr-scaler/OptiScaler.dll
helixsr-scaler/OptiScaler.ini
helixsr-scaler/README-Linux.txt
helixsr-scaler/README.txt
helixsr-scaler/setup_linux.sh
helixsr-scaler/setup_windows.bat
helixsr-setup.bat
helixsr-setup.ps1
helixsr-setup.sh
helixsr-uninstall.bat
helixsr-uninstall.ps1
helixsr-uninstall.sh
setup/fg/data/3109/fused.txt
setup/fg/data/3109/helpers.launches.txt
setup/fg/data/3109/helpers.ptx.sha256
setup/fg/data/3109/helpers.sha256
setup/fg/data/3109/natives.txt
setup/fg/data/3109/postproc.txt
setup/fg/data/3109/sm69.txt
setup/fg/data/3109/table.txt
setup/fg/data/3109/weights.sha256
setup/fg/data/fgprog.small.txt
setup/fg/data/fgprog.txt
setup/fg/data/kernels.ptx.sha256
setup/fg/data/kernels.sha256
setup/fg/data/natives.txt
setup/fg/data/samplers.json
setup/fg/data/vk/k0102.relay.spv
setup/fg/data/vk/k0102.vk
setup/fg/data/vk/k0102.vk.spv
setup/fg/data/vk/k0105.relay.spv
setup/fg/data/vk/k0105.vk
setup/fg/data/vk/k0105.vk.spv
setup/fg/data/vk/vkreset.cso
setup/fg/data/weights.sha256
setup/fg/extract_ptx.py
setup/fg/fg_rec_from_dll.py
setup/fg/fg_setup.py
setup/fg/fg_weights_from_dll.py
setup/fg/translator/kernels/native/compose.hlsl
setup/fg/translator/kernels/native/conv3.hlsl
setup/fg/translator/kernels/native/conv3b.hlsl
setup/fg/translator/kernels/native/conv3g.hlsl
setup/fg/translator/kernels/native/conv3p.hlsl
setup/fg/translator/kernels/native/conv3s.hlsl
setup/fg/translator/kernels/native/conv3t.hlsl
setup/fg/translator/kernels/native/conv3u.hlsl
setup/fg/translator/kernels/native/decfuse.hlsl
setup/fg/translator/kernels/native/pool2.hlsl
setup/fg/translator/kernels/native/scat11.hlsl
setup/fg/translator/kernels/native/tileskip.hlsl
setup/fg/translator/kernels/native/warpin.hlsl
setup/fg/translator/kernels/rt/px_common.h
setup/fg/translator/kernels/rt/px_cpp.h
setup/fg/translator/kernels/rt/px_hlsl.h
setup/fg/translator/kernels/vk/build_spv.sh
setup/fg/translator/kernels/vk/convh.comp
setup/fg/translator/kernels/vk/convs.comp
setup/fg/translator/kernels/vk/convt.comp
setup/fg/translator/kernels/vk/convt2.comp
setup/fg/translator/kernels/vk/convt3.comp
setup/fg/translator/kernels/vk/convt4.comp
setup/fg/translator/kernels/vk/convu.comp
setup/fg/translator/kernels/vk/convw.comp
setup/fg/translator/kernels/vk/relays.comp
setup/fg/translator/kernels/vk/relayu.comp
setup/fg/translator/kernels/vk/relayw.comp
setup/fg/translator/kernels/vk/unet.txt
setup/fg/translator/kernels/vk/vkreset.hlsl
setup/fg/translator/tools/fused.py
setup/fg/translator/tools/gst8quad.py
setup/fg/translator/tools/kernel_table.py
setup/fg/translator/tools/maskskip.py
setup/fg/translator/tools/native.py
setup/fg/translator/tools/ptx2hlsl.py
setup/fg/translator/tools/ptx_prep.py
setup/fg/translator/tools/ptxsim.py
setup/fg/translator/tools/tablelines.py
setup/fg/translator/tools/translate_all.py
setup/helixsr_bridge.py
setup/helixsr_games.py
setup/helixsr_install.py
setup/helixsr_setup.py
setup/kernels/common/fp16.h
setup/kernels/common/port_cpp.h
setup/kernels/common/port_hlsl.hlsli
setup/kernels/rt/px_common.h
setup/kernels/rt/px_cpp.h
setup/kernels/rt/px_hlsl.h
setup/kernels/u5/u5_memory.h
setup/lib/compact_hlsl.py
setup/lib/compact_u5.py
setup/lib/extract_ptx.py
setup/lib/extract_weights.py
setup/lib/family_hlsl.py
setup/lib/family_k/gen_helper.py
setup/lib/family_k/trace_frags.py
setup/lib/family_k/two_sites.json
setup/lib/family_k/validate.py
setup/lib/family_u/gen_helper.py
setup/lib/family_u/ptxsim_up.py
setup/lib/family_u/trace_frags.py
setup/lib/family_u/two_sites.json
setup/lib/family_u/validate.py
setup/lib/fast_tiles.py
setup/lib/k5_xform.py
setup/lib/kernels.py
setup/lib/load_fence.py
setup/lib/model/launch_synth
setup/lib/model/launch_synth.cpp
setup/lib/model/launch_synth.exe
setup/lib/model/model.cpp
setup/lib/model/model.h
setup/lib/model/model_gen.inc
setup/lib/model/runtime-licenses/Zig-MIT.txt
setup/lib/model/runtime-licenses/libcxx-LICENSE.txt
setup/lib/model/runtime-licenses/libcxxabi-LICENSE.txt
setup/lib/model/runtime-licenses/libunwind-LICENSE.txt
setup/lib/model/runtime-licenses/musl-COPYRIGHT.txt
setup/lib/ptx2hlsl.py
setup/lib/ptxsim.py
setup/lib/regen_kernels.py
setup/lib/samplers.py
setup/lib/setup_shader_jobs.py
setup/lib/splitk_hlsl.py
setup/lib/trace_tables.py
setup/lib/u5_roll.py
setup/lib/u5_rows.py
""".split())

FAKE_SETUP = b"""#!/usr/bin/env bash
set -euo pipefail
out=$1
shift
source_sha=be6e434a94ca32499515eb62ca0e6c274526055d568d0426e4c652dcdfb6ee6e
while (($#)); do
    if [[ $1 == --dlss ]]; then
        source_sha=$(sha256sum "$2" | cut -d' ' -f1)
        shift 2
    else
        shift
    fi
done
python3 - "$out" "$source_sha" <<'PY'
import hashlib, json, struct, sys
from pathlib import Path
out = Path(sys.argv[1])
weights = b"fixture generated weights\\n"
(out / "helixsr_weights.bin").write_bytes(weights)
blobs = [(f"shader-{index}".encode(), bytes([index % 256])) for index in range(60)]
offset = 16 + 40 * len(blobs)
table = []
body = []
for name, blob in blobs:
    table.append(struct.pack("<32sII", name, offset, len(blob)))
    body.append(blob)
    offset += len(blob)
(out / "helixsr_kernels.pak").write_bytes(
    b"HXSRKPAK" + struct.pack("<II", 2, len(blobs)) + b"".join(table) + b"".join(body)
)
(out / "helixsr_setup.json").write_text(json.dumps({
    "source_sha256": sys.argv[2],
    "ptx_target": "sm_89",
    "shaders": len(blobs),
    "wave64": True,
    "weights_sha256": hashlib.sha256(weights).hexdigest(),
}) + "\\n", encoding="ascii")
PY
"""

FAKE_V2_BUILD = (
    "import json, subprocess, sys\nfrom pathlib import Path\n"
    "assert '--no-fg' in sys.argv and '--separate-files' in sys.argv\n"
    "assert '--dxc' in sys.argv\n"
    "root = Path(sys.argv[1]); out = root / 'HelixSR-fsrfg'\n"
    # Reuse only our own synthetic generator, not downloaded setup code.
    "subprocess.run(['bash', '-c', "
    + repr(FAKE_SETUP.decode().replace("range(60)", "range(200)"))
    + ", '--', str(out), *sys.argv[2:]], check=True)\n"
    "meta = json.loads((out / 'helixsr_setup.json').read_text())\n"
    "meta.update(fp32=True, fp32h=True)\n"
    "(root / 'helixsr_setup.json').write_text(json.dumps(meta))\n"
    "(out / 'helixsr_setup.json').unlink()\n"
).encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def archive_entry(name: str, value: bytes, mode: int = 0o644) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | mode) << 16
    return info


def make_archive(
    path: Path, *, release="1.4.3", dll=DLL, unsafe_name=None, symlink=False,
    extra_entries=(), build=FAKE_V2_BUILD,
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        files = (*ARCHIVE_FILES, *PINNED_ARCHIVE_EXTRA_FILES) if release == "1.4.3" else V2_ARCHIVE_FILES
        for relative in files:
            name = f"HelixSR-{release}/{relative}"
            value = b"fixture:" + relative.encode("ascii") + b"\n"
            mode = 0o644
            if relative in ("amd_fidelityfx_dx12.dll", "HelixSR-fsrfg/amd_fidelityfx_dx12.dll"):
                value = dll
            elif relative == "helixsr.ini":
                value = b"[Forwarding]\nDll =\nUpscalerDll =\n"
            elif relative == "HelixSR-fsrfg/helixsr.ini":
                value = b"[DlssFrameGeneration]\n; no FG in the managed drop-in\nEnabled = true\n[Log]\nEnabled = true\n"
            elif relative == "setup/helixsr_setup.py" and release != "1.4.3":
                value = build
            elif relative == "helixsr-setup.sh":
                value = FAKE_SETUP
                mode = 0o755
            elif relative == "setup/lib/model/launch_synth":
                mode = 0o755
            archive.writestr(archive_entry(name, value, mode), value)
        for name in extra_entries:
            value = b"future safe upstream file\n"
            archive.writestr(archive_entry(name, value), value)
        if unsafe_name is not None:
            archive.writestr(archive_entry(unsafe_name, b"unsafe\n"), b"unsafe\n")
        if symlink:
            name = f"HelixSR-{release}/setup/lib/model/launch_synth"
            # Replace the archive with one containing a symlink at an expected path.
    if symlink:
        values = {}
        with zipfile.ZipFile(path) as source:
            for entry in source.infolist():
                values[entry.filename] = source.read(entry)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, value in values.items():
                if name.endswith("setup/lib/model/launch_synth"):
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, b"/tmp/outside")
                else:
                    archive.writestr(archive_entry(name, value), value)
    return path


class HelixSRTests(unittest.TestCase):
    release = "1.4.3"
    shader_count = 60

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/tmp/opencode")
        self.root = Path(self.temporary.name)
        self.archive = make_archive(self.root / f"HelixSR-{self.release}.zip", release=self.release)
        self.state = self.root / "state"
        self.game = self.root / "game with spaces"
        self.game.mkdir()
        # The build fixture never uses numpy; satisfy only the helper's
        # dependency preflight without installing packages on the test host.
        fixture_python = self.root / "fixture-python"
        fixture_python.mkdir()
        (fixture_python / "numpy.py").write_text("# synthetic build dependency\n")
        self.env = {
            **os.environ,
            "HOME": str(self.root / "home"),
            "PYTHONPATH": str(fixture_python),
            "BC250_HELIXSR_STATE_DIR": str(self.state),
            "BC250_HELIXSR_RELEASE": f"v{self.release}",
            "BC250_HELIXSR_ARCHIVE": str(self.archive),
            "BC250_HELIXSR_ARCHIVE_SHA256": sha256_file(self.archive),
            "BC250_HELIXSR_DLL_SHA256": sha256_bytes(DLL),
            "BC250_HELIXSR_WEIGHTS_SHA256": sha256_bytes(WEIGHTS),
            "BC250_HELIXSR_DXC": "/bin/true",  # synthetic builder never invokes it
            "BC250_FSR4_STATE_DIR": str(self.root / "fsr4"),
            "BC250_FSR4_LOCK_FILE": str(self.root / "fsr4.lock"),
            "BC250_OPTISCALER_STATE_DIR": str(self.root / "optiscaler"),
            "BC250_OPTISCALER_LOCK_FILE": str(self.root / "optiscaler.lock"),
        }
        if self.release == "2.0.0":
            self.env.pop("BC250_HELIXSR_RELEASE")  # exercise the actual default

    def tearDown(self):
        self.temporary.cleanup()

    def run_helper(self, *args, env=None, check=True):
        return subprocess.run(
            ["bash", str(HELPER), *map(str, args)],
            env=env or self.env,
            check=check,
            capture_output=True,
            text=True,
        )

    def latest_environment(self, release="2.0.0", *, published_digest=None, extra_entries=()):
        archive = make_archive(
            self.root / f"HelixSR-{release}.zip", release=release,
            extra_entries=extra_entries,
        )
        digest = published_digest or sha256_file(archive)
        asset_name = f"HelixSR-{release}.zip"
        asset_url = (
            f"https://github.com/lonewolf0622/HelixSR/releases/download/v{release}/{asset_name}"
        )
        metadata = self.root / "latest-release.json"
        metadata.write_text(json.dumps({
            "tag_name": f"v{release}",
            "assets": [{
                "name": asset_name,
                "browser_download_url": asset_url,
                "digest": f"sha256:{digest}",
            }],
        }), encoding="utf-8")
        curl_dir = self.root / "fake-bin"
        curl_dir.mkdir(exist_ok=True)
        curl = curl_dir / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import os, shutil, sys\n"
            "args = sys.argv[1:]\n"
            "url = next(value for value in args if value.startswith('https://'))\n"
            "if url != 'https://api.github.com/repos/lonewolf0622/HelixSR/releases/latest':\n"
            "    raise SystemExit('unexpected curl URL: ' + url)\n"
            "shutil.copyfile(os.environ['BC250_HELIXSR_TEST_LATEST_JSON'], args[args.index('-o') + 1])\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        return {
            **self.env,
            "PATH": str(curl_dir) + os.pathsep + self.env["PATH"],
            "BC250_HELIXSR_ARCHIVE": str(archive),
            "BC250_HELIXSR_TEST_LATEST_JSON": str(metadata),
        }

    def prepare(self):
        return self.run_helper("prepare")

    def target(self, name="amd_fidelityfx_upscaler_dx12.dll", value=b"original dll\n"):
        path = self.game / name
        path.write_bytes(value)
        path.chmod(0o751)
        return path

    def records(self):
        return json.loads(self.run_helper("records-json").stdout)

    def test_script_parses_and_help_lists_interface(self):
        subprocess.run(["bash", "-n", str(HELPER)], check=True)
        help_result = self.run_helper("--help")
        for command in ("prepare", "payload-status", "records-json", "probe", "count", "install", "uninstall", "purge"):
            self.assertIn(command, help_result.stdout)
        self.assertIn("install TARGET_DLL [EXPECTED_ID]", help_result.stdout)
        self.assertIn("uninstall TARGET_DLL [EXPECTED_ID]", help_result.stdout)
        self.assertIn("prepare [--latest] [DLSS_DLL]", help_result.stdout)

    def test_latest_option_uses_published_digest_and_payload_identity(self):
        env = self.latest_environment()
        self.run_helper("prepare", "--latest", env=env)

        manifest = json.loads((self.state / "payload/manifest.json").read_text())
        self.assertEqual(manifest["release"], "v2.0.0")
        self.assertEqual(manifest["dllSha256"], sha256_bytes(DLL))
        self.assertEqual(self.run_helper("payload-status").stdout, "ready\n")
        self.assertEqual(self.records()["release"], "v2.0.0")

        # Preparing without --latest returns to the known, checksum-pinned stable release.
        self.prepare()
        stable_manifest = json.loads((self.state / "payload/manifest.json").read_text())
        self.assertEqual(stable_manifest["release"], f"v{self.release}")
        self.assertEqual(self.run_helper("payload-status").stdout, "ready\n")

    def test_latest_option_rejects_an_asset_digest_mismatch(self):
        env = self.latest_environment(published_digest="0" * 64)
        refused = self.run_helper("prepare", "--latest", env=env, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("checksum mismatch", refused.stderr)
        self.assertFalse((self.state / "payload").exists())

    def test_prepare_validates_output_and_repairs_private_modes(self):
        self.prepare()
        payload = self.state / "payload"
        status = self.run_helper("payload-status")
        self.assertEqual(status.stdout, "ready\n")
        self.assertEqual(stat.S_IMODE(payload.stat().st_mode), 0o700)
        for path in payload.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        manifest = json.loads((payload / "manifest.json").read_text())
        self.assertEqual(manifest["shaderCount"], self.shader_count)
        self.assertEqual(manifest["weightsSha256"], sha256_bytes(WEIGHTS))
        self.assertEqual(manifest["kernelsSha256"], sha256_file(payload / "helixsr_kernels.pak"))

        (payload / "helixsr.ini").chmod(0o000)
        invalid = self.run_helper("payload-status", check=False)
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(invalid.stdout, "invalid\n")
        self.prepare()
        self.assertEqual(stat.S_IMODE((payload / "helixsr.ini").stat().st_mode), 0o600)

    def test_prepare_passes_a_local_dlss_file_and_attests_its_hash(self):
        dlss = self.root / "local nvngx_dlss.dll"
        dlss.write_bytes(b"local dlss fixture\n")

        self.run_helper("prepare", dlss)

        manifest = json.loads((self.state / "payload/manifest.json").read_text())
        self.assertEqual(manifest["sourceSha256"], sha256_file(dlss))
        self.assertFalse((self.state / "payload/nvngx_dlss.dll").exists())

    def test_prepare_rejects_checksum_layout_and_symlink_entries(self):
        mismatch = {**self.env, "BC250_HELIXSR_ARCHIVE_SHA256": "0" * 64}
        result = self.run_helper("prepare", env=mismatch, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)

        for label, archive in (
            ("layout", make_archive(self.root / "bad-layout.zip", release=self.release, unsafe_name="outside")),
            ("symlink", make_archive(self.root / "bad-symlink.zip", release=self.release, symlink=True)),
        ):
            state = self.root / f"state-{label}"
            env = {
                **self.env,
                "BC250_HELIXSR_STATE_DIR": str(state),
                "BC250_HELIXSR_LOCK_FILE": str(state) + ".lock",
                "BC250_HELIXSR_ARCHIVE": str(archive),
                "BC250_HELIXSR_ARCHIVE_SHA256": sha256_file(archive),
            }
            refused = self.run_helper("prepare", env=env, check=False)
            self.assertNotEqual(refused.returncode, 0)
            self.assertRegex(refused.stderr, "unexpected payload layout|Unsafe HelixSR archive entry")
            self.assertFalse((state / "payload").exists())

    def test_payload_tampering_is_invalid_and_purge_preserves_records(self):
        self.prepare()
        (self.state / "payload/helixsr_weights.bin").write_bytes(b"tampered\n")
        status = self.run_helper("payload-status", check=False)
        self.assertEqual(status.returncode, 2)
        self.assertEqual(status.stdout, "invalid\n")
        self.run_helper("purge")
        self.assertEqual(self.run_helper("payload-status", check=False).stdout, "not-prepared\n")

    def test_purge_preserves_rollback_record_and_uninstallability(self):
        self.prepare()
        target = self.target()
        identifier = hashlib.sha256(str(target).encode()).hexdigest()
        record = self.state / "installs" / identifier
        self.run_helper("install", target)

        self.run_helper("purge")

        self.assertTrue(record.is_dir())
        status = self.records()
        self.assertEqual(status["payloadState"], "not-prepared")
        self.assertEqual(status["state"], "ready")
        self.assertEqual(target.read_bytes(), DLL)
        self.run_helper("uninstall", target)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertFalse(record.exists())

    def test_uninstall_all_refuses_hidden_interrupted_record(self):
        interrupted = self.state / "installs/.helixsr-record.interrupted"
        interrupted.mkdir(parents=True)
        (interrupted / "record.json").write_text("{}", encoding="ascii")

        result = self.run_helper("uninstall", "--all", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(interrupted.is_dir())

    def test_install_uninstall_restores_target_and_all_sidecars_exactly(self):
        self.prepare()
        target = self.target()
        originals = {}
        for index, name in enumerate(("helixsr_weights.bin", "helixsr_kernels.pak", "helixsr.ini")):
            path = self.game / name
            path.write_bytes(f"original {name}\n".encode())
            path.chmod(0o640 + index)
            originals[name] = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
        self.run_helper("install", target)
        self.assertEqual(target.read_bytes(), DLL)
        self.assertEqual((self.game / "helixsr_weights.bin").read_bytes(), WEIGHTS)
        self.assertEqual(self.records()["state"], "ready")
        self.run_helper("uninstall", target)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o751)
        for name, (value, mode) in originals.items():
            self.assertEqual((self.game / name).read_bytes(), value)
            self.assertEqual(stat.S_IMODE((self.game / name).stat().st_mode), mode)
        self.assertEqual(self.records()["state"], "not-installed")

    def test_full_fidelityfx_target_gets_explicit_forwarding_and_rolls_back(self):
        self.prepare()
        target = self.target("amd_fidelityfx_dx12.dll", b"game fidelityfx\n")
        self.run_helper("install", target)
        forward = self.game / "amd_fidelityfx_dx12.bc250-helixsr-original.dll"
        self.assertEqual(forward.read_bytes(), b"game fidelityfx\n")
        self.assertIn(
            "Dll = amd_fidelityfx_dx12.bc250-helixsr-original.dll",
            (self.game / "helixsr.ini").read_text(),
        )
        self.run_helper("uninstall", target)
        self.assertEqual(target.read_bytes(), b"game fidelityfx\n")
        self.assertFalse(forward.exists())
        self.assertFalse((self.game / "helixsr.ini").exists())

    def test_modified_runtime_refuses_uninstall(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        weights = self.game / "helixsr_weights.bin"
        weights.write_bytes(b"user replacement\n")
        refused = self.run_helper("uninstall", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("changed outside the toolkit", refused.stderr)
        self.assertEqual(weights.read_bytes(), b"user replacement\n")

    def test_role_spoof_cannot_hide_modified_weights_or_remove_record(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        identifier = hashlib.sha256(str(target).encode()).hexdigest()
        record_dir = self.state / "installs" / identifier
        record_path = record_dir / "record.json"
        record = json.loads(record_path.read_text())
        weights_entry = next(
            entry for entry in record["files"]
            if entry["name"] == "helixsr_weights.bin"
        )
        weights_entry["role"] = "config"
        record_path.write_text(json.dumps(record, separators=(",", ":")) + "\n")
        weights = self.game / "helixsr_weights.bin"
        weights.write_bytes(b"modified after role spoof\n")

        status = self.records()
        self.assertEqual(status["state"], "invalid")
        self.assertEqual(status["invalidRecordCount"], 1)
        refused = self.run_helper("uninstall", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("record file role is invalid", refused.stderr)
        self.assertTrue(record_dir.is_dir())
        self.assertEqual(weights.read_bytes(), b"modified after role spoof\n")

    def test_record_rejects_boolean_schema_modes_and_nonboolean_preserve(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        identifier = hashlib.sha256(str(target).encode()).hexdigest()
        record_path = self.state / "installs" / identifier / "record.json"
        original = json.loads(record_path.read_text())
        mutations = (
            lambda record: record.__setitem__("schemaVersion", True),
            lambda record: record["files"][0].__setitem__("installedMode", True),
            lambda record: record["files"][0]["original"].__setitem__("mode", True),
            lambda record: record["files"][1].__setitem__("preserve", 0),
            lambda record: record["files"][0].__setitem__("original", None),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                record = json.loads(json.dumps(original))
                mutate(record)
                record_path.write_text(json.dumps(record, separators=(",", ":")) + "\n")
                status = self.records()
                self.assertEqual(status["state"], "invalid")
                self.assertEqual(status["invalidRecordCount"], 1)
        record_path.write_text(json.dumps(original, separators=(",", ":")) + "\n")
        self.run_helper("uninstall", target)

    def test_expected_id_binds_install_and_uninstall_to_canonical_target(self):
        self.prepare()
        target = self.target()
        identifier = hashlib.sha256(str(target.resolve()).encode()).hexdigest()

        malformed = self.run_helper("install", target, "A" * 64, check=False)
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("64 lowercase hexadecimal", malformed.stderr)
        mismatch = self.run_helper("install", target, "0" * 64, check=False)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("does not match the canonical target path", mismatch.stderr)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertEqual(self.records()["state"], "not-installed")

        linked_game = self.root / "linked game"
        linked_game.symlink_to(self.game, target_is_directory=True)
        linked_target = linked_game / target.name
        self.run_helper("install", linked_target, identifier)
        self.assertEqual(target.read_bytes(), DLL)
        refused = self.run_helper("uninstall", linked_target, "0" * 64, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("does not match the canonical target path", refused.stderr)
        self.assertEqual(target.read_bytes(), DLL)
        self.assertEqual(self.records()["state"], "ready")
        self.run_helper("uninstall", linked_target, identifier)
        self.assertEqual(target.read_bytes(), b"original dll\n")

    def test_expected_id_mismatch_is_read_only_before_state_setup(self):
        target = self.target()
        isolated_state = self.root / "isolated-state"
        env = {
            **self.env,
            "BC250_HELIXSR_STATE_DIR": str(isolated_state),
            "BC250_HELIXSR_LOCK_FILE": str(isolated_state) + ".lock",
        }

        refused = self.run_helper("install", target, "0" * 64, env=env, check=False)

        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("does not match the canonical target path", refused.stderr)
        self.assertFalse(isolated_state.exists())
        self.assertFalse(Path(str(isolated_state) + ".lock").exists())
        self.assertEqual(target.read_bytes(), b"original dll\n")

    def test_missing_target_is_restored_during_recovery(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        target.unlink()

        self.assertEqual(self.records()["records"][0]["state"], "restorable")
        self.run_helper("uninstall", target)

        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o751)

    def test_install_resumes_an_interrupted_target_quarantine(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        suffix = hashlib.sha256(target.name.encode()).hexdigest()[:24]
        recovery = self.game / f".bc250-helixsr-{suffix}.rollback"
        target.rename(recovery)

        self.run_helper("install", target)

        self.assertEqual(target.read_bytes(), DLL)
        self.assertFalse(recovery.exists())
        self.assertEqual(self.records()["state"], "ready")

    def test_user_created_ini_is_preserved_but_changed_collision_is_refused(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        ini = self.game / "helixsr.ini"
        ini.write_bytes(b"user settings\n")
        self.run_helper("uninstall", target)
        self.assertEqual(ini.read_bytes(), b"user settings\n")

        target.write_bytes(b"second original\n")
        ini.write_bytes(b"preexisting settings\n")
        self.run_helper("install", target)
        ini.write_bytes(b"ambiguous edit\n")
        refused = self.run_helper("uninstall", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(ini.read_bytes(), b"ambiguous edit\n")

    def test_update_preserves_safely_edited_toolkit_ini(self):
        self.prepare()
        target = self.target()
        self.run_helper("install", target)
        ini = self.game / "helixsr.ini"
        ini.write_bytes(b"user settings for update\n")
        updated_dll = b"updated fixture helix dll\n"
        archive = make_archive(
            self.root / f"update/HelixSR-{self.release}.zip",
            release=self.release, dll=updated_dll,
        )
        update_env = {
            **self.env,
            "BC250_HELIXSR_ARCHIVE": str(archive),
            "BC250_HELIXSR_ARCHIVE_SHA256": sha256_file(archive),
            "BC250_HELIXSR_DLL_SHA256": sha256_bytes(updated_dll),
        }

        self.run_helper("prepare", env=update_env)
        self.run_helper("install", target, env=update_env)

        self.assertEqual(target.read_bytes(), updated_dll)
        self.assertEqual(ini.read_bytes(), b"user settings for update\n")
        self.assertEqual(
            json.loads(self.run_helper("records-json", env=update_env).stdout)["state"],
            "ready",
        )
        self.run_helper("uninstall", target, env=update_env)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertEqual(ini.read_bytes(), b"user settings for update\n")

    def test_cross_manager_exclusion_and_records_json(self):
        self.prepare()
        target = self.target()
        fsr_record = self.root / "fsr4/installs" / hashlib.sha256(str(target).encode()).hexdigest()
        fsr_record.mkdir(parents=True)
        (fsr_record / "target").write_text(str(target) + "\n", encoding="utf-8")
        refused = self.run_helper("install", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("managed by FSR4", refused.stderr)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        (self.root / "fsr4").rename(self.root / "fsr4-disabled")

        install_path = str(self.game.resolve())
        identifier = hashlib.sha256(install_path.encode()).hexdigest()
        opti_record = self.root / "optiscaler/installs" / identifier
        opti_record.mkdir(parents=True)
        (opti_record / "record.json").write_text(json.dumps({
            "candidateId": identifier, "installPath": install_path,
        }), encoding="utf-8")
        refused = self.run_helper("install", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("managed by OptiScaler", refused.stderr)
        (self.root / "optiscaler").rename(self.root / "optiscaler-disabled")

        self.run_helper("install", target)
        data = self.records()
        self.assertEqual(data["release"], f"v{self.release}")
        self.assertEqual(data["dllSha256"], sha256_bytes(DLL))
        self.assertEqual(data["payloadState"], "ready")
        self.assertEqual(data["invalidRecordCount"], 0)
        self.assertEqual(data["records"], [{
            "targetId": hashlib.sha256(str(target).encode()).hexdigest(),
            "targetPath": str(target), "release": f"v{self.release}",
            "state": "ready", "currentRelease": True,
        }])

        fsr_env = {**self.env, "BC250_HELIXSR_STATE_DIR": str(self.state)}
        fsr_refused = subprocess.run(
            ["bash", str(FSR4), "install", str(target)], env=fsr_env,
            check=False, capture_output=True, text=True,
        )
        self.assertNotEqual(fsr_refused.returncode, 0)
        self.assertIn("managed by HelixSR", fsr_refused.stderr)

    def test_records_json_reports_invalid_record_and_unsafe_state(self):
        invalid = self.state / "installs/not-an-id"
        invalid.mkdir(parents=True)
        data = self.records()
        self.assertEqual(data["state"], "invalid")
        self.assertEqual(data["invalidRecordCount"], 1)
        self.assertEqual(data["records"][0]["state"], "invalid")

        unsafe_state = self.root / "unsafe-state"
        outside = self.root / "outside-state"
        outside.mkdir()
        unsafe_state.symlink_to(outside, target_is_directory=True)
        env = {
            **self.env,
            "BC250_HELIXSR_STATE_DIR": str(unsafe_state),
            "BC250_HELIXSR_LOCK_FILE": str(self.root / "unsafe.lock"),
        }
        unsafe = json.loads(self.run_helper("records-json", env=env).stdout)
        self.assertEqual(unsafe["state"], "invalid")
        self.assertEqual(unsafe["payloadState"], "invalid")
        self.assertEqual(unsafe["invalidRecordCount"], 1)


class HelixSRV2Tests(HelixSRTests):
    release = "2.0.0"
    shader_count = 200

    def legacy_install(self, target_name="amd_fidelityfx_dx12.dll"):
        legacy_dll = b"legacy fixture helix dll\n"
        archive = make_archive(self.root / "legacy/HelixSR-1.4.3.zip", dll=legacy_dll)
        env = {
            **self.env,
            "BC250_HELIXSR_RELEASE": "v1.4.3",
            "BC250_HELIXSR_ARCHIVE": str(archive),
            "BC250_HELIXSR_ARCHIVE_SHA256": sha256_file(archive),
            "BC250_HELIXSR_DLL_SHA256": sha256_bytes(legacy_dll),
        }
        target = self.target(target_name)
        self.run_helper("prepare", env=env)
        self.run_helper("install", target, env=env)
        return target

    def test_v2_exact_path_inventory_and_build_only_output(self):
        self.assertEqual(len(V2_ARCHIVE_FILES), 149)
        self.assertEqual(
            sha256_bytes("\n".join(sorted(V2_ARCHIVE_FILES)).encode()),
            "779f383db3dd5c36a154ced20bf02d6a4802302b08be2352d22b6d2321967997",
        )
        self.prepare()
        payload = self.state / "payload"
        self.assertEqual({p.name for p in payload.iterdir()}, {
            "amd_fidelityfx_dx12.dll", "helixsr_weights.bin", "helixsr_kernels.pak",
            "helixsr.ini", "helixsr_setup.json", "manifest.json",
        })
        ini = (payload / "helixsr.ini").read_text()
        self.assertIn("[DlssFrameGeneration]\n; no FG in the managed drop-in\nEnabled = false", ini)
        self.assertIn("[Log]\nEnabled = true", ini)
        metadata = json.loads((payload / "helixsr_setup.json").read_text())
        for key in ("wave64", "fp32", "fp32h"):
            self.assertIs(metadata[key], True)

    def test_latest_fails_closed_on_unknown_layout_before_running_setup(self):
        self.prepare()
        before = (self.state / "payload/manifest.json").read_bytes()
        env = self.latest_environment(
            release="2.0.1", extra_entries=("HelixSR-2.0.1/new-loader.dll",),
        )
        refused = self.run_helper("prepare", "--latest", env=env, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("unqualified v2 payload layout", refused.stderr)
        self.assertEqual((self.state / "payload/manifest.json").read_bytes(), before)

    def test_current_latest_does_not_bypass_stable_dll_pin(self):
        env = self.latest_environment()
        env["BC250_HELIXSR_DLL_SHA256"] = "0" * 64
        refused = self.run_helper("prepare", "--latest", env=env, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("DLL checksum mismatch", refused.stderr)
        self.assertFalse((self.state / "payload").exists())

    def test_missing_dxc_fails_without_running_wrapper_or_mutating_game(self):
        target = self.target()
        env = {**self.env, "BC250_HELIXSR_DXC": str(self.root / "missing-dxc")}
        refused = self.run_helper("prepare", env=env, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("No packages will be installed", refused.stderr)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertFalse((self.state / "payload").exists())

    def test_missing_numpy_fails_before_build_without_package_install(self):
        (Path(self.env["PYTHONPATH"]) / "numpy.py").write_text("raise ImportError('fixture missing numpy')\n")
        refused = self.run_helper("prepare", check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("requires numpy", refused.stderr)
        self.assertIn("No packages will be installed", refused.stderr)
        self.assertFalse((self.state / "payload").exists())

    def test_old_prepared_payload_is_not_silently_reused(self):
        target = self.legacy_install()
        status = self.run_helper("payload-status", check=False)
        self.assertEqual((status.returncode, status.stdout), (2, "invalid\n"))
        self.assertEqual(self.records()["state"], "upgrade-required")
        refused = self.run_helper("install", target, check=False)
        self.assertNotEqual(refused.returncode, 0)
        # Removal requires neither the old archive nor preparing v2.
        self.run_helper("purge")
        self.run_helper("uninstall", target)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertEqual(self.records()["state"], "not-installed")

    def test_upgrade_old_install_retains_original_rollback_and_user_ini(self):
        target = self.legacy_install()
        ini = self.game / "helixsr.ini"
        ini.write_bytes(b"[Forwarding]\nDll = amd_fidelityfx_dx12.bc250-helixsr-original.dll\n; user edit\n")
        identifier = sha256_bytes(str(target).encode())
        record_path = self.state / "installs" / identifier / "record.json"
        old_record = json.loads(record_path.read_text())
        self.prepare()
        self.assertEqual(self.records()["state"], "upgrade-required")
        self.run_helper("install", target)
        record = json.loads(record_path.read_text())
        self.assertEqual(record["release"], "v2.0.0")
        self.assertEqual(target.read_bytes(), DLL)
        self.assertEqual(record["files"][0]["original"], old_record["files"][0]["original"])
        self.assertEqual(self.records()["state"], "ready")
        self.assertIn(b"user edit", ini.read_bytes())
        self.run_helper("purge")
        self.run_helper("uninstall", "--all")
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertFalse((self.game / "helixsr_weights.bin").exists())
        self.assertFalse((self.game / "helixsr_kernels.pak").exists())
        self.assertFalse((self.game / "amd_fidelityfx_dx12.bc250-helixsr-original.dll").exists())
        self.assertIn(b"user edit", ini.read_bytes())

    def test_rejects_legacy_schema_and_partial_v2_shader_variants(self):
        self.prepare()
        metadata_path = self.state / "payload/helixsr_setup.json"
        original_bytes = metadata_path.read_bytes()
        original = json.loads(original_bytes)
        manifest_path = self.state / "payload/manifest.json"
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        mutations = (
            lambda v: v.pop("fp32"),
            lambda v: v.__setitem__("fp32h", False),
            lambda v: v.__setitem__("wave64", 1),
            lambda v: v.__setitem__("shaders", 60),
            lambda v: v.__setitem__("shaders", True),
        )
        for mutate in mutations:
            value = dict(original)
            mutate(value)
            metadata_path.write_text(json.dumps(value))
            # Keep the manifest's file hash consistent so validation must reject
            # the schema itself, not merely detect a changed metadata file.
            manifest["setupSha256"] = sha256_file(metadata_path)
            manifest_path.write_text(json.dumps(manifest))
            self.assertEqual(self.run_helper("payload-status", check=False).stdout, "invalid\n")
        metadata_path.write_bytes(original_bytes)
        manifest_path.write_bytes(manifest_bytes)
        self.assertEqual(self.run_helper("payload-status").stdout, "ready\n")

    def test_modified_legacy_runtime_blocks_upgrade_and_removal(self):
        target = self.legacy_install()
        weights = self.game / "helixsr_weights.bin"
        weights.write_bytes(b"user replacement\n")
        self.prepare()
        for operation in ("install", "uninstall"):
            refused = self.run_helper(operation, target, check=False)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("changed outside the toolkit", refused.stderr)
        self.assertEqual(weights.read_bytes(), b"user replacement\n")
        self.assertEqual(self.records()["state"], "invalid")

    def test_interrupted_upgrade_remains_removable(self):
        target = self.legacy_install()
        old_dll = target.read_bytes()
        old_kernel = (self.game / "helixsr_kernels.pak").read_bytes()
        self.prepare()
        self.run_helper("install", target)
        record_path = self.state / "installs" / sha256_bytes(str(target).encode()) / "record.json"
        record = json.loads(record_path.read_text())
        previous = {target.name: old_dll, "helixsr_kernels.pak": old_kernel}
        for entry in record["files"]:
            if entry["name"] in previous:
                entry["previousSha256"] = sha256_bytes(previous[entry["name"]])
                entry["previousMode"] = entry["installedMode"]
                (self.game / entry["name"]).write_bytes(previous[entry["name"]])
        record_path.write_text(json.dumps(record))
        self.assertEqual(self.records()["state"], "restorable")
        self.run_helper("uninstall", target)
        self.assertEqual(target.read_bytes(), b"original dll\n")
        self.assertFalse((self.game / "helixsr_kernels.pak").exists())
        self.assertFalse(record_path.exists())


if __name__ == "__main__":
    unittest.main()
