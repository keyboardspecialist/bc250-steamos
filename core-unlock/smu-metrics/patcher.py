#!/usr/bin/env python3
"""
apply or verify firmware patches from an intel-hex file.
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bc250_smu import Bc250Smu


METRICS_TICK_SLOT = 0xC700 + 0x27 * 4
METRICS_TICK_HANDLERS = (0x29AEC, 0x29848)
METRICS_TICK_NOOP = 0x1B220
METRICS_TABLE = 0x3C000
METRICS_TABLE_SIZE = 0x11C
METRICS_POINTERS = (0x17F34, 0x17F24)


def read_hex(path):
    sites, used, base, eof = [], set(), 0, False
    with open(path, encoding="ascii") as stream:
        for line_number, line in enumerate(stream, 1):
            line = line.strip()
            if not line:
                continue
            if eof:
                raise ValueError(f"record after Intel HEX EOF at line {line_number}")
            if not line.startswith(":"):
                raise ValueError(f"invalid Intel HEX line {line_number}")
            record = bytes.fromhex(line[1:])
            if len(record) < 5 or len(record) != record[0] + 5 or sum(record) & 0xFF:
                raise ValueError(f"invalid Intel HEX record at line {line_number}")
            count = record[0]
            addr = struct.unpack(">H", record[1:3])[0]
            typ = record[3]
            data = record[4:4 + count]
            if typ == 2:
                if count != 2:
                    raise ValueError(f"invalid segment record at line {line_number}")
                base = struct.unpack(">H", data)[0] << 4
            elif typ == 0:
                addresses = set(range(base + addr, base + addr + count))
                if used & addresses:
                    raise ValueError(f"overlapping data record at line {line_number}")
                used |= addresses
                sites.append((base + addr, data))
            elif typ == 1:
                if count != 0 or addr != 0:
                    raise ValueError(f"invalid EOF record at line {line_number}")
                eof = True
            elif typ == 3:
                if count != 4 or addr != 0:
                    raise ValueError(f"invalid start-address record at line {line_number}")
            else:
                raise ValueError(f"unsupported Intel HEX record type {typ} at line {line_number}")
    if not eof:
        raise ValueError("Intel HEX file has no EOF record")
    return sorted(sites)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
    base = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="verify without writing")
    ap.add_argument("--hex", default=os.path.join(base, "metrics-8core.hex"))
    ap.add_argument(
        "--original",
        default=os.path.join(base, "metrics-8core-original.hex"),
        help="known-good Robin 1/3 bytes for every patched range",
    )
    ns = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("needs root")

    patches = read_hex(ns.hex)
    originals = read_hex(ns.original)
    patch_layout = [(address, len(data)) for address, data in patches]
    original_layout = [(address, len(data)) for address, data in originals]
    if original_layout != patch_layout:
        sys.exit("original-byte manifest does not match the patch layout")
    original_by_address = dict(originals)
    if any(original_by_address[address] == replacement for address, replacement in patches):
        sys.exit("patch manifest contains an unchanged record")

    smu = Bc250Smu()
    ok = True
    completed = False
    metrics_tick_paused = False
    paused_handler = None
    try:
        metrics_ranges = ((0x17F24, 0x17F38), (0x2980E, 0x29CD0), (0x31EFF, 0x31F6B))
        patches_metrics = any(
            addr < end and addr + len(data) > start
            for addr, data in patches
            for start, end in metrics_ranges
        )
        relocates_metrics = (
            (0x17F24, struct.pack("<I", METRICS_TABLE)) in patches
            and (0x17F34, struct.pack("<I", METRICS_TABLE - 0x100)) in patches
        )
        # Change code first, then the secondary anchor, and the primary pointer last.
        apply_order = sorted(
            patches,
            key=lambda item: (
                next(
                    (priority for priority, pointer in enumerate(METRICS_POINTERS, 1)
                     if item[0] <= pointer < item[0] + len(item[1])),
                    0,
                ),
                item[0],
            ),
        )
        for addr, new in patches:
            original = original_by_address[addr]
            current = smu.smu_read_bytes(addr, len(new))
            if current not in (original, new):
                raise RuntimeError(f"unexpected target bytes at 0x{addr:05x}: {current.hex()}")

        if patches_metrics and not ns.check:
            handler = struct.unpack("<I", smu.smu_read_bytes(METRICS_TICK_SLOT, 4))[0]
            if handler not in METRICS_TICK_HANDLERS:
                raise RuntimeError(
                    f"unexpected metrics tick handler 0x{handler:05x}; reboot before retrying"
                )
            paused_handler = handler
            metrics_tick_paused = True
            smu.smu_write32(METRICS_TICK_SLOT, METRICS_TICK_NOOP)
            if struct.unpack("<I", smu.smu_read_bytes(METRICS_TICK_SLOT, 4))[0] != METRICS_TICK_NOOP:
                raise RuntimeError("failed to pause the metrics tick handler")
            print(f"pause metrics tick {handler:05X} OK")
        elif patches_metrics:
            handler = struct.unpack("<I", smu.smu_read_bytes(METRICS_TICK_SLOT, 4))[0]
            if handler not in METRICS_TICK_HANDLERS:
                print(f"check metrics tick {handler:05X} ** MISMATCH")
                ok = False

        table_initialized = False
        for addr, new in apply_order:
            if not ns.check:
                print(f"patch {addr:05X} begin")
            switches_metrics_table = any(
                addr <= pointer < addr + len(new) for pointer in METRICS_POINTERS
            )
            if relocates_metrics and switches_metrics_table and not table_initialized and not ns.check:
                smu.smu_memset32(METRICS_TABLE, 0, METRICS_TABLE_SIZE // 4)
                for offset in range(0, METRICS_TABLE_SIZE, 18 * 4):
                    words = min(18, (METRICS_TABLE_SIZE - offset) // 4)
                    if any(smu.smu_read(METRICS_TABLE + offset, words)):
                        raise RuntimeError("failed to initialize the relocated metrics table")
                table_initialized = True
            cur = smu.smu_read_bytes(addr, len(new))
            if ns.check or cur == new:
                status = "OK" if cur == new else f"** MISMATCH (want {new.hex()})"
                print(f"check {addr:05X} {cur.hex()} {status}")
                ok &= cur == new
            else:
                smu.smu_write_bytes(addr, new)
                got = smu.smu_read_bytes(addr, len(new))
                status = "OK" if got == new else "** VERIFY FAIL"
                print(f"apply {addr:05X} {cur.hex()} -> {got.hex()} {status}")
                ok &= got == new
        completed = True
    finally:
        if metrics_tick_paused:
            if completed and ok:
                smu.smu_write32(METRICS_TICK_SLOT, paused_handler)
                restored = struct.unpack("<I", smu.smu_read_bytes(METRICS_TICK_SLOT, 4))[0]
                ok &= restored == paused_handler
                print(f"restore metrics tick {restored:05X} {'OK' if ok else '** VERIFY FAIL'}")
            else:
                print("metrics tick remains paused because patch verification failed", file=sys.stderr)
        smu.close()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
