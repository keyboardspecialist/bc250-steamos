import threading
import time
from typing import Optional

from .transport import Bc250PciTransport


class Bc250Mailbox:
    SMU_RETURN_OK = 0x01
    SMU_RETURN_FAILED = 0xFF
    SMU_RETURN_UNKNOWN_CMD = 0xFE
    SMU_RETURN_REJECTED_PREREQ = 0xFD
    SMU_RETURN_REJECTED_BUSY = 0xFC

    def __init__(
        self,
        transport: Bc250PciTransport,
        cmd_addr: int,
        rsp_addr: int,
        arg_addr: int,
        timeout: float = 5.0,
        lock: Optional[threading.Lock] = None,
    ) -> None:
        self._transport = transport
        self._cmd_addr = cmd_addr
        self._rsp_addr = rsp_addr
        self._arg_addr = arg_addr
        self._timeout = timeout
        self._lock = lock or threading.Lock()

    def send(self, msg_id: int, arg: int = 0, arg_high: Optional[int] = None) -> int:
        with self._lock:
            self._transport.write_smu_reg(self._rsp_addr, 0)
            self._transport.write_smu_reg(self._arg_addr, arg)
            self._transport.write_smu_reg(
                self._arg_addr + 4, 0 if arg_high is None else arg_high
            )
            self._transport.write_smu_reg(self._cmd_addr, msg_id)
            return self._wait_done(msg_id)

    def read_arg(self) -> int:
        with self._lock:
            return self._transport.read_smu_reg(self._arg_addr)

    def read_arg_high(self) -> int:
        with self._lock:
            return self._transport.read_smu_reg(self._arg_addr + 4)

    def _wait_done(self, msg_id: int) -> int:
        done_statuses = {
            self.SMU_RETURN_OK,
            self.SMU_RETURN_FAILED,
            self.SMU_RETURN_UNKNOWN_CMD,
            self.SMU_RETURN_REJECTED_PREREQ,
            self.SMU_RETURN_REJECTED_BUSY,
        }
        deadline = time.monotonic() + self._timeout
        last_status = 0
        while time.monotonic() < deadline:
            last_status = self._transport.read_smu_reg(self._rsp_addr)
            if last_status in done_statuses:
                return last_status
            time.sleep(0.001)
        raise RuntimeError(
            f"smu timed out after {self._timeout:g}s for msg 0x{msg_id:02X} "
            f"(last status 0x{last_status:02X})"
        )
