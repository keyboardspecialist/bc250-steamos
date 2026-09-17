from .errors import SmuRejected
from .mailbox import Bc250Mailbox


class Queue2Mixin:
    """Queue 2 operations required by the unlock and SRAM transfer paths."""

    def transfer_engine_smu2dram(self, dram_hi: int, dram_lo: int, words: int):
        return self.send_message(2, 0x0A, [0x14, dram_hi, dram_lo, words, 0, 0])

    def transfer_engine_sram_load(self, src: int, words: int):
        return self.send_message(2, 0x0A, [0x1F, 0, src, words])

    def transfer_engine_dram2smu(
        self, dram_hi: int, dram_lo: int, words: int, key: int
    ):
        return self.send_message(2, 0x0A, [0x23, dram_hi, dram_lo, words, 0, key])

    def q2_0x23_append(self, args):
        st, _ = self.send_message(2, 0x23, args, check_status=False)
        if st != Bc250Mailbox.SMU_RETURN_OK:
            raise SmuRejected(2, 0x23, st)
