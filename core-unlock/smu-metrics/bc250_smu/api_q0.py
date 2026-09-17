class Queue0Mixin:
    """Queue 0 operation required to identify the Robin firmware."""

    def _get_smu_version(self):
        return self.send_message(0, 0x02)
