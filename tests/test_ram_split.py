import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAM = ROOT / "bc250-ram-split.sh"
TOOLKIT = ROOT / "bc250-toolkit.sh"


def run_sourced(body: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "bash",
            "-c",
            'script=$1; shift; args=("$@"); set -- help; source "$script" >/dev/null; '
            'set -- "${args[@]}"; ' + body,
            "_",
            str(RAM),
            *args,
        ],
        capture_output=True,
        text=True,
    )


class RamSplitTests(unittest.TestCase):
    def test_help_documents_cmos_and_ttm_safety(self):
        result = subprocess.run(
            ["bash", str(RAM), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("clear CMOS", result.stdout)
        self.assertIn("ttm.pages_limit", result.stdout)
        self.assertIn("2048 MiB is blocked", result.stdout)
        self.assertIn("exposes no memory", result.stdout)

    def test_status_and_installed_are_rootless_and_local(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DATA_DIR": str(root / "data"),
                    "TTM_CONFIG": str(root / "ttm.cfg"),
                    "GRUB_CFG": str(root / "grub.cfg"),
                    "TTM_SYS_PARAM": str(root / "pages_limit"),
                    "PROC_CMDLINE": str(root / "cmdline"),
                    "RAM_KEEP_FILE": str(root / "keep.conf"),
                }
            )
            status = subprocess.run(
                ["bash", str(RAM), "status"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            installed = subprocess.run(
                ["bash", str(RAM), "installed"],
                capture_output=True,
                text=True,
                env=env,
            )

        self.assertIn("not installed", status.stdout)
        self.assertIn("TTM configured:        default", status.stdout)
        self.assertEqual(installed.returncode, 1)
        self.assertEqual(installed.stdout, "not-installed\n")

    def test_status_json_reports_reboot_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            profile = data / "ram-split/settings.conf"
            profile.parent.mkdir(parents=True)
            profile.write_text("UMA_MB=512\n", encoding="utf-8")
            config = root / "ttm.cfg"
            config.write_text(
                "# BC-250 TTM limit managed by bc250-ram-split.sh.\n"
                "# Remove with: bc250-ram-split.sh ttm-remove\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'ttm.pages_limit=3014656"\n',
                encoding="utf-8",
            )
            cmdline = root / "cmdline"
            cmdline.write_text("quiet ttm.pages_limit=2097152\n", encoding="utf-8")
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DATA_DIR": str(data),
                    "TTM_CONFIG": str(config),
                    "GRUB_DEFAULT": str(root / "grub-default"),
                    "PROC_CMDLINE": str(cmdline),
                    "TTM_SYS_PARAM": str(root / "missing-live-limit"),
                    "RAM_KEEP_FILE": str(root / "missing-keep"),
                }
            )
            result = subprocess.run(
                ["bash", str(RAM), "status-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

        status = json.loads(result.stdout)
        self.assertEqual(status["schemaVersion"], 1)
        self.assertEqual(status["umaLastRequestedMiB"], 512)
        self.assertEqual(status["ttmConfiguredPages"], 3014656)
        self.assertEqual(status["ttmBootPages"], 2097152)
        self.assertTrue(status["rebootRequired"])

    def test_uma_validation_blocks_unsafe_values(self):
        for value in ("nope", "0", "00256", "255", "513", "2048", "12289", "16384"):
            result = run_sourced('validate_uma_size "$1"', value)
            self.assertNotEqual(result.returncode, 0, value)
        self.assertEqual(run_sourced('validate_uma_size "$1"', "512").returncode, 0)
        self.assertEqual(run_sourced('validate_uma_size "$1"', "12288").returncode, 0)

    def test_cmos_write_passes_only_uma_size(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "bc250memcfg"
            log = root / "args"
            tool.write_text(
                '#!/bin/sh\nif [ "$#" -eq 0 ]; then printf "UMA_SIZE=0512\\n"; exit; fi\n'
                'printf "%s\\n" "$*" > "$ARG_LOG"\n'
                'printf "setting UMA_SIZE to %s\\n" "$2"\n',
                encoding="utf-8",
            )
            tool.chmod(0o755)
            result = run_sourced(
                'MEMCFG_BIN=$1; ARG_LOG=$2; export ARG_LOG; '
                'require_root() { :; }; require_bc250() { :; }; '
                'verify_installed_tool() { return 0; }; write_profile() { :; }; '
                'cmd_set 512 --yes',
                str(tool),
                str(log),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), "UMA_SIZE 512\n")

    def test_ttm_write_is_owned_and_reports_reboot_needed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-ttm.cfg"
            grub = root / "grub.cfg"
            cmdline = root / "cmdline"
            cmdline.write_text("quiet splash\n", encoding="utf-8")
            result = run_sourced(
                'TTM_CONFIG=$1; GRUB_CFG=$2; PROC_CMDLINE=$3; '
                'require_root() { :; }; install_storage() { :; }; '
                'install_update_persistence() { :; }; chown() { :; }; '
                'preflight_no_foreign_ttm() { :; }; preflight_grub_target() { :; }; '
                'regenerate_grub() { printf "%s\\n" "linux ttm.pages_limit=3014656" > "$GRUB_CFG"; }; '
                'cmd_ttm_set 3014656 --yes; '
                '[[ "$(configured_ttm_pages)" == 3014656 ]]',
                str(config),
                str(grub),
                str(cmdline),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'ttm.pages_limit=3014656"',
                config.read_text(encoding="utf-8"),
            )

    def test_ttm_regeneration_failure_restores_config_and_grub(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-ttm.cfg"
            grub = root / "grub.cfg"
            config.parent.mkdir()
            previous_config = (
                "# BC-250 TTM limit managed by bc250-ram-split.sh.\n"
                "# Remove with: bc250-ram-split.sh ttm-remove\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'ttm.pages_limit=2097152"\n'
            )
            config.write_text(previous_config, encoding="utf-8")
            grub.write_text("previous generated config\n", encoding="utf-8")
            result = run_sourced(
                'TTM_CONFIG=$1; GRUB_CFG=$2; '
                'require_root() { :; }; install_storage() { :; }; chown() { :; }; '
                'preflight_no_foreign_ttm() { :; }; preflight_grub_target() { :; }; '
                'regenerate_grub() { printf "partial\\n" > "$GRUB_CFG"; return 1; }; '
                'cmd_ttm_set 3014656 --yes',
                str(config),
                str(grub),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(encoding="utf-8"), previous_config)
            self.assertEqual(grub.read_text(encoding="utf-8"), "previous generated config\n")

    def test_ttm_validation_accepts_steamos_steamenv_boot_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            grub = Path(directory) / "grub.cfg"
            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz-linux-neptune-616 "
                "quiet ttm.pages_limit=3014656\n",
                encoding="utf-8",
            )
            valid = run_sourced(
                'validate_generated_grub "$1" 3014656', str(grub)
            )
            invalid = run_sourced(
                'validate_generated_grub "$1" 2097152', str(grub)
            )

        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertNotEqual(invalid.returncode, 0)

    def test_release_metadata_requires_expected_asset_and_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "release.json"
            metadata.write_text(
                json.dumps(
                    {
                        "tag_name": "v0.1",
                        "draft": False,
                        "prerelease": False,
                        "assets": [
                            {
                                "id": 42,
                                "name": "bc250_memcfg.zip",
                                "size": 6320,
                                "digest": "sha256:" + "a" * 64,
                                "browser_download_url": "https://github.com/fanoush/"
                                "bc250_memcfg/releases/download/v0.1/bc250_memcfg.zip",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            valid = run_sourced('parse_release_metadata "$1"', str(metadata))
            payload = json.loads(metadata.read_text(encoding="utf-8"))
            payload["assets"][0]["digest"] = None
            metadata.write_text(json.dumps(payload), encoding="utf-8")
            invalid = run_sourced('parse_release_metadata "$1"', str(metadata))

        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn("v0.1 42 " + "a" * 64, valid.stdout)
        self.assertNotEqual(invalid.returncode, 0)

    def test_toolkit_exposes_ram_child_menu(self):
        source = TOOLKIT.read_text(encoding="utf-8")
        self.assertIn('RAM_SPLIT_SH="$SCRIPT_DIR/bc250-ram-split.sh"', source)
        self.assertIn('"RAM / VRAM split|', source)
        self.assertIn("ram) (($# == 0))", source)

    def test_script_parses(self):
        subprocess.run(["bash", "-n", str(RAM)], check=True)


if __name__ == "__main__":
    unittest.main()
