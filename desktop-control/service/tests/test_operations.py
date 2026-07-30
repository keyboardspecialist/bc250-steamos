import asyncio
import unittest

from bc250_control_service.errors import AccessDenied, ServiceError
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

    async def test_operation_json_includes_cancellable_and_protected_cancel_is_false(self):
        manager = OperationManager()
        release = asyncio.Event()

        async def wait():
            await release.wait()

        operation_id = manager.submit(1000, "protected", wait, cancellable=False)
        await asyncio.sleep(0)
        self.assertFalse(manager.cancel(operation_id, 1000))
        self.assertFalse(manager.get(operation_id, 1000)["cancellable"])
        with self.assertRaises(AccessDenied):
            manager.cancel(operation_id, 1001)
        release.set()
        await manager.close()

    async def test_queued_cancel_reaches_cancelled_state_without_running_job(self):
        manager = OperationManager()
        release = asyncio.Event()
        ran = False

        async def blocking():
            await release.wait()

        async def queued():
            nonlocal ran
            ran = True

        first = manager.submit(1000, "first", blocking)
        await asyncio.sleep(0)
        second = manager.submit(1000, "second", queued)
        self.assertTrue(manager.cancel(second, 1000))
        await asyncio.sleep(0)

        operation = manager.get(second, 1000)
        self.assertEqual(operation["status"], "cancelled")
        self.assertFalse(ran)
        release.set()
        for _ in range(20):
            if manager.get(first, 1000)["status"] == "succeeded":
                break
            await asyncio.sleep(0)
        await manager.close()
        self.assertEqual(manager.get(first, 1000)["status"], "succeeded")


if __name__ == "__main__":
    unittest.main()
