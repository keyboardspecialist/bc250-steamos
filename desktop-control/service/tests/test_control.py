import asyncio
import json
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bc250_control_service.control import Caller, ControlService
from bc250_control_service.errors import AccessDenied, InvalidArguments


class FakeResolver:
    async def resolve(self, sender):
        uid = 1000 if sender != ":1.2" else 1001
        return Caller(
            sender,
            uid,
            2000 + uid,
            "audit:" + str(uid),
            "user" + str(uid),
            Path("/home/user" + str(uid)),
        )


class FakeAuthorizer:
    def __init__(self):
        self.calls = []

    async def authorize(self, sender, uid, session, category):
        self.calls.append((sender, uid, session, category))


class FakeBackend:
    active = 0
    maximum_active = 0

    def __init__(self, user, home):
        self.user = user
        self.home = home
        self.release = None
        self.calls = []

    async def get_snapshot(self):
        return {"user": self.user, "ok": True}

    async def get_telemetry(self):
        return {"cpuClock": 3200}

    async def get_cpu_unlock_status(self):
        return {"schemaVersion": 1, "topologyState": "locked"}

    async def _mutation(self, name, *args):
        self.calls.append((name, args))
        FakeBackend.active += 1
        FakeBackend.maximum_active = max(
            FakeBackend.maximum_active, FakeBackend.active
        )
        try:
            if self.release is not None:
                await self.release.wait()
            else:
                await asyncio.sleep(0.01)
        finally:
            FakeBackend.active -= 1

    async def set_cu_wgp(self, *args):
        await self._mutation("set_cu_wgp", *args)

    async def set_gpu_frequency(self, *args):
        await self._mutation("set_gpu_frequency", *args)

    async def set_load_target(self, *args):
        await self._mutation("set_load_target", *args)

    async def set_custom_load_target(self, *args):
        await self._mutation("set_custom_load_target", *args)

    async def set_ramp(self, *args):
        await self._mutation("set_ramp", *args)

    async def cpu_oc_action(self, *args):
        await self._mutation("cpu_oc_action", *args)

    async def cpu_unlock_action(self, *args):
        await self._mutation("cpu_unlock_action", *args)
        return {"action": args[0], "nextStep": "none"}

    async def set_cpu_mitigations(self, *args):
        await self._mutation("set_cpu_mitigations", *args)

    async def set_uma_size(self, *args):
        await self._mutation("set_uma_size", *args)

    async def set_ttm_pages(self, *args):
        await self._mutation("set_ttm_pages", *args)

    async def remove_ttm_override(self, *args):
        await self._mutation("remove_ttm_override", *args)

    async def cec_action(self, *args):
        await self._mutation("cec_action", *args)

    async def set_cec_toggle(self, *args):
        await self._mutation("set_cec_toggle", *args)

    async def set_cec_name(self, *args):
        await self._mutation("set_cec_name", *args)


class ControlServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        FakeBackend.active = 0
        FakeBackend.maximum_active = 0
        self.backends = []
        self.authorizer = FakeAuthorizer()

        def factory(user, home):
            backend = FakeBackend(user, home)
            self.backends.append(backend)
            return backend

        self.service = ControlService(factory, FakeResolver(), self.authorizer)

    async def asyncTearDown(self):
        await self.service.close()

    async def wait_for_status(self, sender, operation_id, status):
        for _ in range(100):
            value = json.loads(
                await self.service.get_operation(sender, operation_id)
            )
            if value["status"] == status:
                return value
            await asyncio.sleep(0.005)
        self.fail("operation did not reach " + status)

    async def test_reads_return_compact_json_without_authorization(self):
        value = await self.service.get_snapshot(":1.1")
        self.assertEqual(value, '{"user":"user1000","ok":true}')
        unlock = await self.service.get_cpu_unlock_status(":1.1")
        self.assertEqual(
            unlock, '{"schemaVersion":1,"topologyState":"locked"}'
        )
        self.assertEqual(self.authorizer.calls, [])

    async def test_privileged_mutation_is_authorized_and_pollable(self):
        operation_id = await self.service.set_cu_wgp(":1.1", 0, 1, 4, True)
        operation = await self.wait_for_status(":1.1", operation_id, "succeeded")
        self.assertEqual(operation["method"], "SetCuWgp")
        self.assertEqual(
            self.authorizer.calls, [(":1.1", 1000, "audit:1000", "cu")]
        )
        self.assertEqual(
            self.backends[0].calls, [("set_cu_wgp", (0, 1, 4, True))]
        )

    async def test_cec_mutation_uses_non_prompting_category(self):
        operation_id = await self.service.cec_action(":1.1", "tv-on")
        await self.wait_for_status(":1.1", operation_id, "succeeded")
        self.assertEqual(
            self.authorizer.calls, [(":1.1", 1000, "audit:1000", "cec")]
        )

    async def test_mutations_from_different_users_are_serialized(self):
        first = await self.service.set_ramp(":1.1", 500)
        second = await self.service.set_ramp(":1.2", 600)
        await self.wait_for_status(":1.1", first, "succeeded")
        await self.wait_for_status(":1.2", second, "succeeded")
        self.assertEqual(FakeBackend.maximum_active, 1)

    async def test_cpu_job_survives_request_completion_and_can_be_cancelled(self):
        operation_id = await self.service.cpu_oc_action(
            ":1.1", "detect", 4000, 1275, 90
        )
        self.backends[0].release = asyncio.Event()
        await self.wait_for_status(":1.1", operation_id, "running")
        self.assertTrue(await self.service.cancel_operation(":1.1", operation_id))
        await self.wait_for_status(":1.1", operation_id, "cancelled")

    async def test_cpu_unlock_operation_is_protected_and_returns_next_step(self):
        operation_id = await self.service.cpu_unlock_action(":1.1", "enable")
        operation = await self.wait_for_status(":1.1", operation_id, "succeeded")

        self.assertFalse(operation["cancellable"])
        self.assertFalse(await self.service.cancel_operation(":1.1", operation_id))
        self.assertEqual(operation["result"], {"action": "enable", "nextStep": "none"})
        self.assertEqual(
            self.authorizer.calls, [(":1.1", 1000, "audit:1000", "cpu")]
        )
        self.assertEqual(
            self.backends[0].calls, [("cpu_unlock_action", ("enable",))]
        )

    async def test_cpu_unlock_accepts_efi_enable_without_changing_dbus_contract(self):
        operation_id = await self.service.cpu_unlock_action(":1.1", "efi-enable")
        operation = await self.wait_for_status(":1.1", operation_id, "succeeded")

        self.assertEqual(
            operation["result"], {"action": "efi-enable", "nextStep": "none"}
        )
        self.assertEqual(
            self.backends[0].calls, [("cpu_unlock_action", ("efi-enable",))]
        )

    async def test_cpu_mitigations_are_authorized_and_non_cancellable(self):
        operation_id = await self.service.set_cpu_mitigations(":1.1", False)
        operation = await self.wait_for_status(":1.1", operation_id, "succeeded")

        self.assertFalse(operation["cancellable"])
        self.assertEqual(operation["method"], "SetCpuMitigations")
        self.assertEqual(
            self.authorizer.calls, [(":1.1", 1000, "audit:1000", "cpu")]
        )
        self.assertEqual(
            self.backends[0].calls, [("set_cpu_mitigations", (False,))]
        )

    async def test_ram_mutations_are_authorized_and_non_cancellable(self):
        operation_id = await self.service.set_uma_size(":1.1", 512)
        operation = await self.wait_for_status(":1.1", operation_id, "succeeded")
        self.assertFalse(operation["cancellable"])
        self.assertEqual(operation["method"], "SetUmaSize")
        self.assertEqual(self.authorizer.calls, [(":1.1", 1000, "audit:1000", "ram")])
        self.assertEqual(self.backends[0].calls, [("set_uma_size", (512,))])

    async def test_operations_are_private_to_uid_but_survive_sender_change(self):
        operation_id = await self.service.cec_action(":1.1", "mute")
        await self.wait_for_status(":9.9", operation_id, "succeeded")
        with self.assertRaises(AccessDenied):
            await self.service.get_operation(":1.2", operation_id)

    async def test_validation_happens_before_authorization_or_backend_call(self):
        with self.assertRaises(InvalidArguments):
            await self.service.set_gpu_frequency(":1.1", "pin", 0, 2200)
        with self.assertRaises(InvalidArguments):
            await self.service.set_cec_name(":1.1", 'bad"name')
        with self.assertRaises(InvalidArguments):
            await self.service.cpu_oc_action(":1.1", "detect", True, 1200, 90)
        with self.assertRaises(InvalidArguments):
            await self.service.set_cpu_mitigations(":1.1", 0)
        for action in ("", "uninstall", "test; reboot", 1):
            with self.subTest(action=action), self.assertRaises(InvalidArguments):
                await self.service.cpu_unlock_action(":1.1", action)
        for value in (255, 513, 2048, 12289, True):
            with self.subTest(uma=value), self.assertRaises(InvalidArguments):
                await self.service.set_uma_size(":1.1", value)
        for value in (65535, 3145729, True):
            with self.subTest(ttm=value), self.assertRaises(InvalidArguments):
                await self.service.set_ttm_pages(":1.1", value)
        self.assertEqual(self.authorizer.calls, [])
        self.assertEqual(self.backends, [])
