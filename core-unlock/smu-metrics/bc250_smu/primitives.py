"""Composites built on the queue wrappers: SMU-local SRAM access + dump."""
import ctypes
import os
import struct

from .errors import SmuError, SmuRejected
from .mailbox import Bc250Mailbox

PAGE = 4096

_LIBC = None


def _libc():
    global _LIBC
    if _LIBC is None:
        _LIBC = ctypes.CDLL("libc.so.6")
        _LIBC.mmap.restype = ctypes.c_void_p
        _LIBC.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
        _LIBC.mlock.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        _LIBC.mlock.restype = ctypes.c_int
        _LIBC.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        _LIBC.munmap.restype = ctypes.c_int
    return _LIBC


def _phys_of(va):
    with open("/proc/self/pagemap", "rb") as f:
        f.seek((va // PAGE) * 8)
        e = __import__("struct").unpack("<Q", f.read(8))[0]
    return (e & ((1 << 55) - 1)) * PAGE if (e & (1 << 63)) else None


def alloc_page():
    """Mlocked 4096-byte page for transfer targets; free with free_page()."""
    va = _libc().mmap(None, PAGE, 3, 0x22, -1, 0)
    if not va or va in (-1, 2 ** 64 - 1):
        raise RuntimeError("mmap failed")
    if _libc().mlock(ctypes.c_void_p(va), PAGE) != 0:
        _libc().munmap(ctypes.c_void_p(va), PAGE)
        raise RuntimeError("mlock failed")
    phys = _phys_of(va)
    if phys is None:
        _libc().munmap(ctypes.c_void_p(va), PAGE)
        raise RuntimeError("pagemap failed")
    return va, phys


def free_page(va):
    """Release a page from alloc_page()."""
    _libc().munmap(ctypes.c_void_p(va), PAGE)


class PrimitiveMixin:
    """smu_read / smu_write32 / smu_memset32 / smn_* / window_read / dump."""

    def smu_read(self, addr: int, n: int = 1):
        """Read n 32-bit words from SMU-local addr (n <= 18)."""
        va, phys = alloc_page()
        try:
            self.transfer_engine_sram_load(addr, n)
            self.transfer_engine_smu2dram(phys >> 32, phys & 0xFFFFFFFF, n)
            return bytes(ctypes.string_at(va, n * 4))
        finally:
            free_page(va)

    def smu_write32(self, addr: int, value: int):
        """Write one 32-bit word to SMU-local addr (gated)."""
        self.sec_set_write_ptr(addr)
        self.sec_write_through32(value)

    def smu_read_bytes(self, addr: int, size: int) -> bytes:
        """read `size` bytes at smu-local addr, dword-granular."""
        out = b""
        for base in range(addr & ~3, addr + size, 4):
            w = self.smu_read(base, 1)
            lo = max(0, addr - base)
            hi = min(4, addr + size - base)
            out += w[lo:hi]
        return out

    def smu_write_bytes(self, addr: int, data: bytes):
        """Byte-granular write with one SMU store per affected dword."""
        end = addr + len(data)
        for base in range(addr & ~3, (end + 3) & ~3, 4):
            dword = bytearray(self.smu_read(base, 1))
            lo = max(addr, base)
            hi = min(end, base + 4)
            dword[lo - base:hi - base] = data[lo - addr:hi - addr]
            self.smu_write32(base, struct.unpack("<I", dword)[0])

    def smu_memset32(self, addr: int, value: int, words: int):
        """Fill `words` 32-bit words at SMU-local addr (gated)."""
        for i in range(words):
            self.smu_write32(addr + 4 * i, value)

    def smn_read32(self, addr: int):
        """32-bit SMN read via the mem64 window."""
        st, v = self.sec_smn_read32(addr)
        if st != Bc250Mailbox.SMU_RETURN_OK:
            raise SmuRejected(3, 0x2A, st)
        return v

    def smn_write32(self, addr: int, value: int):
        """32-bit SMN write via the mem64 window."""
        self.sec_set_smn_write_addr(addr)
        self.sec_smn_write32(value)

    WINDOW_BASE = 0x3030

    def window_read(self, words: int = 24576):
        """Read the factory-window SRAM range (0x3030..) in 18-word chunks."""
        return b"".join(self.smu_read(self.WINDOW_BASE + off * 4, min(18, words - off))
                       for off in range(0, words, 18))

    def dump_sram(self, path: str = "smu_dump.bin", start: int = 0, end: int = 0x40000, chunk: int = 18):
        """Full SRAM dump via smu_read chunks (like smu-dump.py)."""
        import time
        dump = bytearray()
        t0 = time.monotonic()
        for src in range(start, end, chunk * 4):
            n = min(chunk, (end - src) // 4)
            dump += self.smu_read(src, n)
        with open(path, "wb") as f:
            f.write(dump)
        print("dumped %d bytes to %s in %.1fs" % (len(dump), path, time.monotonic() - t0))
        return bytes(dump)
