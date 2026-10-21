import importlib.util
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path

from scripts.menu_graph import parse
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bc250-memory-temperature.sh"
HELPER = ROOT / "memory-temperature/bc250-memory-temperature.py"
UPSTREAM_COMMIT = "4a2221d1da387fa2e738bb9368b39594e242ba4b"
SYMBOLS = (
    "queue_write_status_qid A 00000fa8 \n"
    "queue_store_word_head_for_qid A 00000fe4 \n"
    "queue_read_head_for_qid A 00000ffc \n"
    "umc_read A 000029f8 \n"
    "umc_write A 00002a74 \n"
    "reg_dump T 0003aab4 0000005e\n"
    "umc_read_temp_per_chip T 0003ab34 000000f6\n"
    "umc_read_temp_packed T 0003ac34 0000011e\n"
    "regdump_read T 0003ad54 00000042\n"
    "regdump_arr B 0003ad98 00000080\n"
    "c$1496 b 0003ae18 00000004\n"
    "c$1492 b 0003ae1c 00000004\n"
    "c$1481 b 0003ae20 00000004\n"
    "c$1477 b 0003ae24 00000004\n"
).encode("ascii")


def load_helper():
    spec = importlib.util.spec_from_file_location("bc250_memory_temperature", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSmu:
    def __init__(self, helper, handlers, payload, fail_write_number=None):
        self.helper = helper
        self.handlers = dict(handlers)
        self.payload = bytearray(payload)
        self.fail_write_number = fail_write_number
        self.write_count = 0
        self.closed = False
        self.writes = []
        self.messages = []
        self.responses = [0x2B292725, 0x2C2A2826]
        self.firmware = helper.SMU_VERSION

    def smu_read(self, address, count=1):
        size = count * 4
        if address == 0:
            return self.firmware.to_bytes(4, "little")
        for message, value in self.handlers.items():
            if address == self.helper.handler_slot(message):
                return value.to_bytes(4, "little")
        offset = address - self.helper.PAYLOAD_START
        return bytes(self.payload[offset : offset + size]).ljust(size, b"\0")

    def smu_write32(self, address, value):
        self.write_count += 1
        if self.fail_write_number == self.write_count:
            self.fail_write_number = None
            raise OSError("synthetic write failure")
        self.writes.append((address, value))
        for message in self.handlers:
            if address == self.helper.handler_slot(message):
                self.handlers[message] = value
                return
        if not self.helper.PAYLOAD_START <= address < self.helper.PAYLOAD_START + len(self.payload):
            raise AssertionError(f"write outside backed-up region: {address:#x}")
        offset = address - self.helper.PAYLOAD_START
        self.payload[offset : offset + 4] = value.to_bytes(4, "little")

    def close(self):
        self.closed = True

    def send_message(self, queue, message, arguments):
        self.messages.append((queue, message, arguments))
        return 1, self.responses.pop(0)


class MemoryTemperatureTests(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.payload = bytes((index * 3) & 0xFF for index in range(self.helper.PAYLOAD_SIZE))
        self.original = bytes((index * 7) & 0xFF for index in range(self.helper.RUNTIME_SIZE))
        self.handlers = self.helper.parse_symbols(SYMBOLS, len(self.payload))
        self.original_handlers = {5: 0x1234, 6: 0x2345, 7: 0x3456}

    @contextlib.contextmanager
    def fake_hardware(self, smu):
        with mock.patch.object(self.helper, "load_image", return_value=(self.payload, self.handlers)), mock.patch.object(
            self.helper, "load_upstream", return_value=(lambda: smu, lambda _smu: True)
        ):
            yield

    def legacy_backup(self, path, payload):
        path.write_text(json.dumps({
            "schemaVersion": 1,
            "upstreamCommit": self.helper.LEGACY_COMMIT,
            "handler": self.original_handlers[5],
            "payloadSha256": hashlib.sha256(payload).hexdigest(),
            "payload": base64.b64encode(payload).decode("ascii"),
        }), encoding="ascii")

    def test_shell_and_python_sources_parse(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        compile(HELPER.read_text(encoding="utf-8"), str(HELPER), "exec")

    def test_upstream_inputs_are_commit_and_checksum_pinned(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'UPSTREAM_COMMIT="{UPSTREAM_COMMIT}"', source)
        self.assertIn(
            "SMUPayload.bin 32ab902bb07a5a00cdb54f8686b8944fed8cb30abf394c395d5e8d421f756529",
            source,
        )
        self.assertIn(
            "LICENSE 2c077d99237afe7b5a57ad02c515d2eee309e1149f5f0af7d346b793d43bd753",
            source,
        )
        self.assertIn('curl --retry 3 --retry-all-errors -fsSL "$RAW_BASE/$relative"', source)
        self.assertIn('"$(sha256_file "$source_dir/$relative")" == "$expected"', source)
        self.assertNotIn("releases/latest", source)

    def test_live_writes_require_exact_acknowledgement(self):
        for action in ("patch", "restore"):
            result = subprocess.run(
                ["bash", str(SCRIPT), action],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"Usage: {SCRIPT} {action} --acknowledge-smu-risk", result.stderr)

    def test_status_does_not_create_or_touch_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            result = subprocess.run(
                ["bash", str(SCRIPT), "status"],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "BC250_MEMORY_TEMP_STATE_DIR": str(state),
                    "BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST": "1",
                },
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("source:   not prepared", result.stdout)
            self.assertFalse(state.exists())

    def test_verified_old_stage_can_restore_offline_but_cannot_patch(self):
        for action in ("restore", "patch"):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as directory:
                state = Path(directory) / "state"
                result = subprocess.run(
                    ["bash", "-c", r'''
script=$1; action=$2; set -- help; source "$script" >/dev/null
mkdir -p "$STATE_DIR/upstream-$LEGACY_COMMIT"
HELPER="$STATE_DIR/helper"
MANIFEST="$STATE_DIR/install.conf"
printf '%064d' 0 > "$HELPER"
printf '%s %064d\n' "$LEGACY_COMMIT" 0 > "$MANIFEST"
while read -r relative expected; do
    target="$STATE_DIR/upstream-$LEGACY_COMMIT/$relative"
    mkdir -p "${target%/*}"
    printf '%s' "$expected" > "$target"
done < <(legacy_files)
# Isolate hashing from the network-free routing test. The real pinned checksums
# are separately checked against the recorded commit/manifest in other tests.
sha256_file() { cat "$1"; }
verify_stage "$STATE_DIR/upstream-$LEGACY_COMMIT" "$LEGACY_COMMIT" legacy_files || exit 20
# Even interrupted replacement of the installed helper/manifest must not make
# the independently verified old transport unusable for schema-1 restoration.
rm "$HELPER" "$MANIFEST"
systemctl() { return 1; }
python3() { printf '%s\n' "$@" > "$STATE_DIR/invocation"; }
curl() { exit 30; }
run_smu_action "$action" --acknowledge-smu-risk
''', "_", str(SCRIPT), action],
                    capture_output=True,
                    text=True,
                    env={**os.environ, "BC250_MEMORY_TEMP_STATE_DIR": str(state),
                         "BC250_MEMORY_TEMP_LOCK_FILE": str(Path(directory) / "operation.lock"),
                         "BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST": "1"},
                )
                if action == "restore":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = (state / "invocation").read_text().splitlines()
                    self.assertEqual(args[0], str(HELPER))
                    self.assertEqual(args[1], "restore")
                    self.assertIn(str(state / ("upstream-" + self.helper.LEGACY_COMMIT)), args)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((state / "invocation").exists())

    def test_hardware_guard_requires_both_exact_pci_devices(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            pci = Path(directory)
            root = pci / helper.ROOT_BDF
            gpu = pci / helper.GPU_BDF
            root.mkdir()
            gpu.mkdir()
            (root / "vendor").write_text("0x1022\n", encoding="ascii")
            (root / "device").write_text("0x13e0\n", encoding="ascii")
            (gpu / "vendor").write_text("0x1002\n", encoding="ascii")
            (gpu / "device").write_text("0x13fe\n", encoding="ascii")
            previous = os.environ.get("BC250_MEMORY_TEMP_PCI_ROOT")
            os.environ["BC250_MEMORY_TEMP_PCI_ROOT"] = str(pci)
            try:
                helper.require_hardware()
                (gpu / "device").write_text("0xffff\n", encoding="ascii")
                with self.assertRaisesRegex(RuntimeError, "not the BC-250 GFX1013 GPU"):
                    helper.require_hardware()
            finally:
                if previous is None:
                    os.environ.pop("BC250_MEMORY_TEMP_PCI_ROOT", None)
                else:
                    os.environ["BC250_MEMORY_TEMP_PCI_ROOT"] = previous

    def test_original_smu_backup_is_atomic_and_self_validating(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "original-smu.json"
            payload = self.original
            helper.save_backup(path, self.original_handlers, payload)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(helper.read_backup(path), (self.original_handlers, payload, False))
            record = json.loads(path.read_text(encoding="ascii"))
            record["payloadSha256"] = "0" * 64
            path.write_text(json.dumps(record), encoding="ascii")
            with self.assertRaisesRegex(RuntimeError, "invalid original-firmware backup"):
                helper.read_backup(path)

    def test_partial_patch_write_rolls_back_to_recorded_original(self):
        helper = self.helper
        for failure in (3, helper.RUNTIME_SIZE // 4 + 2):
            smu = FakeSmu(helper, self.original_handlers, self.original, fail_write_number=failure)
            with self.subTest(failure=failure), self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
                backup = Path(directory) / "original-smu.json"
                with self.assertRaisesRegex(OSError, "synthetic write failure"):
                    helper.patch_payload(Path(directory), backup, True)
                self.assertEqual(smu.handlers, self.original_handlers)
                self.assertEqual(bytes(smu.payload), self.original)
                self.assertTrue(backup.exists())
                self.assertTrue(smu.closed)

    def test_cold_cycle_original_state_clears_stale_backup(self):
        helper = self.helper
        for legacy in (False, True):
            original = self.original[:176] if legacy else self.original
            smu = FakeSmu(helper, self.original_handlers, original)
            with self.subTest(legacy=legacy), self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
                backup = Path(directory) / "original-smu.json"
                if legacy:
                    self.legacy_backup(backup, original)
                else:
                    helper.save_backup(backup, self.original_handlers, original)
                helper.restore_payload(Path(directory), backup, True)
                self.assertFalse(backup.exists())
                self.assertEqual(bytes(smu.payload), original)
                self.assertEqual(smu.writes, [])

    def test_active_payload_without_backup_is_refused(self):
        helper = self.helper
        for handlers in (self.handlers, {**self.original_handlers, 5: helper.LEGACY_HANDLER}):
            smu = FakeSmu(helper, handlers, self.payload + bytes(144))
            with self.subTest(handlers=handlers), self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(RuntimeError, "no recorded original-SMU backup"):
                    helper.patch_payload(
                        Path(directory), Path(directory) / "missing.json", True
                    )
                self.assertEqual(smu.writes, [])

    def test_symbol_manifest_is_verified_and_has_exact_bss_extent(self):
        helper = self.helper
        self.assertEqual(hashlib.sha256(SYMBOLS).hexdigest(), helper.SYMBOLS_SHA256)
        self.assertEqual(self.handlers, {5: 0x3AB34, 6: 0x3AC34, 7: 0x3AD54})
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "SMUPayload.bin").write_bytes(self.payload)
            (source / "SMUPayload.symbols").write_bytes(SYMBOLS)
            with mock.patch.object(helper, "PAYLOAD_SHA256", hashlib.sha256(self.payload).hexdigest()):
                self.assertEqual(helper.load_image(source), (self.payload, self.handlers))
                (source / "SMUPayload.symbols").write_bytes(SYMBOLS + b"\n")
                with self.assertRaisesRegex(RuntimeError, "manifest failed checksum"):
                    helper.load_image(source)
            with self.assertRaisesRegex(RuntimeError, "payload failed checksum"):
                helper.load_payload(source)

    def test_symbol_bounds_and_duplicate_symbols_fail_closed(self):
        for manifest in (
            SYMBOLS.replace(b"0003ab34", b"0003dfff"),
            SYMBOLS.replace(b"000000f6", b"00000000"),
            SYMBOLS.replace(b"0003ad98", b"0003ad94"),
            SYMBOLS.replace(b"0003ae24", b"0003e000"),
            SYMBOLS.replace(b"0003ad54", b"0003ad90"),
            SYMBOLS.replace(b"umc_read_temp_packed T", b"umc_read_temp_packed A"),
            SYMBOLS + b"umc_read_temp_packed T 0003ac34 0000011e\n",
            SYMBOLS.replace(b"c$1477 b 0003ae24 00000004\n", b""),
        ):
            with self.subTest(manifest=manifest), self.assertRaises(RuntimeError):
                self.helper.parse_symbols(manifest, self.helper.PAYLOAD_SIZE)
        for message in (-1, 0xA9, True):
            with self.subTest(message=message), self.assertRaises(RuntimeError):
                self.helper.handler_slot(message)

    def test_install_backs_up_and_initializes_full_runtime_before_redirect(self):
        helper = self.helper
        smu = FakeSmu(helper, self.original_handlers, self.original)
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            original_write = smu.smu_write32

            def check_backup_before_write(address, value):
                self.assertEqual(helper.read_backup(backup), (self.original_handlers, self.original, False))
                original_write(address, value)

            with mock.patch.object(smu, "smu_write32", side_effect=check_backup_before_write):
                helper.patch_payload(Path(directory), backup, True)
            self.assertEqual(smu.handlers, self.handlers)
            self.assertEqual(bytes(smu.payload), self.payload + bytes(144))
            size = helper.RUNTIME_SIZE // 4
            self.assertTrue(all(address >= helper.PAYLOAD_START for address, _ in smu.writes[:size]))
            self.assertEqual(smu.writes[size:], [(helper.handler_slot(message), value) for message, value in self.handlers.items()])

    def test_mutable_bss_does_not_break_attestation_or_idempotence(self):
        helper = self.helper
        smu = FakeSmu(helper, self.handlers, self.payload + bytes(range(144)))
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            helper.save_backup(backup, self.original_handlers, self.original)
            helper.patch_payload(Path(directory), backup, True)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                helper.read_temperatures(Path(directory), True)
            reading = json.loads(output.getvalue())
            self.assertEqual([chip["chip"] for chip in reading["chips"]], list(range(8)))
            self.assertEqual([chip["code"] for chip in reading["chips"]], list(range(0x25, 0x2D)))
            self.assertEqual(reading["hotspotChip"], 7)
            self.assertEqual(smu.messages, [(3, 6, [0]), (3, 6, [1])])
            self.assertEqual(smu.writes, [])

    def test_packed_errors_do_not_emit_partial_averages(self):
        for raw, expected in ((0xFF292725, "stage 1 timeout"), (0xFE292725, "stage 2 timeout"), (0x99292725, "invalid temperature")):
            smu = FakeSmu(self.helper, self.handlers, self.payload + bytes(144))
            smu.responses = [raw]
            output = io.StringIO()
            with self.subTest(raw=raw), self.fake_hardware(smu), contextlib.redirect_stdout(output):
                with self.assertRaisesRegex(RuntimeError, expected):
                    self.helper.read_temperatures(Path("unused"), True)
                self.assertEqual(output.getvalue(), "")
                self.assertTrue(smu.closed)

    def test_corrupt_live_code_or_handler_is_refused_before_temperature_message(self):
        for bad_handler in (False, True):
            handlers = {**self.handlers, 7: 0x1234} if bad_handler else self.handlers
            payload = self.payload if bad_handler else bytes(self.helper.PAYLOAD_SIZE)
            smu = FakeSmu(self.helper, handlers, payload + bytes(144))
            with self.subTest(bad_handler=bad_handler), self.fake_hardware(smu):
                with self.assertRaisesRegex(RuntimeError, "failed attestation"):
                    self.helper.read_temperatures(Path("unused"), True)
                self.assertEqual(smu.messages, [])

    def test_restore_detaches_all_handlers_before_restoring_code_and_bss(self):
        helper = self.helper
        smu = FakeSmu(helper, self.handlers, self.payload + bytes(range(144)))
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            helper.save_backup(backup, self.original_handlers, self.original)
            helper.restore_payload(Path(directory), backup, True)
            self.assertEqual(smu.writes[:3], [(helper.handler_slot(message), value) for message, value in self.original_handlers.items()])
            self.assertEqual(bytes(smu.payload), self.original)
            self.assertEqual(smu.handlers, self.original_handlers)
            self.assertFalse(backup.exists())

    def test_failed_handler_detach_keeps_code_and_backup(self):
        helper = self.helper
        live = self.payload + bytes(144)
        smu = FakeSmu(helper, self.handlers, live, fail_write_number=2)
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            helper.save_backup(backup, self.original_handlers, self.original)
            with self.assertRaisesRegex(OSError, "synthetic write failure"):
                helper.restore_payload(Path(directory), backup, True)
            self.assertEqual(bytes(smu.payload), live)
            self.assertTrue(backup.exists())

    def test_mixed_partial_install_is_recovered_without_replacing_backup(self):
        helper = self.helper
        smu = FakeSmu(helper, {**self.original_handlers, 5: self.handlers[5]}, self.payload + bytes(144))
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            helper.save_backup(backup, self.original_handlers, self.original)
            before = backup.read_bytes()
            helper.patch_payload(Path(directory), backup, True)
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual(smu.handlers, self.handlers)
            self.assertEqual(smu.writes[:3], [(helper.handler_slot(message), value) for message, value in self.original_handlers.items()])

    def test_legacy_live_restore_preserves_exact_176_byte_extent(self):
        helper = self.helper
        for interrupted in (False, True):
            smu = FakeSmu(helper, {**self.original_handlers, 5: helper.LEGACY_HANDLER}, bytes(176) + self.original[176:])
            if interrupted:
                smu.handlers[5] = self.original_handlers[5]
            with self.subTest(interrupted=interrupted), self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
                backup = Path(directory) / "original-smu.json"
                self.legacy_backup(backup, self.original[:176])
                with mock.patch.object(helper, "load_image", side_effect=AssertionError("legacy restore needs no new image")):
                    helper.restore_payload(Path(directory), backup, True)
                self.assertEqual(bytes(smu.payload), self.original)
                self.assertEqual(smu.handlers, self.original_handlers)
                self.assertEqual(len(smu.writes), 1 + 176 // 4)
                self.assertFalse(backup.exists())

    def test_legacy_restore_refuses_overlapping_new_handler_without_writes(self):
        helper = self.helper
        smu = FakeSmu(helper, {**self.original_handlers, 5: helper.LEGACY_HANDLER, 6: self.handlers[6]}, self.original)
        with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            self.legacy_backup(backup, self.original[:176])
            with self.assertRaisesRegex(RuntimeError, "refusing legacy restore"):
                helper.restore_payload(Path(directory), backup, True)
            self.assertTrue(backup.exists())
            self.assertEqual(smu.writes, [])

    def test_legacy_backup_is_never_silently_promoted_or_overwritten(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "original-smu.json"
            self.legacy_backup(backup, self.original[:176])
            before = backup.read_bytes()
            with mock.patch.object(helper, "load_image", return_value=(self.payload, self.handlers)), mock.patch.object(helper, "load_upstream") as upstream:
                with self.assertRaisesRegex(RuntimeError, "restore it before installing"):
                    helper.patch_payload(Path(directory), backup, True)
                upstream.assert_not_called()
            self.assertEqual(backup.read_bytes(), before)

    def test_legacy_reads_remain_attested_and_use_per_chip_message(self):
        helper = self.helper
        legacy_payload = self.payload[:176]
        smu = FakeSmu(helper, {**self.original_handlers, 5: helper.LEGACY_HANDLER}, legacy_payload)
        smu.responses = [0x2525] * 8
        with self.fake_hardware(smu), mock.patch.object(helper, "LEGACY_SHA256", hashlib.sha256(legacy_payload).hexdigest()), contextlib.redirect_stdout(io.StringIO()):
            helper.read_temperatures(Path("unused"), True)
        self.assertEqual(smu.messages, [(3, 5, [chip]) for chip in range(8)])

    def test_invalid_backup_records_are_refused(self):
        helper = self.helper
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "original-smu.json"
            helper.save_backup(path, self.original_handlers, self.original)
            good = json.loads(path.read_text())
            invalid = [
                {**good, "upstreamCommit": helper.LEGACY_COMMIT},
                {**good, "schemaVersion": 1},
                {**good, "handlers": {"5": 0x1234}},
                {**good, "payload": base64.b64encode(self.original[:176]).decode()},
                {**good, "payloadSha256": "0" * 64},
                {**good, "handlers": {**good["handlers"], "6": True}},
                {**good, "handlers": {**good["handlers"], "6": -1}},
                {**good, "handlers": {**good["handlers"], "6": 1 << 32}},
                {**good, "handlers": {**good["handlers"], "6": helper.LEGACY_HANDLER}},
            ]
            for record in invalid:
                with self.subTest(record=record):
                    path.write_text(json.dumps(record))
                    with self.assertRaisesRegex(RuntimeError, "invalid original-firmware backup"):
                        helper.read_backup(path)
            path.write_text('{"schemaVersion":2,"schemaVersion":2}')
            with self.assertRaisesRegex(RuntimeError, "duplicate backup key"):
                helper.read_backup(path)
            alias = Path(directory) / "alias"
            alias.symlink_to(path)
            with self.assertRaisesRegex(RuntimeError, "not a regular file"):
                helper.read_backup(alias)

    def test_unknown_firmware_and_short_reads_refuse_before_unlock(self):
        helper = self.helper
        for action in ("patch", "restore", "read"):
            smu = FakeSmu(helper, self.original_handlers, self.original)
            smu.firmware ^= 1
            with self.fake_hardware(smu), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "original-smu.json"
                helper.save_backup(path, self.original_handlers, self.original)
                with self.assertRaisesRegex(RuntimeError, "unsupported SMU version"):
                    if action == "read":
                        helper.read_temperatures(Path(directory), True)
                    else:
                        getattr(helper, action + "_payload")(Path(directory), path, True)
                self.assertEqual(smu.writes, [])
                self.assertTrue(path.exists())
        smu = mock.Mock()
        for invalid in (b"", b"\x00", None, [0, 0, 0, 0]):
            smu.smu_read.return_value = invalid
            with self.subTest(invalid=invalid), self.assertRaisesRegex(RuntimeError, "short or invalid"):
                helper.read_u32(smu, 0)
        with self.assertRaisesRegex(RuntimeError, "unaligned"):
            helper.write_bytes(smu, helper.PAYLOAD_START, b"abc")

    def test_toolkit_release_and_references_include_component(self):
        toolkit = (ROOT / "bc250-toolkit.sh").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn('MEMORY_TEMP_SH="$SCRIPT_DIR/bc250-memory-temperature.sh"', toolkit)
        self.assertIn("memory-temperature-patch", toolkit)
        graph = parse(ROOT / "menus/toolkit.mmd")
        power_ids = {node.id for node in graph.choices("menu__cmd_power_menu")}
        device_ids = {node.id for node in graph.choices("menu__cmd_devices_menu")}
        self.assertIn("menu__cmd_memory_temperature_menu", power_ids)
        self.assertNotIn("menu__cmd_memory_temperature_menu", device_ids)
        self.assertNotIn("memory temperature (research)", toolkit)
        self.assertNotIn("memory-temperature research", toolkit)
        self.assertIn("bc250-mesa-patches memory-temperature", workflow)
        self.assertIn("| BC-250 GDDR6 Memory Temperature |", readme)
        self.assertIn(UPSTREAM_COMMIT, (ROOT / "memory-temperature/README.md").read_text())

    def test_no_boot_service_or_automatic_patch_is_added(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("systemctl enable", source)
        self.assertNotIn("WantedBy=", source)
        self.assertIn('systemctl stop "$GOVERNOR_SERVICE"', source)
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn("fcntl.LOCK_EX | fcntl.LOCK_NB", helper)
        self.assertLess(
            helper.index("write_bytes(smu, PAYLOAD_START, image)"),
            helper.index("smu.smu_write32(handler_slot(message), address)", helper.index("def patch_payload")),
        )


if __name__ == "__main__":
    unittest.main()
