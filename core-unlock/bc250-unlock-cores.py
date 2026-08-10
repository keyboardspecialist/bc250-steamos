#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Enable the BC-250's two disabled CPU cores (6c/12t to 8c/16t).

Derived from rw-r-r-0644/bc250-core-unlock commit 87ec098. See
core-unlock/README.md and LICENSE in the toolkit source for attribution,
integration changes, and license terms.
"""

import fcntl
import glob
import os
from pathlib import Path
import struct
import subprocess
import sys
import time


BDF = "0000:00:00.0"
PCI_CONFIG = Path("/sys/bus/pci/devices") / BDF / "config"
BC250_VENDOR, BC250_DEVICE = "0x1002", "0x13fe"
MASK_REG = 0x0115A870
MSG_WRITE_FF = 0x98
Q3_CMD, Q3_RSP, Q3_ARG = 0x03B10A20, 0x03B10A80, 0x03B10A88
DONE = {0x01, 0xFF, 0xFE, 0xFD, 0xFC}
STATE_DIR = Path(
    os.environ.get(
        "BC250_CORE_UNLOCK_STATE_DIR", "/var/lib/bc250-control/core-unlock"
    )
)
PENDING = STATE_DIR / "reboot-pending"
LOCK_PATH = Path(
    os.environ.get("BC250_CORE_UNLOCK_LOCK", "/run/lock/bc250-core-unlock.lock")
)


class OperationLock:
    def __enter__(self):
        self.fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, _type, _value, _traceback):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def is_bc250():
    for vendor_path in glob.glob("/sys/bus/pci/devices/*/vendor"):
        try:
            vendor = Path(vendor_path).read_text().strip().lower()
            device = (Path(vendor_path).parent / "device").read_text().strip().lower()
        except OSError:
            continue
        if (vendor, device) == (BC250_VENDOR, BC250_DEVICE):
            return True
    return False


def require_bc250():
    if not is_bc250():
        raise RuntimeError("BC-250 PCI device 1002:13fe was not found; refusing SMU access")


def topology():
    cores = set()
    threads = 0
    for cpu_dir in glob.glob("/sys/devices/system/cpu/cpu[0-9]*"):
        topology_dir = Path(cpu_dir) / "topology"
        try:
            package = (topology_dir / "physical_package_id").read_text().strip()
            core = (topology_dir / "core_id").read_text().strip()
        except OSError:
            continue
        cores.add((package, core))
        threads += 1
    return len(cores), threads


class Smu:
    def __init__(self):
        self.fd = os.open(PCI_CONFIG, os.O_RDWR)
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def close(self):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)

    def read(self, reg):
        os.pwrite(self.fd, struct.pack("<I", reg), 0xB8)
        return struct.unpack("<I", os.pread(self.fd, 4, 0xBC))[0]

    def write(self, reg, value):
        os.pwrite(self.fd, struct.pack("<I", reg), 0xB8)
        os.pwrite(self.fd, struct.pack("<I", value), 0xBC)

    def send(self, message, argument, budget=5.0):
        end = time.monotonic() + budget
        status = self.read(Q3_RSP)
        while status not in DONE and time.monotonic() < end:
            time.sleep(0.002)
            status = self.read(Q3_RSP)
        if status not in DONE:
            raise RuntimeError("mailbox busy before send; aborting without a write")

        self.write(Q3_RSP, 0)
        self.write(Q3_ARG, argument)
        self.write(Q3_ARG + 4, 0)
        self.write(Q3_CMD, message)
        end = time.monotonic() + budget
        while time.monotonic() < end:
            status = self.read(Q3_RSP)
            if status in DONE:
                return status
            time.sleep(0.002)
        raise RuntimeError("mailbox timeout; abort and do not retry before a cold boot")


def read_or_apply_mask():
    smu = Smu()
    try:
        before = smu.read(MASK_REG)
        print("core presence mask: 0x%08X" % before)
        if before == 0x000000FF:
            print("core presence mask is already 0xff")
            return False

        status = smu.send(MSG_WRITE_FF, MASK_REG)
        if status != 0x01:
            raise RuntimeError("Q3 0x98 returned 0x%02X" % status)
        time.sleep(0.2)
        after = smu.read(MASK_REG)
        print("after write        : 0x%08X" % after)
        if after != 0x000000FF:
            raise RuntimeError("core presence mask did not change to 0xff")
        return True
    finally:
        smu.close()


def clear_pending():
    try:
        PENDING.unlink()
    except FileNotFoundError:
        pass


def current_boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def pending_boot_id():
    try:
        return PENDING.read_text(encoding="ascii").split()[0]
    except FileNotFoundError:
        return ""


def pending_kind():
    try:
        fields = PENDING.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return ""
    return fields[1] if len(fields) > 1 else "automatic"


def write_pending(kind):
    if kind not in ("manual", "automatic"):
        raise ValueError("invalid core-unlock attempt kind")
    STATE_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    with PENDING.open("w", encoding="ascii") as marker:
        marker.write("%s %s\n" % (current_boot_id(), kind))
        marker.flush()
        os.fsync(marker.fileno())
    directory = os.open(STATE_DIR, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def status():
    cores, threads = topology()
    detected = is_bc250()
    state = "unlocked" if cores == 8 else "locked" if cores == 6 else "unexpected"
    print("BC-250 PCI identity: %s" % ("detected" if detected else "not found"))
    print("CPU topology: %d cores / %d threads (%s)" % (cores, threads, state))
    print("unlock attempt/reboot guard: %s" % (pending_kind() or "clear"))
    return 0 if detected and cores in (6, 8) else 1


def apply():
    with OperationLock():
        require_bc250()
        cores, threads = topology()
        if cores >= 8:
            clear_pending()
            print(
                "CPU topology: %d cores / %d threads; already unlocked"
                % (cores, threads)
            )
            return 0
        if cores != 6:
            raise RuntimeError(
                "unexpected CPU topology (%d cores / %d threads); refusing SMU write"
                % (cores, threads)
            )
        attempted_boot = pending_boot_id()
        if attempted_boot == current_boot_id():
            raise RuntimeError(
                "an unlock was already attempted this boot; cold boot before retrying"
            )
        clear_pending()
        write_pending("manual")
        read_or_apply_mask()
        print("reboot required for AGESA to enumerate all eight cores")
        return 0


def boot():
    with OperationLock():
        require_bc250()
        cores, threads = topology()
        if cores >= 8:
            clear_pending()
            print("CPU topology: %d cores / %d threads; unlock active" % (cores, threads))
            return 0
        if cores != 6:
            raise RuntimeError(
                "unexpected CPU topology (%d cores / %d threads); refusing SMU write"
                % (cores, threads)
            )
        if PENDING.exists():
            raise RuntimeError(
                "previous automatic attempt did not expose eight cores; "
                "reboot-loop guard is active (run 'cpu-unlock test' to retry)"
            )

        # Persist the guard before the dangerous operation. Any SMU failure,
        # process crash, or failed warm reboot therefore blocks boot retries.
        write_pending("automatic")
        read_or_apply_mask()
        print("requesting one warm reboot so AGESA can enumerate all eight cores")
        subprocess.run(["/usr/bin/systemctl", "--no-block", "reboot"], check=True)
        return 0


def verify_unlocked():
    with OperationLock():
        require_bc250()
        cores, threads = topology()
        if cores != 8:
            raise RuntimeError(
                "current boot has %d cores / %d threads, not 8 cores; "
                "run 'cpu-unlock test', reboot, and validate before enabling persistence"
                % (cores, threads)
            )
        clear_pending()
        print("CPU topology: %d cores / %d threads; persistence can be enabled" % (cores, threads))
        return 0


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "status":
        return status()
    if os.geteuid() != 0:
        raise RuntimeError("root is required for raw PCI configuration access")
    if command == "apply":
        return apply()
    if command == "boot":
        return boot()
    if command == "verify-unlocked":
        return verify_unlocked()
    raise RuntimeError("usage: bc250-unlock-cores {status|apply|boot|verify-unlocked}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit("bc250 core unlock: %s" % error)
