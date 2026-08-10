import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POWER = ROOT / "bc250-power.sh"


def run_sourced(body: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "bash",
            "-c",
            'script=$1; shift; args=("$@"); set -- help; '
            'REAL_HOME=/tmp FIXES_REPO_DIR=/tmp source "$script" >/dev/null; '
            'set -- "${args[@]}"; ' + body,
            "_",
            str(POWER),
            *args,
        ],
        capture_output=True,
        text=True,
    )


class CpuMitigationsTests(unittest.TestCase):
    def test_disable_writes_owned_fragment_and_reports_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-cpu-mitigations.cfg"
            grub = root / "grub.cfg"
            cmdline = root / "cmdline"
            keep = root / "bc250-power.conf"
            cmdline.write_text("quiet splash\n", encoding="utf-8")
            result = run_sourced(
                'CPU_MITIGATIONS_CONFIG=$1; GRUB_CFG=$2; PROC_CMDLINE=$3; '
                'POWER_KEEP_FILE=$4; require_root() { :; }; preflight_cpu_mitigations() { :; }; '
                'grub_config_lock() { :; }; grub_config_unlock() { :; }; '
                'unlock_rootfs() { :; }; relock_rootfs() { :; }; chown() { :; }; install_update_persistence() { '
                'mkdir -p "$(dirname "$POWER_KEEP_FILE")"; printf keep > "$POWER_KEEP_FILE"; }; '
                'regenerate_cpu_mitigations_grub() { printf "steamenv_boot linux mitigations=off\\n" > "$GRUB_CFG"; }; '
                'cpu_mitigations_set disabled; cpu_mitigations_status_json',
                str(config),
                str(grub),
                str(cmdline),
                str(keep),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("mitigations=off", config.read_text(encoding="utf-8"))
            status = json.loads(result.stdout.splitlines()[-1])
            self.assertFalse(status["configuredEnabled"])
            self.assertTrue(status["bootEnabled"])
            self.assertTrue(status["rebootRequired"])

    def test_generated_grub_requires_argument_on_every_linux_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            grub = Path(directory) / "grub.cfg"
            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz quiet mitigations=off\n"
                "steamenv_boot linux /boot/vmlinuz-fallback quiet\n",
                encoding="utf-8",
            )
            result = run_sourced(
                'validate_cpu_mitigations_grub "$1" off', str(grub)
            )

            self.assertNotEqual(result.returncode, 0)

    def test_status_reports_incomplete_when_generated_grub_is_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-cpu-mitigations.cfg"
            grub = root / "grub.cfg"
            config.parent.mkdir()
            config.write_text(
                "# BC-250 CPU security policy managed by bc250-power.sh.\n"
                "# Remove with: bc250-power.sh cpu-mitigations enable\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'mitigations=off"\n',
                encoding="utf-8",
            )
            grub.write_text("steamenv_boot linux quiet\n", encoding="utf-8")
            result = run_sourced(
                'CPU_MITIGATIONS_CONFIG=$1; GRUB_CFG=$2; GRUB_DEFAULT=$3; '
                'cpu_mitigations_status_json',
                str(config),
                str(grub),
                str(root / "default-grub"),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            status = json.loads(result.stdout.strip())
            self.assertEqual(status["state"], "incomplete")
            self.assertIsNone(status["configuredEnabled"])

    def test_persistence_failure_restores_config_and_grub(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-cpu-mitigations.cfg"
            grub = root / "grub.cfg"
            config.parent.mkdir()
            grub.write_text("steamenv_boot linux quiet\n", encoding="utf-8")
            result = run_sourced(
                'CPU_MITIGATIONS_CONFIG=$1; GRUB_CFG=$2; require_root() { :; }; '
                'preflight_cpu_mitigations() { :; }; grub_config_lock() { :; }; '
                'grub_config_unlock() { :; }; unlock_rootfs() { :; }; relock_rootfs() { :; }; '
                'chown() { :; }; install_update_persistence() { return 1; }; '
                'regenerate_cpu_mitigations_grub() { printf "steamenv_boot linux mitigations=off\\n" > "$GRUB_CFG"; }; '
                'cpu_mitigations_set disabled',
                str(config),
                str(grub),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(config.exists())
            self.assertEqual(
                grub.read_text(encoding="utf-8"), "steamenv_boot linux quiet\n"
            )

    def test_foreign_mitigations_source_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "grub.d/bc250-cpu-mitigations.cfg"
            config.parent.mkdir()
            foreign = config.parent / "operator.cfg"
            foreign.write_text(
                'GRUB_CMDLINE_LINUX_DEFAULT="mitigations=auto,nosmt"\n',
                encoding="utf-8",
            )
            result = run_sourced(
                'CPU_MITIGATIONS_CONFIG=$1; GRUB_DEFAULT=$2; '
                'cpu_mitigations_configured_state',
                str(config),
                str(root / "default-grub"),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "foreign")


if __name__ == "__main__":
    unittest.main()
