from .mailbox import Bc250Mailbox


class Queue3Mixin:
    """Queue 3 gated primitives opened by the Queue 2 unlock path."""

    def secure_access_enabled(self):
        st, _ = self.send_message(3, 0x2A, check_status=False)
        return st == Bc250Mailbox.SMU_RETURN_OK

    def sec_set_write_ptr(self, addr: int):
        return self.send_message(3, 0x28, [addr])

    def sec_write_through32(self, value: int):
        return self.send_message(3, 0x29, [value])

    def sec_smn_read32(self, addr: int):
        return self.send_message(3, 0x2A, [addr], check_status=False)

    def sec_set_smn_write_addr(self, addr: int):
        return self.send_message(3, 0x2B, [addr])

    def sec_smn_write32(self, value: int):
        return self.send_message(3, 0x2C, [value])
