import asyncio
import unittest

from bc250_control_service.errors import ServiceError
from bc250_control_service.operations import OperationManager


class OperationManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_unbounded_active_operations(self):
        manager = OperationManager(active_limit=2, owner_active_limit=2)
        release = asyncio.Event()

        async def wait():
            await release.wait()

        manager.submit(1000, "first", wait)
        manager.submit(1000, "second", wait)
        with self.assertRaisesRegex(ServiceError, "Too many"):
            manager.submit(1000, "third", wait)

        release.set()
        await manager.close()


if __name__ == "__main__":
    unittest.main()
