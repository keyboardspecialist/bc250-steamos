import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "core-unlock" / "bc250-unlock-cores.py"
EFI_SOURCE = ROOT / "core-unlock" / "bc250-unlock-cores-efi.c"
EFI_BUILD_CHECK = ROOT / "scripts" / "check-efi-core-unlock-build.sh"
POWER = ROOT / "bc250-power.sh"


def load_helper():
    spec = importlib.util.spec_from_file_location("bc250_core_unlock", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CoreUnlockTests(unittest.TestCase):
    def test_cpu_unlock_command_exposes_the_guided_menu(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; set -- help; source "$script" >/dev/null; '
                'menu_cpu_unlock() { printf menu; }; cmd_cpu_unlock menu',
                "_",
                str(POWER),
            ],
            check=True,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "REAL_USER": "core-unlock-test",
                "REAL_HOME": str(ROOT),
            },
        )
        self.assertEqual(result.stdout, "menu")

    def test_release_build_check_uses_pinned_headers_and_efi_subsystem(self):
        source = EFI_BUILD_CHECK.read_text(encoding="utf-8")
        self.assertIn("761b114e3b186adb82516d5fa8e7a4c559f56ba5", source)
        self.assertIn("-subsystem:efi_application", source)
        self.assertIn("PE32+", source)
        self.assertIn("x86-64", source)
        self.assertIn('"efi (application)"', source)

    def run_power_shell(self, body, directory):
        return subprocess.run(
            [
                "bash",
                "-c",
                'script=$1; base=$2; set -- help; source "$script" >/dev/null; '
                + body,
                "_",
                str(POWER),
                directory,
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "REAL_USER": "core-unlock-test", "REAL_HOME": directory},
        )

    def test_shell_status_reports_metrics_compatibility(self):
        power = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")

        self.assertIn("core_unlock_metrics_state", power)
        self.assertIn(".bc250-metrics-fix", power)
        self.assertIn("AMDGPU telemetry patch", power)
        self.assertIn("GPU-utilization correction", power)

    def test_boot_clears_guard_when_eight_cores_are_present(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            helper.PENDING.write_text("prior-boot\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(8, 16)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper.subprocess, "run") as reboot:
                self.assertEqual(helper.boot(), 0)
            self.assertFalse(helper.PENDING.exists())
            apply_mask.assert_not_called()
            reboot.assert_not_called()

    def test_boot_guard_prevents_a_second_automatic_reboot(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            helper.PENDING.write_text("prior-boot\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper.subprocess, "run") as reboot:
                with self.assertRaisesRegex(RuntimeError, "reboot-loop guard"):
                    helper.boot()
            apply_mask.assert_not_called()
            reboot.assert_not_called()

    def test_boot_applies_then_requests_one_warm_reboot(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper, "write_pending") as pending, mock.patch.object(
                helper.subprocess, "run"
            ) as reboot:
                self.assertEqual(helper.boot(), 0)
            apply_mask.assert_called_once_with()
            pending.assert_called_once_with("automatic")
            reboot.assert_called_once_with(
                ["/usr/bin/systemctl", "--no-block", "reboot"], check=True
            )

    def test_apply_accepts_non_factory_locked_mask(self):
        helper = load_helper()
        smu = mock.Mock()
        smu.read.side_effect = (0x0000003F, 0x000000FF)
        smu.send.return_value = 0x01
        with mock.patch.object(helper, "Smu", return_value=smu), mock.patch.object(
            helper.time, "sleep"
        ):
            self.assertTrue(helper.read_or_apply_mask())
        smu.send.assert_called_once_with(helper.MSG_WRITE_FF, helper.MASK_REG)
        smu.close.assert_called_once_with()

    def test_boot_refuses_non_bc250_hardware_before_smu_access(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=False), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask:
                with self.assertRaisesRegex(RuntimeError, "1002:13fe"):
                    helper.boot()
            apply_mask.assert_not_called()

    def test_boot_failure_leaves_guard_and_blocks_same_boot_retry(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "current_boot_id", return_value="current-boot"
            ), mock.patch.object(
                helper, "read_or_apply_mask", side_effect=RuntimeError("mailbox timeout")
            ):
                with self.assertRaisesRegex(RuntimeError, "mailbox timeout"):
                    helper.boot()
                self.assertTrue(helper.PENDING.exists())
                with self.assertRaisesRegex(RuntimeError, "already attempted this boot"):
                    helper.apply()

    def test_manual_failure_also_blocks_same_boot_retry(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "current_boot_id", return_value="current-boot"
            ), mock.patch.object(
                helper, "read_or_apply_mask", side_effect=RuntimeError("mailbox timeout")
            ):
                with self.assertRaisesRegex(RuntimeError, "mailbox timeout"):
                    helper.apply()
                self.assertEqual(helper.pending_kind(), "manual")
                with self.assertRaisesRegex(RuntimeError, "already attempted this boot"):
                    helper.apply()

    def test_persistence_gate_requires_eight_active_cores(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ):
                with self.assertRaisesRegex(RuntimeError, "validate before enabling"):
                    helper.verify_unlocked()

            helper.PENDING.write_text("prior-boot manual\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(8, 16)
            ):
                self.assertEqual(helper.verify_unlocked(), 0)
            self.assertFalse(helper.PENDING.exists())

    def test_efi_source_has_hardware_identity_and_one_attempt_guards(self):
        source = EFI_SOURCE.read_text(encoding="utf-8")
        main = source[source.index("EFI_STATUS efi_main") :]

        self.assertIn("0x13fe1002U", source)
        self.assertIn("0x000000ffU", source)
        self.assertIn("0x0115A870U", source)
        self.assertIn("0x98U", source)
        self.assertLess(main.index("pci_read32(0)"), main.index("smn_read(MASK_REG)"))
        self.assertIn("GetVariable", main)
        self.assertIn("SetVariable", main)
        self.assertIn("clear_guard", main)
        self.assertIn("EfiResetWarm", main)
        self.assertIn("0x8000000000000000ULL", source)
        self.assertNotIn("#define LOCKED_MASK", source)
        unlocked = main[
            main.index("if (mask == UNLOCKED_MASK)") : main.index(
                "status = system_table->RuntimeServices->GetVariable"
            )
        ]
        self.assertIn("EFI_ERROR_STATUS(EFI_ABORTED)", unlocked)
        self.assertNotIn("return EFI_SUCCESS", unlocked)
        self.assertNotIn("return EFI_LOAD_ERROR", source)
        self.assertIn("4f6f6f13-1ec2-4f26-a250-bc250c0e77ff", (
            ROOT / "core-unlock" / "README.md"
        ).read_text(encoding="utf-8"))

    def test_efi_provenance_build_and_secure_boot_contract(self):
        power = POWER.read_text(encoding="utf-8")
        notes = (ROOT / "core-unlock" / "README.md").read_text(encoding="utf-8")

        for expected in (
            "3e45131678b111c50e5c285834869ecd3c487a2e",
            "Liam McLoughlin",
            "761b114e3b186adb82516d5fa8e7a4c559f56ba5",
            "Warren Mann",
        ):
            self.assertIn(expected, notes)
        self.assertIn(
            'git -C "$work" fetch -q --no-tags --depth=1 origin '
            '"$CORE_UNLOCK_EFI_PIN"',
            power,
        )
        self.assertIn('[[ "$head" == "$CORE_UNLOCK_EFI_PIN" ]]', power)
        self.assertIn("-target x86_64-unknown-windows", power)
        self.assertIn("-Wl,-subsystem:efi_application", power)
        self.assertIn("command -v lld-link", power)
        self.assertNotIn("command -v ld.lld", power)
        self.assertIn('description=$(LC_ALL=C file -b', power)
        self.assertIn('"efi (application)"', power)
        self.assertIn("Secure Boot state is unknown", power)
        self.assertIn('findmnt -nro SOURCE,TARGET,FSTYPE,OPTIONS --target "$CORE_UNLOCK_ESP_ROOT"', power)
        self.assertIn('lsblk -dnpro NAME,TYPE,PKNAME,PARTN,PARTUUID,PARTTYPE "$source"', power)
        self.assertIn("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", power)
        self.assertNotIn("nvme0n1", power)
        self.assertTrue((ROOT / "core-unlock" / "EFI-LICENSE").is_file())
        self.assertTrue((ROOT / "core-unlock" / "EFI-HEADERS-LICENSE").is_file())
        efi_enable = power[power.index("core_unlock_efi_enable()") : power.index("clear_core_unlock_efi_guard()")]
        self.assertNotIn("clear_core_unlock_efi_guard", efi_enable)
        self.assertLess(efi_enable.index("mode=$(core_unlock_mode)"), efi_enable.index("efibootmgr --create"))
        self.assertLess(efi_enable.index("efi_recovery_write"), efi_enable.index("efibootmgr --create"))
        self.assertEqual(efi_enable.count("efi_recovery_write"), 2)
        self.assertNotIn(">> \"$CORE_UNLOCK_EFI_RECOVERY\"", efi_enable)
        self.assertLess(
            efi_enable.index('EFI_RECOVERY_CANDIDATE="$number"'),
            efi_enable.index("[[ $create_rc -eq 0 ]]"),
        )
        recovery_writer = power[power.index("efi_recovery_write()") : power.index("efi_number_in_csv()")]
        self.assertLess(recovery_writer.index('sync "$tmp"'), recovery_writer.index('mv -f "$tmp"'))
        self.assertLess(recovery_writer.index('mv -f "$tmp"'), recovery_writer.index('sync "$CORE_UNLOCK_STATE_DIR"'))

    def test_secure_boot_check_accepts_unsupported_firmware(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
mokutil() { printf '%s\n' "This system doesn't support Secure Boot" >&2; return 1; }
core_unlock_secure_boot_disabled
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_secure_boot_check_still_rejects_enabled_and_unknown_states(self):
        cases = (
            ("SecureBoot enabled", "Secure Boot is enabled"),
            ("unexpected mokutil response", "Secure Boot state is unknown"),
        )
        for state, message in cases:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                result = self.run_power_shell(
                    f'''mokutil() {{ printf '%s\\n' {state!r}; }}\ncore_unlock_secure_boot_disabled\n''',
                    directory,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_mode_classifier_reports_all_authoritative_states(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
SYSTEMD_ACTIVE=0
NVRAM_ACTIVE=0
systemctl() {
    [[ "$1" == is-enabled && $SYSTEMD_ACTIVE -eq 1 ]] && { echo enabled; return 0; }
    return 1
}
verify_core_unlock_esp_state() { :; }
efibootmgr() {
    if [[ $NVRAM_ACTIVE -eq 0 ]]; then
        printf '%s\n' 'BootOrder: 0001'
        return 0
    fi
    printf '%s\n' 'BootOrder: 0007,0001'
    printf '%s\n' 'Boot0007* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
}
SYSTEMD_WANTS_DIR="$base/wants"
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
CORE_UNLOCK_EFIVARS_DIR="$base/efivars"
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
mkdir -p "$SYSTEMD_WANTS_DIR" "$(dirname "$CORE_UNLOCK_EFI_MASTER")" \
    "$CORE_UNLOCK_EFI_DIR" "$(dirname "$CORE_UNLOCK_EFI_LICENSE")" \
    "$CORE_UNLOCK_EFIVARS_DIR"
core_unlock_mode
SYSTEMD_ACTIVE=1; core_unlock_mode
SYSTEMD_ACTIVE=0; NVRAM_ACTIVE=1; core_unlock_mode
NVRAM_ACTIVE=0; printf image > "$CORE_UNLOCK_EFI_MASTER"; core_unlock_mode
cp "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE"
touch "$CORE_UNLOCK_EFI_LICENSE" "$CORE_UNLOCK_EFI_HEADER_LICENSE"
NVRAM_ACTIVE=1
printf 'BOOTNUM=0007\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nLABEL=%s\nLOADER=%s\n' \
    "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$CORE_UNLOCK_EFI_STATE"
printf '0007\n' > "$CORE_UNLOCK_EFI_BOOTNUM"
sha256sum "$CORE_UNLOCK_EFI_MASTER" | awk '{print $1}' > "$CORE_UNLOCK_EFI_IMAGE_HASH"
core_unlock_mode
SYSTEMD_ACTIVE=1; core_unlock_mode
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                ["none", "systemd", "partial", "partial", "efi", "conflict"],
            )

    def test_efi_removal_refuses_a_mismatched_recorded_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
efibootmgr() {
    printf '%s\n' "$*" >> "$base/efibootmgr.log"
    printf '%s\n' 'BootOrder: 0007,0001'
    printf '%s\n' 'Boot0007* Operator Entry HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
}
verify_core_unlock_esp_state() { :; }
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
mkdir -p "$(dirname "$CORE_UNLOCK_EFI_MASTER")" "$CORE_UNLOCK_EFI_DIR" \
    "$(dirname "$CORE_UNLOCK_EFI_LICENSE")"
touch "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" \
    "$CORE_UNLOCK_EFI_LICENSE" "$CORE_UNLOCK_EFI_HEADER_LICENSE"
printf 'BOOTNUM=0007\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nLABEL=%s\nLOADER=%s\n' \
    "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$CORE_UNLOCK_EFI_STATE"
remove_core_unlock_efi
''',
                directory,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatched label, loader, or ESP identity", result.stderr)
            self.assertTrue(Path(directory, "state", "efi-state").exists())
            log = Path(directory, "efibootmgr.log").read_text(encoding="utf-8")
            self.assertNotIn("--delete-bootnum", log)

    def test_efi_removal_deletes_only_the_exact_recorded_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
BOOT_ACTIVE=1
efibootmgr() {
    printf '%s\n' "$*" >> "$base/efibootmgr.log"
    if [[ "$*" == *"--delete-bootnum"* ]]; then BOOT_ACTIVE=0; return 0; fi
    if [[ $BOOT_ACTIVE -eq 1 ]]; then
        printf '%s\n' 'BootOrder: 0007,0001'
        printf '%s\n' 'Boot0007 BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
    else
        printf '%s\n' 'BootOrder: 0001'
    fi
}
verify_core_unlock_esp_state() { :; }
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
CORE_UNLOCK_EFIVARS_DIR="$base/efivars"
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
mkdir -p "$(dirname "$CORE_UNLOCK_EFI_MASTER")" "$CORE_UNLOCK_EFI_DIR" \
    "$(dirname "$CORE_UNLOCK_EFI_LICENSE")" "$CORE_UNLOCK_EFIVARS_DIR"
touch "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" \
    "$CORE_UNLOCK_EFI_LICENSE" "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
    "$CORE_UNLOCK_EFIVARS_DIR/BC250CoreUnlockAttempt-$CORE_UNLOCK_EFI_GUARD_GUID"
printf 'BOOTNUM=0007\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nLABEL=%s\nLOADER=%s\n' \
    "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$CORE_UNLOCK_EFI_STATE"
remove_core_unlock_efi
[[ ! -e "$CORE_UNLOCK_EFI_STATE" && ! -e "$CORE_UNLOCK_EFI_IMAGE" \
    && ! -e "$CORE_UNLOCK_EFI_MASTER" \
    && ! -e "$CORE_UNLOCK_EFIVARS_DIR/BC250CoreUnlockAttempt-$CORE_UNLOCK_EFI_GUARD_GUID" ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            log = Path(directory, "efibootmgr.log").read_text(encoding="utf-8")
            self.assertIn("--bootnum 0007 --delete-bootnum", log)

    def test_efi_removal_keeps_guard_when_boot_entry_deletion_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
efibootmgr() {
    if [[ "$*" == *"--delete-bootnum"* ]]; then return 1; fi
    printf '%s\n' 'BootOrder: 0007,0001'
    printf '%s\n' 'Boot0007* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
}
verify_core_unlock_esp_state() { :; }
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
CORE_UNLOCK_EFIVARS_DIR="$base/efivars"
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
mkdir -p "$base/state" "$CORE_UNLOCK_EFI_DIR" "$base/licenses" "$CORE_UNLOCK_EFIVARS_DIR"
touch "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" "$CORE_UNLOCK_EFI_LICENSE" \
    "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
    "$CORE_UNLOCK_EFIVARS_DIR/BC250CoreUnlockAttempt-$CORE_UNLOCK_EFI_GUARD_GUID"
printf 'BOOTNUM=0007\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nLABEL=%s\nLOADER=%s\n' \
    "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$CORE_UNLOCK_EFI_STATE"
remove_core_unlock_efi
''',
                directory,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Could not delete verified owned Boot0007", result.stderr)
            self.assertTrue(
                Path(
                    directory,
                    "efivars",
                    "BC250CoreUnlockAttempt-4f6f6f13-1ec2-4f26-a250-bc250c0e77ff",
                ).exists()
            )

    def test_efi_removal_recovers_transaction_without_committed_state(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
BOOT_ACTIVE=1
efibootmgr() {
    if [[ "$*" == *"--delete-bootnum"* ]]; then BOOT_ACTIVE=0; return 0; fi
    printf '%s\n' "$*" >> "$base/efibootmgr.log"
    if [[ $BOOT_ACTIVE -eq 1 ]]; then
        printf '%s\n' 'BootOrder: 000A,0001'
        printf '%s\n' 'Boot0001* Operator Boot HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x1000)/File(\EFI\BOOT\BOOTX64.EFI)'
        printf '%s\n' 'Boot000A* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
    else
        printf '%s\n' 'BootOrder: 0001'
        printf '%s\n' 'Boot0001* Operator Boot HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x1000)/File(\EFI\BOOT\BOOTX64.EFI)'
    fi
}
verify_core_unlock_recovery_esp_state() { :; }
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
mkdir -p "$base/state" "$CORE_UNLOCK_EFI_DIR" "$base/licenses"
touch "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" "$CORE_UNLOCK_EFI_LICENSE"
printf 'PHASE=create\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nBEFORE=0001\nAFTER=000A,0001\nCANDIDATE=000A\n' \
    > "$CORE_UNLOCK_EFI_RECOVERY"
remove_core_unlock_efi
[[ ! -e "$CORE_UNLOCK_EFI_RECOVERY" && ! -e "$CORE_UNLOCK_EFI_IMAGE" ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatched_new_boot_entry_retains_recovery_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
NEW_ENTRY=0
require_root() { :; }
core_unlock_lifecycle_lock() { :; }
core_unlock_lifecycle_unlock() { :; }
core_unlock_service_enabled() { return 1; }
install_core_unlock_files() { :; }
ensure_core_unlock_efi_tools() { :; }
core_unlock_secure_boot_disabled() { :; }
discover_core_unlock_esp() { :; }
python3() { :; }
sync() { :; }
install() {
    local -a args=()
    while (($#)); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
build_core_unlock_efi() {
    CORE_UNLOCK_EFI_BUILD="$base/build.efi"
    printf image > "$CORE_UNLOCK_EFI_BUILD"
}
efibootmgr() {
    printf '%s\n' "$*" >> "$base/efibootmgr.log"
    if [[ "$*" == *"--create"* ]]; then NEW_ENTRY=1; return 0; fi
    if [[ "$*" == *"--bootnum 000A --delete-bootnum"* ]]; then
        NEW_ENTRY=0
        return 0
    fi
    if [[ "$*" == *"-v"* ]]; then
            printf '%s\n' 'BootOrder: 000A,0001'
            printf '%s\n' 'Boot0001* Operator Boot HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x1000)/File(\EFI\BOOT\BOOTX64.EFI)'
        if [[ $NEW_ENTRY -eq 1 ]]; then
            printf '%s\n' 'Boot000A* Mangled Label HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
        fi
        return 0
    fi
    printf '%s\n' 'BootOrder: 000A,0001'
}
ROOT_DATA_DIR="$base/data"
CORE_UNLOCK_STATE_DIR="$ROOT_DATA_DIR/core-unlock"
CORE_UNLOCK_EFI_MASTER="$CORE_UNLOCK_STATE_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$CORE_UNLOCK_STATE_DIR/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$CORE_UNLOCK_STATE_DIR/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$CORE_UNLOCK_STATE_DIR/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$CORE_UNLOCK_STATE_DIR/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE_SOURCE="$base/EFI-LICENSE"
CORE_UNLOCK_EFI_HEADER_LICENSE_SOURCE="$base/EFI-HEADERS-LICENSE"
CORE_UNLOCK_EFI_LICENSE="$ROOT_DATA_DIR/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$ROOT_DATA_DIR/licenses/headers"
CORE_UNLOCK_ESP_SOURCE=/dev/test1
CORE_UNLOCK_ESP_DISK=/dev/test
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
printf license > "$CORE_UNLOCK_EFI_LICENSE_SOURCE"
printf headers > "$CORE_UNLOCK_EFI_HEADER_LICENSE_SOURCE"
core_unlock_efi_enable
''',
                directory,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not exactly match", result.stderr)
            log = Path(directory, "efibootmgr.log").read_text(encoding="utf-8")
            self.assertNotIn("--bootnum 000A --delete-bootnum", log)
            self.assertNotIn("--bootnum 0001 --delete-bootnum", log)
            self.assertTrue(Path(directory, "data", "core-unlock", "efi-state").exists())
            self.assertTrue(Path(directory, "data", "core-unlock", "efi-recovery").exists())
            self.assertTrue(
                Path(directory, "esp", "EFI", "bc250", "bc250-core-unlock.efi").exists()
            )

    def test_efi_enable_finalizes_only_a_fully_valid_retained_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
require_root() { :; }
core_unlock_lifecycle_lock() { :; }
core_unlock_lifecycle_unlock() { printf unlocked > "$base/unlocked"; }
core_unlock_mode() { printf partial; }
efi_configuration_complete() { [[ "$1" == 1 ]]; }
install_core_unlock_files() { exit 20; }
sync() { :; }
CORE_UNLOCK_STATE_DIR="$base/state"
CORE_UNLOCK_EFI_RECOVERY="$CORE_UNLOCK_STATE_DIR/efi-recovery"
mkdir -p "$CORE_UNLOCK_STATE_DIR"
touch "$CORE_UNLOCK_EFI_RECOVERY"
core_unlock_efi_enable
[[ ! -e "$CORE_UNLOCK_EFI_RECOVERY" && -e "$base/unlocked" ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Validated and finalized", result.stdout)

    def test_efi_enable_still_rejects_invalid_partial_state(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
require_root() { :; }
core_unlock_lifecycle_lock() { :; }
core_unlock_mode() { printf partial; }
efi_configuration_complete() { return 1; }
core_unlock_efi_enable
''',
                directory,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot repair incomplete or invalid partial EFI state", result.stderr)

    def test_boot_entry_checks_active_order_and_device_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_ESP_PART=1
CORE_UNLOCK_ESP_PARTUUID=11111111-2222-3333-4444-555555555555
active='BootOrder: 0007,0001
Boot0007* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
direct='BootOrder: 0007,0001
Boot0007* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/\EFI\bc250\bc250-core-unlock.efi'
inactive='BootOrder: 0007,0001
Boot0007 BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
wrong_device='BootOrder: 0007,0001
Boot0007* BC250 Core Unlock HD(2,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)'
extra_path='BootOrder: 0007,0001
Boot0007* BC250 Core Unlock HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x1000)/File(\EFI\bc250\bc250-core-unlock.efi)/File(\EFI\BOOT\BOOTX64.EFI)'
efi_boot_entry_matches_in 0007 1 "$active"
efi_boot_entry_matches_in 0007 1 "$direct"
[[ "$(efi_matching_boot_numbers_in "$direct")" == 0007 ]]
efi_boot_entry_matches_in 0007 0 "$inactive"
if efi_boot_entry_matches_in 0007 1 "$inactive"; then exit 20; fi
if efi_boot_entry_matches_in 0007 0 "$wrong_device"; then exit 21; fi
if efi_boot_entry_matches_in 0007 0 "$extra_path"; then exit 22; fi
[[ "$(efi_boot_order_first_in "$active")" == 0007 ]]
reordered=${active/BootOrder: 0007,0001/BootOrder: 0001,0007}
[[ "$(efi_boot_order_first_in "$reordered")" == 0001 ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_esp_discovery_requires_canonical_gpt_fat_mount(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_ESP_ROOT="$base/efi"
mkdir -p "$CORE_UNLOCK_ESP_ROOT"
findmnt() { printf '/dev/alias %s vfat rw,nosuid\n' "$CORE_UNLOCK_ESP_ROOT"; }
lsblk() { printf '/dev/test1 part /dev/test 1 11111111-2222-3333-4444-555555555555 c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n'; }
discover_core_unlock_esp
printf '%s %s %s %s\n' "$CORE_UNLOCK_ESP_SOURCE" "$CORE_UNLOCK_ESP_DISK" \
    "$CORE_UNLOCK_ESP_PART" "$CORE_UNLOCK_ESP_PARTUUID"
findmnt() { printf '/dev/alias / vfat rw\n'; }
if discover_core_unlock_esp; then exit 20; fi
[[ "$ESP_DISCOVERY_ERROR" == *"not an actual mountpoint"* ]]
findmnt() { printf '/dev/alias %s ext4 rw\n' "$CORE_UNLOCK_ESP_ROOT"; }
if discover_core_unlock_esp; then exit 21; fi
[[ "$ESP_DISCOVERY_ERROR" == *"FAT/vfat"* ]]
findmnt() { printf '/dev/alias %s vfat ro\n' "$CORE_UNLOCK_ESP_ROOT"; }
if discover_core_unlock_esp; then exit 22; fi
[[ "$ESP_DISCOVERY_ERROR" == *"read-only"* ]]
findmnt() { printf '/dev/alias %s vfat rw\n' "$CORE_UNLOCK_ESP_ROOT"; }
lsblk() { printf '/dev/test1 disk /dev/test 1 11111111-2222-3333-4444-555555555555 00000000-0000-0000-0000-000000000000\n'; }
if discover_core_unlock_esp; then exit 23; fi
[[ "$ESP_DISCOVERY_ERROR" == *"not a supported GPT EFI partition"* ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "/dev/test1 /dev/test 1 11111111-2222-3333-4444-555555555555",
                result.stdout,
            )

    def test_esp_discovery_resolves_steamos_automount_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_ESP_ROOT="$base/efi"
CORE_UNLOCK_STEAMOS_EFI_PARTSET="$base/self-efi"
mkdir -p "$CORE_UNLOCK_ESP_ROOT"
ln -s /dev/test3 "$CORE_UNLOCK_STEAMOS_EFI_PARTSET"
findmnt() {
    printf 'systemd-1 %s autofs rw,direct\n' "$CORE_UNLOCK_ESP_ROOT"
    printf '/dev/test3 %s vfat rw,nosuid\n' "$CORE_UNLOCK_ESP_ROOT"
}
lsblk() { printf '/dev/test3 part /dev/test 3 11111111-2222-3333-4444-555555555555 ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\n'; }
discover_core_unlock_esp
[[ "$CORE_UNLOCK_ESP_SOURCE" == /dev/test3 && "$CORE_UNLOCK_ESP_PART" == 3 ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_esp_discovery_rejects_unowned_basic_data_partition(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_ESP_ROOT="$base/efi"
CORE_UNLOCK_STEAMOS_EFI_PARTSET="$base/self-efi"
mkdir -p "$CORE_UNLOCK_ESP_ROOT"
ln -s /dev/other3 "$CORE_UNLOCK_STEAMOS_EFI_PARTSET"
findmnt() { printf '/dev/test3 %s vfat rw,nosuid\n' "$CORE_UNLOCK_ESP_ROOT"; }
lsblk() { printf '/dev/test3 part /dev/test 3 11111111-2222-3333-4444-555555555555 ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\n'; }
if discover_core_unlock_esp; then exit 20; fi
[[ "$ESP_DISCOVERY_ERROR" == *"not a supported GPT EFI partition"* ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_removal_retains_evidence_on_esp_or_nvram_query_failure(self):
        template = r'''
efibootmgr() { printf '%%s\n' "$*" >> "$base/efibootmgr.log"; %s; }
%s
CORE_UNLOCK_EFI_MASTER="$base/state/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$base/state/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$base/state/efi-recovery"
CORE_UNLOCK_EFI_DIR="$base/esp/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/header"
mkdir -p "$base/state" "$CORE_UNLOCK_EFI_DIR" "$base/licenses"
touch "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" "$CORE_UNLOCK_EFI_LICENSE"
printf 'BOOTNUM=0007\nESP_SOURCE=/dev/test1\nDISK=/dev/test\nPART=1\nPARTUUID=11111111-2222-3333-4444-555555555555\nLABEL=%%s\nLOADER=%%s\n' \
    "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$CORE_UNLOCK_EFI_STATE"
remove_core_unlock_efi
'''
        cases = (
            ("return 0", "verify_core_unlock_esp_state() { ESP_DISCOVERY_ERROR='identity mismatch'; return 1; }", "identity mismatch"),
            ("return 1", "verify_core_unlock_esp_state() { :; }", "Could not read EFI Boot entries"),
        )
        for efi_result, verifier, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                result = self.run_power_shell(template % (efi_result, verifier), directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertTrue(Path(directory, "state", "efi-state").exists())
                log = Path(directory, "efibootmgr.log").read_text(encoding="utf-8") if Path(directory, "efibootmgr.log").exists() else ""
                self.assertNotIn("--delete-bootnum", log)

    def test_guard_is_partial_state_and_failed_clear_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_EFIVARS_DIR="$base/efivars"
mkdir -p "$CORE_UNLOCK_EFIVARS_DIR"
guard=$(core_unlock_efi_guard_path)
touch "$guard"
core_unlock_service_enabled() { return 1; }
efibootmgr() { return 0; }
[[ "$(core_unlock_mode)" == partial ]]
rm() { :; }
if clear_core_unlock_efi_guard; then exit 20; fi
[[ -e "$guard" ]]
''',
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_removal_requires_nvram_query_when_uefi_runtime_is_available(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_power_shell(
                r'''
CORE_UNLOCK_EFIVARS_DIR="$base/efivars"
CORE_UNLOCK_EFI_MASTER="$base/state/master"
CORE_UNLOCK_EFI_STATE="$base/state/state"
CORE_UNLOCK_EFI_BOOTNUM="$base/state/bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$base/state/hash"
CORE_UNLOCK_EFI_RECOVERY="$base/state/recovery"
CORE_UNLOCK_EFI_IMAGE="$base/esp/image"
CORE_UNLOCK_EFI_LICENSE="$base/licenses/efi"
CORE_UNLOCK_EFI_HEADER_LICENSE="$base/licenses/headers"
mkdir -p "$CORE_UNLOCK_EFIVARS_DIR"
efibootmgr() { return 1; }
core_unlock_service_enabled() { return 1; }
[[ "$(core_unlock_mode)" == partial ]]
remove_core_unlock_efi
''',
                directory,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Could not verify", result.stderr)


if __name__ == "__main__":
    unittest.main()
