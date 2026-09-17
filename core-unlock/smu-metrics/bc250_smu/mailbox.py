import threading
import time
from typing import Optional

from .errors import SmuTimeout
from .transport import Bc250PciTransport


class Bc250Mailbox:
    """One mailbox (cmd/rsp/arg register triple) with a thread lock."""

    SMU_RETURN_OK = 0x01
    SMU_RETURN_FAILED = 0xFF
    SMU_RETURN_UNKNOWN_CMD = 0xFE
    SMU_RETURN_REJECTED_PREREQ = 0xFD
    SMU_RETURN_REJECTED_BUSY = 0xFC
    DONE = {SMU_RETURN_OK, SMU_RETURN_FAILED, SMU_RETURN_UNKNOWN_CMD, SMU_RETURN_REJECTED_PREREQ, SMU_RETURN_REJECTED_BUSY}

    def __init__(self, transport: Bc250PciTransport, queue: int, cmd_addr: int, rsp_addr: int, arg_addr: int, timeout: float = 5.0, lock: Optional[threading.Lock] = None) -> None:
        self._transport = transport
        self._queue = queue
        self._cmd_addr = cmd_addr
        self._rsp_addr = rsp_addr
        self._arg_addr = arg_addr
        self._timeout = timeout
        self._lock = lock or threading.Lock()

    def send(self, msg_id: int, args=()):
        """Send msg_id with up to 6 arg dwords; returns (status, arg0)."""
        with self._lock:
            self._wait_idle(msg_id)
            self._transport.write_smu_reg(self._rsp_addr, 0)
            for i in range(6):
                self._transport.write_smu_reg(self._arg_addr + 4 * i, args[i] if i < len(args) else 0)
            self._transport.write_smu_reg(self._cmd_addr, msg_id)
            return self._wait_done(msg_id)

    def _wait_idle(self, msg_id):
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            if self._transport.read_smu_reg(self._rsp_addr) in self.DONE:
                return
            time.sleep(0.001)
        raise SmuTimeout(self._queue, msg_id)

    def read_arg(self) -> int:
        with self._lock:
            return self._transport.read_smu_reg(self._arg_addr)

    def read_arg_high(self) -> int:
        with self._lock:
            return self._transport.read_smu_reg(self._arg_addr + 4)

    def _wait_done(self, msg_id):
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            status = self._transport.read_smu_reg(self._rsp_addr)
            if status in self.DONE:
                return status, self._transport.read_smu_reg(self._arg_addr)
            time.sleep(0.001)
        raise SmuTimeout(self._queue, msg_id)
