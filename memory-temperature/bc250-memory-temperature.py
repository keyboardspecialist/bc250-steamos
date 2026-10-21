#!/usr/bin/env python3
# SPDX-License-Identifier: Unlicense
"""Guarded launcher for pan-Rijovich's BC-250 GDDR6 temperature payload."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


UPSTREAM_COMMIT = "4a2221d1da387fa2e738bb9368b39594e242ba4b"
LEGACY_COMMIT = "b7e6bffcb5d592fc03edde375b7598ddc79aa846"
PAYLOAD_START = 0x0003AA9C
PAYLOAD_END = 0x0003E000
LEGACY_HANDLER = 0x0003AAC4
HANDLER_REGISTER = 0x0000748C
LEGACY_SHA256 = "b31908460e932a615d9eafb6b3112e6448994f9f6fa656d1d80a8616ac1df4df"
PAYLOAD_SHA256 = "32ab902bb07a5a00cdb54f8686b8944fed8cb30abf394c395d5e8d421f756529"
SYMBOLS_SHA256 = "16c3baadae4a6790c315c71107e7ca9343dedd0d624d5bdaa507dc00ffe655a1"
PAYLOAD_SIZE = 764
RUNTIME_SIZE = 908  # .bin plus 144 bytes of .bss, including polling counters.
SMU_VERSION = 0x00580600
MESSAGE_SYMBOLS = {5: "umc_read_temp_per_chip", 6: "umc_read_temp_packed", 7: "regdump_read"}
ROOT_BDF = "0000:00:00.0"
GPU_BDF = "0000:01:00.0"


def fail(message):
    raise RuntimeError(message)


def read_identity(pci_root, bdf):
    base = pci_root / bdf
    try:
        return (
            (base / "vendor").read_text(encoding="ascii").strip().lower(),
            (base / "device").read_text(encoding="ascii").strip().lower(),
        )
    except OSError as error:
        fail(f"cannot read PCI identity for {bdf}: {error}")


def require_hardware():
    pci_root = Path(os.environ.get("BC250_MEMORY_TEMP_PCI_ROOT", "/sys/bus/pci/devices"))
    if read_identity(pci_root, ROOT_BDF) != ("0x1022", "0x13e0"):
        fail("00:00.0 is not the BC-250 Ariel root complex; refusing SMU access")
    if read_identity(pci_root, GPU_BDF) != ("0x1002", "0x13fe"):
        fail("01:00.0 is not the BC-250 GFX1013 GPU; refusing SMU access")


def require_root():
    if os.geteuid() != 0 and os.environ.get("BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST") != "1":
        fail("root privileges are required")


def load_upstream(source_dir):
    sys.path.insert(0, str(source_dir))
    import bc250_smu.api as api_module
    from bc250_smu.transport import Bc250PciTransport

    class LockedTransport(Bc250PciTransport):
        """Hold the shared 0xB8/0xBC PCI window lock for the whole operation."""

        def open(self):
            super().open()
            try:
                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                super().close()
                fail("another SMU client holds the PCI configuration lock")

        def close(self):
            if self._fd is not None:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            super().close()

    api_module.Bc250PciTransport = LockedTransport
    from bc250_smu import Bc250Smu
    from unlock import unlock

    return Bc250Smu, unlock


def read_bytes(smu, address, size):
    output = bytearray()
    while len(output) < size:
        count = min(18, (size - len(output) + 3) // 4)
        chunk = smu.smu_read(address + len(output), count)
        if not isinstance(chunk, (bytes, bytearray)) or len(chunk) != count * 4:
            fail("short or invalid SMU SRAM read; aborting")
        output.extend(chunk)
    return bytes(output[:size])


def write_bytes(smu, address, data):
    if address % 4 or len(data) % 4:
        fail("unaligned SMU write; refusing to overwrite unrecorded bytes")
    for offset in range(0, len(data), 4):
        value = int.from_bytes(data[offset : offset + 4].ljust(4, b"\0"), "little")
        smu.smu_write32(address + offset, value)


def read_u32(smu, address):
    return int.from_bytes(read_bytes(smu, address, 4), "little")


def save_backup(path, handlers, payload):
    record = {
        "schemaVersion": 2,
        "upstreamCommit": UPSTREAM_COMMIT,
        "handlers": {str(message): value for message, value in handlers.items()},
        "payloadSha256": hashlib.sha256(payload).hexdigest(),
        "payload": base64.b64encode(payload).decode("ascii"),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".backup.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as output:
            json.dump(record, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def valid_original_handler(value):
    return type(value) is int and 0 <= value <= 0xFFFFFFFF and not PAYLOAD_START <= value < PAYLOAD_END


def unique_json_object(pairs):
    record = {}
    for key, value in pairs:
        if key in record:
            raise ValueError(f"duplicate backup key: {key}")
        record[key] = value
    return record


def read_backup(path):
    try:
        if path.is_symlink() or not path.is_file():
            fail("invalid original-firmware backup: not a regular file")
        record = json.loads(path.read_text(encoding="ascii"), object_pairs_hook=unique_json_object)
        payload = base64.b64decode(record["payload"], validate=True)
        legacy = record.get("schemaVersion") == 1 and record.get("upstreamCommit") == LEGACY_COMMIT
        modern = record.get("schemaVersion") == 2 and record.get("upstreamCommit") == UPSTREAM_COMMIT
        handlers = {5: record["handler"]} if legacy else {
            int(message): value for message, value in record["handlers"].items()
        }
        valid = (
            (legacy or modern)
            and type(record.get("schemaVersion")) is int
            and set(handlers) == ({5} if legacy else {5, 6, 7})
            and (legacy or set(record["handlers"]) == {"5", "6", "7"})
            and all(valid_original_handler(value) for value in handlers.values())
            and len(payload) == (176 if legacy else RUNTIME_SIZE)
            and hashlib.sha256(payload).hexdigest() == record.get("payloadSha256")
        )
    except (AttributeError, TypeError, KeyError, OSError, ValueError) as error:
        fail(f"invalid original-firmware backup: {error}")
    if not valid:
        fail("invalid original-firmware backup")
    return handlers, payload, legacy


def load_payload(source_dir):
    payload = (source_dir / "SMUPayload.bin").read_bytes()
    if hashlib.sha256(payload).hexdigest() != PAYLOAD_SHA256:
        fail("staged SMU payload failed checksum verification")
    if len(payload) != PAYLOAD_SIZE:
        fail("staged SMU payload has an unexpected size")
    return payload


def parse_symbols(data, payload_size):
    """Validate the pinned GNU nm manifest, including the mutable .bss extent."""
    symbols = {}
    try:
        for line in data.decode("ascii").splitlines():
            fields = line.split()
            if len(fields) not in (3, 4) or fields[0] in symbols:
                fail("invalid or duplicate payload symbol")
            name, kind, address = fields[:3]
            symbols[name] = (kind, int(address, 16), int(fields[3], 16) if len(fields) == 4 else 0)
    except (UnicodeError, ValueError) as error:
        fail(f"invalid payload symbol manifest: {error}")
    binary_end = PAYLOAD_START + payload_size
    runtime_end = binary_end
    for kind, address, size in symbols.values():
        if kind in ("T", "t", "B", "b"):
            if size <= 0 or address < PAYLOAD_START or address + size > PAYLOAD_END:
                fail("payload symbol outside reserved SRAM bounds")
            if kind in ("T", "t") and address + size > binary_end:
                fail("handler text is not fully present in the payload binary")
            if kind in ("B", "b") and address < binary_end:
                fail("mutable payload state overlaps immutable binary")
            runtime_end = max(runtime_end, address + size)
    handlers = {}
    for message, name in MESSAGE_SYMBOLS.items():
        if name not in symbols or symbols[name][0] not in ("T", "t"):
            fail(f"missing text handler symbol: {name}")
        handlers[message] = symbols[name][1]
    runtime_size = (runtime_end - PAYLOAD_START + 3) & ~3
    if payload_size != PAYLOAD_SIZE or runtime_size != RUNTIME_SIZE:
        fail("unexpected payload runtime extent")
    return handlers


def load_image(source_dir):
    payload = load_payload(source_dir)
    symbols = (source_dir / "SMUPayload.symbols").read_bytes()
    if hashlib.sha256(symbols).hexdigest() != SYMBOLS_SHA256:
        fail("staged SMU symbol manifest failed checksum verification")
    return payload, parse_symbols(symbols, len(payload))


def handler_slot(message):
    if type(message) is not int or not 0 <= message < 0xA9:
        fail("invalid Queue 3 handler index")
    return 0x7464 + message * 8  # Only handler u32; never the adjacent flags.


def read_handlers(smu, messages):
    return {message: read_u32(smu, handler_slot(message)) for message in messages}


def restore_bytes(smu, handlers, original):
    # Detach every redirected entry before overwriting executable code. If this
    # fails, leave the payload intact and retain the durable backup for recovery.
    for message, address in handlers.items():
        smu.smu_write32(handler_slot(message), address)
        if read_u32(smu, handler_slot(message)) != address:
            fail("original SMU handler read-back verification failed")
    write_bytes(smu, PAYLOAD_START, original)
    if read_bytes(smu, PAYLOAD_START, len(original)) != original:
        fail("original SMU payload read-back verification failed")


def require_firmware(smu):
    if read_u32(smu, 0) != SMU_VERSION:
        fail("unsupported SMU version; expected 0.58.6.0 (ASRock P3.0)")


def patch_payload(source_dir, backup_path, acknowledge):
    if not acknowledge:
        fail("patch requires --acknowledge-smu-risk")
    payload, handlers = load_image(source_dir)
    backup = read_backup(backup_path) if backup_path.exists() or backup_path.is_symlink() else None
    if backup is not None and backup[2]:
        fail("legacy original-SMU backup retained; restore it before installing the new payload")
    Bc250Smu, unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    original_handlers = None
    original_payload = None
    changed = False
    try:
        require_firmware(smu)
        unlock(smu)
        current_handlers = read_handlers(smu, handlers)
        current_payload = read_bytes(smu, PAYLOAD_START, RUNTIME_SIZE)
        if current_handlers == handlers:
            if current_payload[:len(payload)] != payload:
                fail("the SMU handler points at a modified or incomplete payload")
            if backup is None:
                fail("the live payload has no recorded original-SMU backup; cold-power-cycle before continuing")
            print("BC-250 memory-temperature payload is already active.")
            return
        if backup is not None:
            saved_handlers, saved_payload, _legacy = backup
            if any(current_handlers[message] not in (saved_handlers[message], handlers[message]) for message in handlers):
                fail("live SMU state does not match the recorded original backup")
            if current_payload != saved_payload or current_handlers != saved_handlers:
                print("Recovering bytes from an interrupted payload installation.")
                restore_bytes(smu, saved_handlers, saved_payload)
                current_payload = saved_payload
                current_handlers = saved_handlers
        else:
            if not all(valid_original_handler(value) for value in current_handlers.values()):
                fail("an existing or foreign payload has no recorded original-SMU backup; restore it or cold-power-cycle")
            save_backup(backup_path, current_handlers, current_payload)
        original_handlers, original_payload = current_handlers, current_payload
        changed = True
        image = payload + bytes(RUNTIME_SIZE - len(payload))
        write_bytes(smu, PAYLOAD_START, image)
        if read_bytes(smu, PAYLOAD_START, len(image)) != image:
            fail("SMU payload read-back verification failed")
        for message, address in handlers.items():
            smu.smu_write32(handler_slot(message), address)
            if read_u32(smu, handler_slot(message)) != address:
                fail("SMU handler read-back verification failed")
        print("BC-250 memory-temperature payload installed for this SMU runtime.")
        print("A cold power cycle resets the live SMU patch.")
    except BaseException:
        if changed and original_handlers is not None and original_payload is not None:
            try:
                restore_bytes(smu, original_handlers, original_payload)
            except Exception as rollback_error:
                print(
                    f"rollback failed ({rollback_error}); cold-power-cycle the system",
                    file=sys.stderr,
                )
        raise
    finally:
        smu.close()


def restore_payload(source_dir, backup_path, acknowledge):
    if not acknowledge:
        fail("restore requires --acknowledge-smu-risk")
    original_handlers, original_payload, legacy = read_backup(backup_path)
    if legacy:
        handlers = {5: LEGACY_HANDLER}
    else:
        _payload, handlers = load_image(source_dir)
    Bc250Smu, unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    try:
        require_firmware(smu)
        unlock(smu)
        current_handlers = read_handlers(smu, handlers)
        if legacy and any(not valid_original_handler(value) for value in read_handlers(smu, (6, 7)).values()):
            fail("another payload uses Queue 3 messages 6/7; refusing legacy restore")
        current_payload = read_bytes(smu, PAYLOAD_START, len(original_payload))
        if current_handlers == original_handlers and current_payload == original_payload:
            backup_path.unlink()
            print("SMU is already in its recorded original state; cleared the stale backup.")
            return
        if any(current_handlers[message] not in (handlers[message], original_handlers[message]) for message in handlers):
            fail("live SMU handler matches neither the patch nor the recorded original")
        restore_bytes(smu, original_handlers, original_payload)
        backup_path.unlink()
        print("Original SMU handler and overwritten bytes restored.")
    finally:
        smu.close()


def read_temperatures(source_dir, json_output):
    payload, handlers = load_image(source_dir)
    Bc250Smu, _unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    try:
        require_firmware(smu)
        legacy = read_u32(smu, HANDLER_REGISTER) == LEGACY_HANDLER
        if legacy:
            if hashlib.sha256(read_bytes(smu, PAYLOAD_START, 176)).hexdigest() != LEGACY_SHA256:
                fail("live legacy SMU payload failed attestation")
        elif read_handlers(smu, handlers) != handlers or read_bytes(smu, PAYLOAD_START, len(payload)) != payload:
            fail("live SMU payload failed attestation; run the patch command first")
        chips = []
        for selector in range(8 if legacy else 2):
            raw = smu.send_message(3, 0x05 if legacy else 0x06, [selector])[1]
            if type(raw) is not int or not 0 <= raw <= 0xFFFFFFFF:
                fail("invalid SMU temperature response")
            if legacy and (raw >> 16 or ((raw >> 8) & 0xFF) != (raw & 0xFF)):
                fail(f"chip {selector} returned an invalid MR3 response: 0x{raw:08X}")
            for slot in range(1 if legacy else 4):
                chip = selector if legacy else selector + 2 * slot
                code = (raw >> (slot * 8)) & 0xFF
                if code in (0xFF, 0xFE):
                    fail(f"chip {chip} UMC stage {1 if code == 0xFF else 2} timeout; no temperature reported")
                temperature = code * 2 - 40
                if not -40 <= temperature <= 150:
                    fail(f"chip {chip} returned an invalid temperature code: 0x{code:02X}")
                chips.append({"chip": chip, "raw": raw, "code": code, "temperatureC": temperature})
    finally:
        smu.close()
    chips.sort(key=lambda item: item["chip"])
    average = sum(item["temperatureC"] for item in chips) / len(chips)
    hotspot = max(chips, key=lambda item: item["temperatureC"])
    if json_output:
        print(json.dumps({
            "chips": chips,
            "averageC": average,
            "hotspotC": hotspot["temperatureC"],
            "hotspotChip": hotspot["chip"],
        }, separators=(",", ":")))
        return
    print("Chip  Response    Code  Temperature")
    for item in chips:
        print(
            f"{item['chip']:>4}  0x{item['raw']:08X}  0x{item['code']:02X}  "
            f"{item['temperatureC']:>6.1f} C"
        )
    print(f"Average: {average:.1f} C")
    print(f"Hotspot: {hotspot['temperatureC']:.1f} C (chip {hotspot['chip']})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("patch", "read", "restore"))
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--acknowledge-smu-risk", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    require_root()
    require_hardware()
    backup_path = args.state_dir / "original-smu.json"
    if args.action == "patch":
        patch_payload(args.source_dir, backup_path, args.acknowledge_smu_risk)
    elif args.action == "restore":
        restore_payload(args.source_dir, backup_path, args.acknowledge_smu_risk)
    else:
        read_temperatures(args.source_dir, args.json)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(f"[bc250-memory-temperature] {error}")
