import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Dict


ROOT = Path(__file__).resolve().parents[1]
POWER = ROOT / "bc250-power.sh"
COMPUTE = ROOT / "bc250-40cu.sh"


def script_env(home: str) -> Dict[str, str]:
    env = os.environ.copy()
    env.update({"REAL_USER": "lifecycle-test", "REAL_HOME": home})
    return env


class LifecycleTests(unittest.TestCase):
    def test_scripts_parse(self):
        subprocess.run(["bash", "-n", str(POWER), str(COMPUTE)], check=True)

    def test_installed_contract_is_noninteractive_and_machine_readable(self):
        with tempfile.TemporaryDirectory() as home:
            for script in (POWER, COMPUTE):
                result = subprocess.run(
                    ["bash", str(script), "installed"],
                    capture_output=True,
                    text=True,
                    env=script_env(home),
                )
                self.assertIn(result.returncode, (0, 1))
                self.assertIn(result.stdout, ("installed\n", "not-installed\n"))
                self.assertEqual(
                    (result.returncode, result.stdout),
                    (0, "installed\n")
                    if result.stdout == "installed\n"
                    else (1, "not-installed\n"),
                )
                self.assertEqual(result.stderr, "")

    def test_help_documents_lifecycle_and_preservation(self):
        with tempfile.TemporaryDirectory() as home:
            for script in (POWER, COMPUTE):
                result = subprocess.run(
                    ["bash", str(script), "help"],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=script_env(home),
                )
                self.assertIn("installed", result.stdout)
                self.assertIn("uninstall", result.stdout)
                self.assertIn("REBOOT REQUIRED", result.stdout)
            compute_help = subprocess.run(
                ["bash", str(COMPUTE), "help"],
                check=True,
                capture_output=True,
                text=True,
                env=script_env(home),
            ).stdout
            self.assertIn("shared UMR", compute_help)

    def test_uninstall_boundaries_preserve_settings_and_shared_data(self):
        power = POWER.read_text(encoding="utf-8")
        power_uninstall = power[
            power.index("cmd_uninstall()") : power.index(
                "# ============================ CPU overclock", power.index("cmd_uninstall()")
            )
        ]
        self.assertNotIn('rm -f "$GOV_CONF"', power_uninstall)
        self.assertNotIn('rm -f "$OC_CONF"', power_uninstall)
        self.assertNotIn('rm -f "$FREQ_STATE"', power_uninstall)
        self.assertNotIn('rm -rf "$ACPI_DIR"', power_uninstall)

        compute = COMPUTE.read_text(encoding="utf-8")
        compute_uninstall = compute[
            compute.index("cmd_uninstall()") : compute.index(
                "# ================================ help", compute.index("cmd_uninstall()")
            )
        ]
        self.assertIn("stock-dispatch", compute)
        self.assertNotIn('rm -rf "$UMR_PREFIX"', compute_uninstall)
        self.assertNotIn('rm -f "$SERVICE_CONF"', compute_uninstall)

    def test_power_uninstall_removes_payload_but_preserves_tuning(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    r'''
script=$1; base=$2
set -- help
source "$script" >/dev/null
require_root() { :; }
reset_cpu_stock_live() { return 0; }
remove_acpi_boot_override() { return 0; }
remove_update_persistence() { rm -f "$POWER_KEEP_FILE"; }
unlock_rootfs() { :; }
relock_rootfs() { :; }
systemctl() { [[ "${1:-}" != is-active ]]; }
busctl() { :; }
SYSTEMD_WANTS_DIR="$base/wants"
HEAL_UNIT="$base/system/bc250-acpi-heal.service"
CPUFREQ_UNIT="$base/system/bc250-cpufreq.service"
GOV_UNIT="$base/system/cyan.service"
RESTORE_UNIT="$base/system/restore.service"
OC_UNIT="$base/system/oc.service"
HEAL_HELPER="$base/data/helper/acpi"
LEGACY_HEAL_HELPER="$base/legacy-acpi"
GOV_BIN="$base/data/bin/governor"
PERF_BIN="$base/data/bin/perf"
RESTORE_BIN="$base/data/bin/restore"
DBUS_POLICY="$base/etc/governor.conf"
POWER_KEEP_FILE="$base/keep/power.conf"
GOV_CONF="$base/settings/config.toml"
FREQ_STATE="$base/settings/freq-state"
OC_CONF="$base/settings/oc.conf"
OC_DIR="$base/data/smu-oc"
OC_STAGE_CONF="$OC_DIR/overclock.conf"
mkdir -p "$base/system" "$base/data/helper" "$base/data/bin" \
    "$base/etc" "$base/keep" "$base/settings" "$OC_DIR/bc250_smu"
touch "$HEAL_UNIT" "$CPUFREQ_UNIT" "$GOV_UNIT" "$RESTORE_UNIT" \
    "$OC_UNIT" "$HEAL_HELPER" "$LEGACY_HEAL_HELPER" "$GOV_BIN" \
    "$PERF_BIN" "$RESTORE_BIN" "$DBUS_POLICY" "$POWER_KEEP_FILE" \
    "$GOV_CONF" "$FREQ_STATE" "$OC_CONF" "$OC_STAGE_CONF" \
    "$OC_DIR/bc250_apply.py" "$OC_DIR/bc250_smu/api.py"
cmd_uninstall >/dev/null
[[ ! -e "$GOV_UNIT" && ! -e "$GOV_BIN" && ! -e "$OC_DIR/bc250_apply.py" ]]
[[ -e "$GOV_CONF" && -e "$FREQ_STATE" && -e "$OC_CONF" && -e "$OC_STAGE_CONF" ]]
''',
                    "_",
                    str(POWER),
                    directory,
                ],
                check=True,
                capture_output=True,
                text=True,
                env=script_env(directory),
            )
            self.assertEqual(result.stderr, "")

    def test_compute_uninstall_preserves_profile_and_shared_umr(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                [
                    "bash",
                    "-c",
                    r'''
script=$1; base=$2
set -- help
source "$script" >/dev/null
require_root() { :; }
restore_stock_dispatch_live() { return 0; }
remove_update_persistence() { rm -f "$UPDATE_KEEP_FILE"; }
unlock_rootfs() { :; }
relock_rootfs() { :; }
systemctl() { [[ "${1:-}" != is-active ]]; }
SERVICE="$base/system/compute.service"
SERVICE_DROPIN="$SERVICE.d/10-bc250-storage.conf"
SERVICE_WANTS="$base/wants/compute.service"
SERVICE_CONF="$base/settings/compute.conf"
PERSIST_MANAGER_BIN="$base/data/helper/manager"
ROOTFS_MANAGER_BIN="$base/rootfs/manager"
VAR_USRLOCAL_MANAGER_BIN="$base/usrlocal/manager"
OLD_UDEV_RULE="$base/etc/old.rule"
UPDATE_KEEP_FILE="$base/keep/compute.conf"
UMR_PREFIX="$base/data/umr"
mkdir -p "$(dirname "$SERVICE_DROPIN")" "$(dirname "$SERVICE_WANTS")" \
    "$(dirname "$SERVICE_CONF")" "$(dirname "$PERSIST_MANAGER_BIN")" \
    "$(dirname "$ROOTFS_MANAGER_BIN")" "$(dirname "$VAR_USRLOCAL_MANAGER_BIN")" \
    "$(dirname "$OLD_UDEV_RULE")" "$(dirname "$UPDATE_KEEP_FILE")" "$UMR_PREFIX"
touch "$SERVICE" "$SERVICE_DROPIN" "$SERVICE_WANTS" "$SERVICE_CONF" \
    "$PERSIST_MANAGER_BIN" "$ROOTFS_MANAGER_BIN" "$VAR_USRLOCAL_MANAGER_BIN" \
    "$OLD_UDEV_RULE" "$UPDATE_KEEP_FILE" "$UMR_PREFIX/database"
cmd_uninstall >/dev/null
[[ ! -e "$SERVICE" && ! -e "$PERSIST_MANAGER_BIN" && ! -e "$UPDATE_KEEP_FILE" ]]
[[ -e "$SERVICE_CONF" && -e "$UMR_PREFIX/database" ]]
''',
                    "_",
                    str(COMPUTE),
                    directory,
                ],
                check=True,
                capture_output=True,
                text=True,
                env=script_env(directory),
            )


if __name__ == "__main__":
    unittest.main()
