import fcntl
import os
import struct


class Bc250PciTransport:
    """PCI config-space SMN window of the root device. Requires root."""

    def __init__(self, bdf: str = "0000:00:00.0", use_flock: bool = True):
        self._config_path = f"/sys/bus/pci/devices/{bdf}/config"
        self._use_flock = use_flock
        self._fd = None

    def open(self) -> None:
        if self._fd is None:
            if os.geteuid() != 0:
                raise PermissionError("SMN window needs root")
            self._fd = os.open(self._config_path, os.O_RDWR | os.O_CLOEXEC)
            if self._use_flock:
                fcntl.flock(self._fd, fcntl.LOCK_EX)

    def close(self) -> None:
        if self._fd is not None:
            if self._use_flock:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None

    def read_smu_reg(self, reg: int) -> int:
        os.pwrite(self._fd, struct.pack("<I", reg), 0xB8)
        return struct.unpack("<I", os.pread(self._fd, 4, 0xBC))[0]

    def write_smu_reg(self, reg: int, value: int) -> None:
        os.pwrite(self._fd, struct.pack("<I", reg), 0xB8)
        os.pwrite(self._fd, struct.pack("<I", value), 0xBC)
