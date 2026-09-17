from typing import Dict, Optional, Tuple

from .errors import SmuError, SmuRejected
from .api_q0 import Queue0Mixin
from .api_q2 import Queue2Mixin
from .api_q3 import Queue3Mixin
from .mailbox import Bc250Mailbox
from .primitives import PrimitiveMixin
from .transport import Bc250PciTransport


# (cmd, rsp, arg) per queue.
DEFAULT_QUEUE_ADDRS: Dict[int, Tuple[int, int, int]] = {
    0: (0x03B10A08, 0x03B10A68, 0x03B10A48),
    2: (0x03B10528, 0x03B10564, 0x03B10998),
    3: (0x03B10A20, 0x03B10A80, 0x03B10A88),
}


class Bc250Smu(Queue0Mixin, Queue2Mixin, Queue3Mixin, PrimitiveMixin):
    def __init__(
        self,
        bdf: str = "0000:00:00.0",
        timeout: float = 5.0,
        queue_addrs: Optional[Dict[int, Tuple[int, int, int]]] = None,
    ) -> None:
        self._transport = Bc250PciTransport(bdf=bdf)
        self._transport.open()
        addrs = dict(DEFAULT_QUEUE_ADDRS)
        if queue_addrs:
            addrs.update(queue_addrs)
        self._queues = {
            queue: Bc250Mailbox(
                self._transport, queue, cmd, rsp, arg, timeout=timeout
            )
            for queue, (cmd, rsp, arg) in addrs.items()
        }

    def close(self) -> None:
        self._transport.close()

    def send_message(self, queue_id: int, msg_id: int, args=(), check_status=True):
        """(status, arg0) for one message; raises RuntimeError unless the
        status is OK (check_status=True)."""
        st, ret = self._get_queue(queue_id).send(msg_id, args)
        if check_status and st != Bc250Mailbox.SMU_RETURN_OK:
            raise SmuRejected(queue_id, msg_id, st)
        return st, ret

    def test_message(self, value: int) -> bool:
        """Send test message and verify the response increments the value."""
        st, ret = self.send_message(3, 0x01, [value])
        if ret != value + 1:
            raise RuntimeError(f"unexpected test response {ret}, expected {value + 1}")
        return True

    def alive(self) -> bool:
        try:
            return self.test_message(0x5EED0000)
        except SmuError:
            return False

    def _get_queue(self, queue: int) -> Bc250Mailbox:
        if queue not in self._queues:
            raise KeyError(f"queue {queue} not configured")
        return self._queues[queue]
