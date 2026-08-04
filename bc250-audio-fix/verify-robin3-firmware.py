#!/usr/bin/env python3
"""Verify the Robin 3 ROM and metrics-related PMFW dispatch evidence."""

import argparse
import hashlib
import struct
from pathlib import Path


ROM_SHA256 = "48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5"
SMU_SHA256 = "6a3da1ef6024c3143283fb92468fd71d628e9402a751c4a9799a20f473549ad9"
SMU_ROM_OFFSET = 0x8FF000
SMU_SIZE = 262656
RUNTIME_TO_FILE = 0x100

DISPATCH = {
    0x708C: 0x1B998,  # primary set address high
    0x7094: 0x1B9B4,  # primary set address low
    0x709C: 0x1BA5C,  # primary SMU-to-DRAM transfer
    0x7574: 0x1BA5C,  # queues 3/4 message 0x22
    0x7654: 0x1B9F4,  # queues 3/4 message 0x3e, tools address high
    0x765C: 0x1BA10,  # queues 3/4 message 0x3f, tools address low
    0x7834: 0x1B998,  # queue 3 message 0x7a
    0x783C: 0x1B9B4,  # queue 3 message 0x7b
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def word(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "rom",
        nargs="?",
        type=Path,
        default=Path.home() / "tools/BC250_3.00_CHIPSETMENU.ROM",
    )
    parser.add_argument(
        "smu",
        nargs="?",
        type=Path,
        default=Path.home() / "tools/bc250/bc250-power/cyan-skillfish-smu-fw.bin",
    )
    args = parser.parse_args()

    rom = args.rom.read_bytes()
    smu = args.smu.read_bytes()
    checks = [
        ("ROM SHA-256", sha256(rom), ROM_SHA256),
        ("SMU SHA-256", sha256(smu), SMU_SHA256),
        ("SMU size", len(smu), SMU_SIZE),
        ("ROM SMU slice", rom[SMU_ROM_OFFSET : SMU_ROM_OFFSET + SMU_SIZE], smu),
    ]

    for runtime, handler in DISPATCH.items():
        checks.append(
            (
                f"dispatch 0x{runtime:04x}",
                word(smu, runtime + RUNTIME_TO_FILE),
                handler,
            )
        )

    checks.extend(
        [
            (
                "queue 4 argument register",
                word(smu, 0x703C + RUNTIME_TO_FILE),
                0x03010A8C,
            ),
            (
                "queue 4 response register",
                word(smu, 0x7040 + RUNTIME_TO_FILE),
                0x03010A84,
            ),
            (
                "queue 4 command register",
                word(smu, 0x7044 + RUNTIME_TO_FILE),
                0x03010A24,
            ),
            ("table 3 callback", word(smu, 0xCAC8 + RUNTIME_TO_FILE), 0x276DC),
            ("table 3 queue mask", smu[0xCAD4 + RUNTIME_TO_FILE], 0x18),
        ]
    )

    failed = False
    for name, actual, expected in checks:
        ok = actual == expected
        failed |= not ok
        if isinstance(expected, bytes):
            shown_actual = "matching bytes" if ok else "different bytes"
            shown_expected = "matching bytes"
        elif isinstance(expected, str):
            shown_actual = actual
            shown_expected = expected
        else:
            shown_actual = f"0x{actual:x}"
            shown_expected = f"0x{expected:x}"
        print(f"{'OK' if ok else 'FAIL':4} {name}: {shown_actual} (expected {shown_expected})")

    if not failed:
        print("OK   table 3 has distinct tools-address handlers")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
