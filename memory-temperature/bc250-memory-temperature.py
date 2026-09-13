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


UPSTREAM_COMMIT = "b7e6bffcb5d592fc03edde375b7598ddc79aa846"
PAYLOAD_START = 0x0003AA9C
PAYLOAD_HANDLER = 0x0003AAC4
HANDLER_REGISTER = 0x0000748C
PAYLOAD_SHA256 = "b31908460e932a615d9eafb6b3112e6448994f9f6fa656d1d80a8616ac1df4df"
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
        output.extend(smu.smu_read(address + len(output), count))
    return bytes(output[:size])


def write_bytes(smu, address, data):
    for offset in range(0, len(data), 4):
        value = int.from_bytes(data[offset : offset + 4].ljust(4, b"\0"), "little")
        smu.smu_write32(address + offset, value)


def read_u32(smu, address):
    return int.from_bytes(read_bytes(smu, address, 4), "little")


def write_backup(path, handler, payload):
    record = {
        "schemaVersion": 1,
        "upstreamCommit": UPSTREAM_COMMIT,
        "handler": handler,
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
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def read_backup(path, payload_size):
    try:
        record = json.loads(path.read_text(encoding="ascii"))
        payload = base64.b64decode(record["payload"], validate=True)
        valid = (
            record.get("schemaVersion") == 1
            and record.get("upstreamCommit") == UPSTREAM_COMMIT
            and isinstance(record.get("handler"), int)
            and len(payload) == payload_size
            and hashlib.sha256(payload).hexdigest() == record.get("payloadSha256")
        )
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        fail(f"invalid original-firmware backup: {error}")
    if not valid:
        fail("invalid original-firmware backup")
    return record["handler"], payload


def load_payload(source_dir):
    payload = (source_dir / "SMUPayload.bin").read_bytes()
    if hashlib.sha256(payload).hexdigest() != PAYLOAD_SHA256:
        fail("staged SMU payload failed checksum verification")
    if len(payload) != 176:
        fail("staged SMU payload has an unexpected size")
    return payload


def patch_payload(source_dir, backup_path, acknowledge):
    if not acknowledge:
        fail("patch requires --acknowledge-smu-risk")
    payload = load_payload(source_dir)
    Bc250Smu, unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    original_handler = None
    original_payload = None
    changed = False
    try:
        unlock(smu)
        current_handler = read_u32(smu, HANDLER_REGISTER)
        current_payload = read_bytes(smu, PAYLOAD_START, len(payload))
        if current_handler == PAYLOAD_HANDLER:
            if current_payload != payload:
                fail("the SMU handler points at a modified or incomplete payload")
            if not backup_path.exists():
                fail("the live payload has no recorded original-SMU backup; cold-power-cycle before continuing")
            read_backup(backup_path, len(payload))
            print("BC-250 memory-temperature payload is already active.")
            return
        if backup_path.exists():
            saved_handler, saved_payload = read_backup(backup_path, len(payload))
            if current_handler != saved_handler:
                fail("live SMU state does not match the recorded original backup")
            if current_payload != saved_payload:
                print("Recovering bytes from an interrupted payload installation.")
                write_bytes(smu, PAYLOAD_START, saved_payload)
                if read_bytes(smu, PAYLOAD_START, len(payload)) != saved_payload:
                    fail("could not recover the interrupted payload installation")
                current_payload = saved_payload
        else:
            write_backup(backup_path, current_handler, current_payload)
        original_handler, original_payload = current_handler, current_payload
        changed = True
        write_bytes(smu, PAYLOAD_START, payload)
        if read_bytes(smu, PAYLOAD_START, len(payload)) != payload:
            fail("SMU payload read-back verification failed")
        smu.smu_write32(HANDLER_REGISTER, PAYLOAD_HANDLER)
        if read_u32(smu, HANDLER_REGISTER) != PAYLOAD_HANDLER:
            fail("SMU handler read-back verification failed")
        print("BC-250 memory-temperature payload installed for this SMU runtime.")
        print("A cold power cycle resets the live SMU patch.")
    except BaseException:
        if changed and original_handler is not None and original_payload is not None:
            try:
                smu.smu_write32(HANDLER_REGISTER, original_handler)
                write_bytes(smu, PAYLOAD_START, original_payload)
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
    payload = load_payload(source_dir)
    original_handler, original_payload = read_backup(backup_path, len(payload))
    Bc250Smu, unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    try:
        unlock(smu)
        current_handler = read_u32(smu, HANDLER_REGISTER)
        current_payload = read_bytes(smu, PAYLOAD_START, len(payload))
        if current_handler == original_handler and current_payload == original_payload:
            backup_path.unlink()
            print("SMU is already in its recorded original state; cleared the stale backup.")
            return
        if current_handler not in (PAYLOAD_HANDLER, original_handler):
            fail("live SMU handler matches neither the patch nor the recorded original")
        write_bytes(smu, PAYLOAD_START, original_payload)
        if read_bytes(smu, PAYLOAD_START, len(payload)) != original_payload:
            fail("original SMU payload read-back verification failed")
        if current_handler != original_handler:
            smu.smu_write32(HANDLER_REGISTER, original_handler)
        if read_u32(smu, HANDLER_REGISTER) != original_handler:
            fail("original SMU handler read-back verification failed")
        if read_bytes(smu, PAYLOAD_START, len(payload)) != original_payload:
            fail("original SMU payload read-back verification failed")
        backup_path.unlink()
        print("Original SMU handler and overwritten bytes restored.")
    finally:
        smu.close()


def read_temperatures(source_dir, json_output):
    payload = load_payload(source_dir)
    Bc250Smu, _unlock = load_upstream(source_dir)
    smu = Bc250Smu()
    try:
        if read_u32(smu, HANDLER_REGISTER) != PAYLOAD_HANDLER:
            fail("memory-temperature payload is not active; run the patch command first")
        if read_bytes(smu, PAYLOAD_START, len(payload)) != payload:
            fail("live SMU payload failed attestation")
        chips = []
        for chip in range(8):
            raw = smu.send_message(3, 0x05, [chip])[1]
            code = raw & 0xFF
            temperature = code * 2 - 40
            if raw >> 16 or ((raw >> 8) & 0xFF) != code or not -40 <= temperature <= 150:
                fail(f"chip {chip} returned an invalid MR3 response: 0x{raw:08X}")
            chips.append({"chip": chip, "raw": raw, "code": code, "temperatureC": temperature})
    finally:
        smu.close()
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
    print("Chip  MR3 raw     Code  Temperature")
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
