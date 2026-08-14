import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWAP = ROOT / "bc250-swap.sh"


class SwapTests(unittest.TestCase):
    def run_sourced(self, body: str, root: Path, check: bool = True):
        env = os.environ.copy()
        env.update(
            {
                "ROOT_DATA_DIR": str(root / "data"),
                "BC250_SWAP_STATE_DIR": str(root / "data/swap"),
                "BC250_SWAP_BACKING_STATE_DIR": str(root / "backing/swap"),
                "BC250_SWAPFILE": str(root / "data/swap/swapfile"),
                "BC250_SWAP_HELPER": str(root / "data/swap/bc250-zswap-setup"),
                "BC250_ZRAM_CONFIG": str(root / "etc/90-bc250-swap.conf"),
                "BC250_ZSWAP_SERVICE": str(root / "systemd/bc250-zswap-setup.service"),
                "BC250_ZSWAP_UNIT": str(root / "systemd/swapfile.swap"),
                "BC250_ZSWAP_WANTS": str(root / "systemd/swap.target.wants/swapfile.swap"),
                "BC250_PROC_SWAPS": str(root / "proc-swaps"),
                "BC250_ZSWAP_PARAMS": str(root / "zswap"),
                "BC250_SWAP_LOCK_FILE": str(root / "swap.lock"),
            }
        )
        if not (root / "proc-swaps").exists():
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n", encoding="utf-8"
            )
        return subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; root=$2; set -- help; source "$script" >/dev/null; '
                + body,
                "_",
                str(SWAP),
                str(root),
            ],
            check=check,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_help_and_shell_parse(self):
        subprocess.run(["bash", "-n", str(SWAP)], check=True)
        result = subprocess.run(
            ["bash", str(SWAP), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("install zram", result.stdout)
        self.assertIn("install zswap [SIZE_GIB]", result.stdout)
        self.assertIn("verify", result.stdout)
        self.assertIn("mutually exclusive", result.stdout)
        self.assertIn("never performs a live swapoff", result.stdout)

    def test_rendered_profiles_are_explicit_and_reboot_gated(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_sourced(
                'render_zram_config; echo ===; render_zswap_config; echo ===; '
                "render_service; echo ===; render_swap_unit",
                Path(directory),
            )
            self.assertIn("zram-size = ram/2", result.stdout)
            self.assertIn("compression-algorithm = zstd", result.stdout)
            self.assertIn("swap-priority = 100", result.stdout)
            self.assertIn("zram-size = 0", result.stdout)
            self.assertIn("DefaultDependencies=no", result.stdout)
            self.assertIn("Before=swap.target", result.stdout)
            self.assertNotIn("swapoff", result.stdout)

    def test_machine_probe_requires_complete_owned_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_sourced(
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; '
                'mkdir -p "$(dirname "$ZRAM_CONFIG")" "$STATE_DIR"; '
                'render_zram_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"; '
                'render_state zram 0 none > "$STATE_FILE"; chmod 644 "$STATE_FILE"; '
                "cmd_installed",
                root,
            )
            self.assertEqual(result.stdout.strip(), "installed")

            foreign = root / "etc/90-bc250-swap.conf"
            foreign.write_text("foreign\n", encoding="utf-8")
            rejected = self.run_sourced(
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; preflight_ownership',
                root,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("unrecognized zram configuration", rejected.stderr)

    def test_active_swap_detection_uses_file_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swapfile = root / "data/swap/swapfile"
            swapfile.parent.mkdir(parents=True)
            swapfile.write_bytes(b"swap")
            alias = root / "swap-alias"
            os.link(swapfile, alias)
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n"
                f"{alias} file 4096 0 10\n",
                encoding="utf-8",
            )
            self.run_sourced('swap_active "$SWAPFILE"', root)

    def test_active_disk_uninstall_is_two_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = r'''
file_secure() { [[ -f "$1" && ! -L "$1" ]]; }
atomic_write() { mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "$2" "$1"; }
install_storage() { :; }
install_persistence() { :; }
remove_persistence() { :; }
systemctl() { :; }
begin_cleanup_lifecycle() { preflight_ownership; }
mkdir -p "$STATE_DIR" "$(dirname "$ZRAM_CONFIG")" "$(dirname "$SERVICE")" "$(dirname "$SWAP_WANTS")"
render_zswap_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"
render_helper > "$HELPER"; chmod 755 "$HELPER"
render_service > "$SERVICE"; chmod 644 "$SERVICE"
render_swap_unit > "$SWAP_UNIT"; chmod 644 "$SWAP_UNIT"
render_state zswap 16 none > "$STATE_FILE"; chmod 644 "$STATE_FILE"
truncate -s 16G "$SWAPFILE"; chmod 600 "$SWAPFILE"
ln -s "../$SWAP_UNIT_NAME" "$SWAP_WANTS"
printf 'Filename Type Size Used Priority\n%s file 1 0 10\n' "$SWAPFILE" > "$PROC_SWAPS"
rc=0; cmd_uninstall || rc=$?; [[ $rc == 75 ]]
[[ -f "$SWAPFILE" && -f "$STATE_FILE" && ! -e "$SWAP_WANTS" && ! -e "$ZRAM_CONFIG" ]]
grep -qx 'pending=uninstall' "$STATE_FILE"
'''
            result = self.run_sourced(body, root)
            self.assertIn("Reboot, then rerun uninstall", result.stdout)

    def test_clean_uninstall_is_a_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_sourced(
                'begin_locked_lifecycle() { :; }; '
                'install_storage() { echo unexpected-storage-install; return 9; }; '
                'cmd_uninstall',
                Path(directory),
            )
            self.assertIn("No toolkit swap profile is installed", result.stdout)
            self.assertNotIn("unexpected-storage-install", result.stdout)

    def test_interrupted_staged_swapfile_is_recoverable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged = root / "data/swap/.swapfile.new"
            staged.parent.mkdir(parents=True)
            staged.write_bytes(b"partial")
            staged.chmod(0o600)
            self.run_sourced(
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; '
                "recover_staged_swapfile; [[ ! -e \"$STATE_DIR/.swapfile.new\" ]]",
                root,
            )

    def test_zram_reboot_pending_clears_only_when_runtime_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meminfo = root / "meminfo"
            zram_sys = root / "zram"
            zram_sys.mkdir()
            meminfo.write_text("MemTotal: 1048576 kB\n", encoding="utf-8")
            (zram_sys / "disksize").write_text("536870912\n", encoding="ascii")
            (zram_sys / "comp_algorithm").write_text("lz4 [zstd]\n", encoding="ascii")
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n/dev/zram0 partition 1 0 100\n",
                encoding="utf-8",
            )
            env_body = (
                f'MEMINFO={str(meminfo)!r}; ZRAM_SYS={str(zram_sys)!r}; '
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; '
                'mkdir -p "$(dirname "$ZRAM_CONFIG")" "$STATE_DIR"; '
                'render_zram_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"; '
                'render_state zram 0 reboot > "$STATE_FILE"; chmod 644 "$STATE_FILE"; '
                'cmd_status'
            )
            matching = self.run_sourced(env_body, root)
            self.assertNotIn("pending:", matching.stdout)
            (zram_sys / "comp_algorithm").write_text("[lz4] zstd\n", encoding="ascii")
            mismatch = self.run_sourced(env_body, root, check=False)
            self.assertIn("pending:    reboot", mismatch.stdout)

    def test_size_bounds_and_source_provenance(self):
        source = SWAP.read_text(encoding="utf-8")
        self.assertIn("MIN_SWAP_GIB=4", source)
        self.assertIn("MAX_SWAP_GIB=64", source)
        self.assertIn('swap_active "$SWAPFILE" && die', source)
        self.assertIn("validate_swapfile_metadata", source)
        self.assertIn("validate_swapfile", source)
        self.assertIn('return 2', source[source.index("cmd_verify()") :])
        self.assertIn("component:swap", (ROOT / "bc250-storage.sh").read_text())
        self.assertNotIn("redbeard1083", source)

    def test_privileged_swap_signature_validation_rejects_plain_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swapfile = root / "data/swap/swapfile"
            swapfile.parent.mkdir(parents=True)
            subprocess.run(["truncate", "-s", "4M", str(swapfile)], check=True)
            swapfile.chmod(0o600)
            rejected = self.run_sourced(
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; '
                'validate_swapfile $((4 * 1024 * 1024))',
                root,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            subprocess.run(["mkswap", str(swapfile)], check=True, capture_output=True)
            self.run_sourced(
                'file_secure() { [[ -f "$1" && ! -L "$1" ]]; }; '
                'validate_swapfile $((4 * 1024 * 1024))',
                root,
            )


if __name__ == "__main__":
    unittest.main()
