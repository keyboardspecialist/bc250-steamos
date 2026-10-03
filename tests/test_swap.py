import os
import shutil
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
                "BC250_ZSWAP_TMPFILES": str(root / "tmpfiles/00-bc250-zswap.conf"),
                "BC250_ZSWAP_SERVICE": str(root / "systemd/bc250-zswap-setup.service"),
                "BC250_ZSWAP_UNIT": str(root / "systemd/swapfile.swap"),
                "BC250_ZSWAP_WANTS": str(root / "systemd/swap.target.wants/swapfile.swap"),
                "BC250_PROC_SWAPS": str(root / "proc-swaps"),
                "BC250_ZSWAP_PARAMS": str(root / "zswap"),
                "BC250_ZSWAP_DEBUG": str(root / "zswap-debug"),
                "BC250_VMSTAT": str(root / "vmstat"),
                "BC250_MEMORY_PRESSURE": str(root / "memory-pressure"),
                "BC250_SWAP_LOCK_FILE": str(root / "swap.lock"),
            }
        )
        if not (root / "proc-swaps").exists():
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n", encoding="utf-8"
            )
        if not (root / "vmstat").exists():
            (root / "vmstat").write_text("pswpin 0\npswpout 0\n", encoding="ascii")
        if not (root / "memory-pressure").exists():
            (root / "memory-pressure").write_text(
                "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
                "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
                encoding="ascii",
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
                "render_zswap_tmpfiles; echo ===; render_service; echo ===; render_swap_unit",
                Path(directory),
            )
            self.assertIn("zram-size = ram/2", result.stdout)
            self.assertIn("compression-algorithm = zstd", result.stdout)
            self.assertIn("swap-priority = 100", result.stdout)
            self.assertIn("zram-size = 0", result.stdout)
            self.assertIn("/sys/module/zswap/parameters/enabled", result.stdout)
            self.assertIn("w! /sys/module/zswap/parameters/compressor - - - - zstd", result.stdout)
            self.assertIn("w! /sys/module/zswap/parameters/max_pool_percent - - - - 10", result.stdout)
            self.assertIn("/sys/module/zswap/parameters/shrinker_enabled", result.stdout)
            self.assertIn("- - - - Y", result.stdout)
            self.assertIn("Requires=systemd-tmpfiles-setup.service", result.stdout)
            self.assertIn("After=systemd-tmpfiles-setup.service", result.stdout)
            self.assertIn("systemd-tmpfiles --create", result.stdout)
            self.assertIn("systemd-tmpfiles --create --boot", result.stdout)
            self.assertIn(
                f"ExecStartPre=/usr/bin/test -w {Path(directory) / 'zswap/shrinker_enabled'}",
                result.stdout,
            )
            self.assertNotIn("RequiresMountsFor", result.stdout.split("===")[3])
            self.assertIn("Before=swap.target", result.stdout)
            self.assertIn("Requires=bc250-zswap-setup.service", result.stdout)
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
            params = root / "zswap"
            params.mkdir()
            for name, value in {
                "enabled": "Y\n",
                "compressor": "zstd\n",
                "max_pool_percent": "10\n",
                "shrinker_enabled": "Y\n",
            }.items():
                (params / name).write_text(value, encoding="ascii")
            self.run_sourced("zswap_runtime_matches", root)

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
render_legacy_helper > "$HELPER"; chmod 755 "$HELPER"
render_legacy_service > "$SERVICE"; chmod 644 "$SERVICE"
render_legacy_swap_unit > "$SWAP_UNIT"; chmod 644 "$SWAP_UNIT"
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

    def test_reinstall_recognizes_legacy_service_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            body = r'''
file_secure() { [[ -f "$1" && ! -L "$1" ]]; }
mkdir -p "$STATE_DIR" "$(dirname "$ZRAM_CONFIG")" "$(dirname "$SERVICE")" "$(dirname "$SWAP_WANTS")"
render_zswap_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"
render_legacy_helper > "$HELPER"; chmod 755 "$HELPER"
render_legacy_service > "$SERVICE"; chmod 644 "$SERVICE"
render_legacy_swap_unit > "$SWAP_UNIT"; chmod 644 "$SWAP_UNIT"
render_state zswap 16 reboot > "$STATE_FILE"; chmod 644 "$STATE_FILE"
truncate -s 16G "$SWAPFILE"; chmod 600 "$SWAPFILE"
ln -s "../$SWAP_UNIT_NAME" "$SWAP_WANTS"
preflight_ownership
'''
            self.run_sourced(body, Path(directory))

    def test_reinstall_recognizes_legacy_zswap_tmpfiles(self):
        with tempfile.TemporaryDirectory() as directory:
            body = r'''
file_secure() { [[ -f "$1" && ! -L "$1" ]]; }
mkdir -p "$(dirname "$ZSWAP_TMPFILES")"
render_legacy_zswap_tmpfiles > "$ZSWAP_TMPFILES"; chmod 644 "$ZSWAP_TMPFILES"
preflight_ownership
'''
            self.run_sourced(body, Path(directory))

    def test_legacy_zswap_profile_reports_upgrade_instead_of_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = r'''
file_secure() { [[ -f "$1" && ! -L "$1" ]]; }
mkdir -p "$STATE_DIR" "$(dirname "$ZRAM_CONFIG")" "$(dirname "$ZSWAP_TMPFILES")" \
    "$(dirname "$SERVICE")" "$(dirname "$SWAP_WANTS")"
render_zswap_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"
render_legacy_zswap_tmpfiles > "$ZSWAP_TMPFILES"; chmod 644 "$ZSWAP_TMPFILES"
render_previous_service > "$SERVICE"; chmod 644 "$SERVICE"
render_swap_unit > "$SWAP_UNIT"; chmod 644 "$SWAP_UNIT"
render_state zswap 4 none > "$STATE_FILE"; chmod 644 "$STATE_FILE"
truncate -s 4G "$SWAPFILE"; chmod 600 "$SWAPFILE"
ln -s "../$SWAP_UNIT_NAME" "$SWAP_WANTS"
printf 'Filename Type Size Used Priority\n%s file 4194304 0 10\n' "$SWAPFILE" > "$PROC_SWAPS"
swap_menu_graph_badge action__status; echo
rc=0; cmd_status || rc=$?; [[ $rc == 3 ]]
require_root() { :; }
validate_swapfile() { echo signature-checked >&2; return 1; }
cmd_verify
'''
            result = self.run_sourced(body, root, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn("[upgrade]", result.stdout)
            self.assertIn("configured: legacy-zswap", result.stdout)
            self.assertIn("upgrade:", result.stdout)
            self.assertIn("signature-checked", result.stderr)
            self.assertIn("swapfile size or swap signature is invalid", result.stderr)

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

    def test_orphaned_zswap_tmpfiles_is_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tmpfiles = root / "tmpfiles/00-bc250-zswap.conf"
            tmpfiles.parent.mkdir(parents=True)
            tmpfiles.write_text("orphaned\n", encoding="utf-8")
            result = self.run_sourced("cmd_status", root, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn("configured: partial", result.stdout)

    def test_foreign_config_is_rejected_before_storage_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "etc/90-bc250-swap.conf"
            config.parent.mkdir(parents=True)
            config.write_text("foreign\n", encoding="ascii")
            result = self.run_sourced(
                'begin_locked_lifecycle() { :; }; '
                'install_storage() { echo storage-mutated; }; '
                'begin_install_lifecycle',
                root,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("storage-mutated", result.stdout)

    def test_swap_storage_calls_preserve_legacy_aic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "aic8800-ensure-modules.sh"
            legacy.write_text("legacy helper\n", encoding="ascii")
            storage = root / "storage.sh"
            persistence = root / "persistence.sh"
            for script in (storage, persistence):
                script.write_text(
                    "#!/bin/sh\n"
                    "[ \"${BC250_STORAGE_SKIP_LEGACY_AIC:-0}\" = 1 ] "
                    "|| rm -f \"$LEGACY_AIC\"\n",
                    encoding="ascii",
                )
                script.chmod(0o755)
            result = self.run_sourced(
                f'STORAGE_SH={str(storage)!r}; PERSISTENCE_SH={str(persistence)!r}; '
                f'export LEGACY_AIC={str(legacy)!r}; '
                'install_storage; install_persistence; [[ -f "$LEGACY_AIC" ]]',
                root,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_active_valve_zram_install_is_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meminfo = root / "meminfo"
            zram_sys = root / "zram"
            zram_sys.mkdir()
            meminfo.write_text("MemTotal: 1048576 kB\n", encoding="ascii")
            (zram_sys / "disksize").write_text("536870912\n", encoding="ascii")
            (zram_sys / "comp_algorithm").write_text("lz4 [zstd]\n", encoding="ascii")
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n/dev/zram0 partition 524288 0 100\n",
                encoding="ascii",
            )
            result = self.run_sourced(
                f'MEMINFO={str(meminfo)!r}; ZRAM_SYS={str(zram_sys)!r}; '
                'require_root() { :; }; '
                'begin_install_lifecycle() { echo unexpected-mutation; return 9; }; '
                'cmd_install_zram',
                root,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already active", result.stdout)
            self.assertIn("allocated on demand", result.stdout)
            self.assertNotIn("unexpected-mutation", result.stdout)

    def test_status_reports_all_swap_devices_and_pressure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n"
                "/dev/zram0 partition 1048576 262144 100\n"
                "/home/swapfile file 2097152 131072 -1\n",
                encoding="ascii",
            )
            (root / "vmstat").write_text(
                "pswpin 12\npswpout 34\n", encoding="ascii"
            )
            (root / "memory-pressure").write_text(
                "some avg10=4.50 avg60=1.00 avg300=0.50 total=10\n"
                "full avg10=1.25 avg60=0.50 avg300=0.25 total=5\n",
                encoding="ascii",
            )
            zswap_debug = root / "zswap-debug"
            zswap_debug.mkdir()
            (zswap_debug / "pool_total_size").write_text(
                str(96 * 1024 * 1024), encoding="ascii"
            )
            (zswap_debug / "stored_pages").write_text("4096", encoding="ascii")
            (zswap_debug / "written_back_pages").write_text("512", encoding="ascii")
            result = self.run_sourced("cmd_status", root, check=False)
            self.assertIn("/dev/zram0 (partition, 256/1024 MiB used", result.stdout)
            self.assertIn("/home/swapfile (file, 128/2048 MiB used", result.stdout)
            self.assertIn("12 pages in, 34 pages out", result.stdout)
            self.assertIn("some avg10 4.50%, full avg10 1.25%", result.stdout)
            self.assertIn("96 MiB resident, 4096 pages stored", result.stdout)
            self.assertIn("zswap writeback: 512 pages", result.stdout)

    def test_zswap_runtime_match_requires_safe_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swapfile = root / "data/swap/swapfile"
            swapfile.parent.mkdir(parents=True)
            swapfile.write_bytes(b"swap")
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n"
                f"{swapfile} file 4096 0 10\n",
                encoding="ascii",
            )
            params = root / "zswap"
            params.mkdir()
            for name, value in {
                "enabled": "Y\n",
                "compressor": "zstd\n",
                "max_pool_percent": "10\n",
                "shrinker_enabled": "Y\n",
            }.items():
                (params / name).write_text(value, encoding="ascii")
            self.run_sourced("zswap_runtime_matches", root)
            (params / "max_pool_percent").write_text("25\n", encoding="ascii")
            result = self.run_sourced("zswap_runtime_matches", root, check=False)
            self.assertNotEqual(result.returncode, 0)
            (params / "max_pool_percent").write_text("10\n", encoding="ascii")
            (params / "shrinker_enabled").unlink()
            result = self.run_sourced("zswap_runtime_matches", root, check=False)
            self.assertNotEqual(result.returncode, 0)
            (params / "shrinker_enabled").write_text("Y\n", encoding="ascii")
            (root / "proc-swaps").write_text(
                "Filename Type Size Used Priority\n"
                f"{swapfile} file 4096 0 5\n",
                encoding="ascii",
            )
            result = self.run_sourced("zswap_runtime_matches", root, check=False)
            self.assertNotEqual(result.returncode, 0)

    def test_status_rejects_stale_active_zswap_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = r'''
file_secure() { [[ -f "$1" && ! -L "$1" ]]; }
mkdir -p "$STATE_DIR" "$(dirname "$ZRAM_CONFIG")" "$(dirname "$ZSWAP_TMPFILES")" \
    "$(dirname "$SERVICE")" "$(dirname "$SWAP_WANTS")" "$ZSWAP_PARAMS"
render_zswap_config > "$ZRAM_CONFIG"; chmod 644 "$ZRAM_CONFIG"
render_zswap_tmpfiles > "$ZSWAP_TMPFILES"; chmod 644 "$ZSWAP_TMPFILES"
render_service > "$SERVICE"; chmod 644 "$SERVICE"
render_swap_unit > "$SWAP_UNIT"; chmod 644 "$SWAP_UNIT"
render_state zswap 4 none > "$STATE_FILE"; chmod 644 "$STATE_FILE"
truncate -s 4G "$SWAPFILE"; chmod 600 "$SWAPFILE"
ln -s "../$SWAP_UNIT_NAME" "$SWAP_WANTS"
printf 'Filename Type Size Used Priority\n%s file 4194304 0 10\n' "$SWAPFILE" > "$PROC_SWAPS"
printf 'Y\n' > "$ZSWAP_PARAMS/enabled"
printf 'lz4\n' > "$ZSWAP_PARAMS/compressor"
printf '25\n' > "$ZSWAP_PARAMS/max_pool_percent"
printf 'Y\n' > "$ZSWAP_PARAMS/shrinker_enabled"
cmd_status
'''
            result = self.run_sourced(body, root, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn("does not match the safe profile", result.stdout)

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
        self.assertIn("BC250_STORAGE_SKIP_LEGACY_AIC=1", source)
        self.assertIn("if zswap_runtime_matches; then", source)
        self.assertIn('return 2', source[source.index("cmd_verify()") :])
        self.assertIn("component:swap", (ROOT / "bc250-storage.sh").read_text())
        self.assertNotIn("redbeard1083", source)

    @unittest.skipUnless(
        shutil.which("mkswap") and shutil.which("blkid"),
        "requires Linux swap utilities",
    )
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
