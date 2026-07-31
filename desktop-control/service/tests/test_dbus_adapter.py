import asyncio
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


DESKTOP_CONTROL = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DESKTOP_CONTROL / "vendor"))
sys.path.insert(0, str(DESKTOP_CONTROL / "service"))

from dbus_next import Message, MessageType
from dbus_next.message_bus import BaseMessageBus

from bc250_control_service.dbus_adapter import (
    DbusAdapter,
    DbusIdentityResolver,
    INTERFACE,
    INTROSPECTION_XML,
    OBJECT_PATH,
)


def method_return(value):
    return Message(
        message_type=MessageType.METHOD_RETURN,
        reply_serial=1,
        signature="u",
        body=[value],
    )


class IdentityBus:
    async def call(self, message):
        if message.member == "GetConnectionUnixUser":
            return method_return(1000)
        if message.member == "GetConnectionUnixProcessID":
            return method_return(4321)
        raise AssertionError(message.member)


class HandlerBus:
    def __init__(self):
        self._user_message_handlers = []
        self._method_return_handlers = {}
        self._path_exports = {}
        self.sent = []

    def send(self, message):
        self.sent.append(message)


class FakeControl:
    def __init__(self):
        self.senders = []

    async def get_telemetry(self, sender):
        self.senders.append(sender)
        return "{}"

    async def get_cpu_unlock_status(self, sender):
        self.senders.append(sender)
        return '{"schemaVersion":1}'

    async def cpu_unlock_action(self, sender, action):
        self.senders.append((sender, action))
        return "operation"


class IdentityResolverTests(unittest.IsolatedAsyncioTestCase):
    async def test_resolves_pid_and_validated_audit_session(self):
        resolver = DbusIdentityResolver(IdentityBus())

        def read_proc(pid, name, limit):
            self.assertEqual(pid, 4321)
            if name == "status":
                return "Name:\tbusctl\nUid:\t1000\t1000\t1000\t1000\n"
            return "27\n"

        account = SimpleNamespace(pw_name="deck", pw_dir="/home/deck")
        with patch.object(
            DbusIdentityResolver, "_read_proc_file", side_effect=read_proc
        ), patch(
            "bc250_control_service.dbus_adapter.pwd.getpwuid",
            return_value=account,
        ):
            caller = await resolver.resolve(":1.20")
        self.assertEqual(caller.uid, 1000)
        self.assertEqual(caller.pid, 4321)
        self.assertEqual(caller.session, "audit:27")

    async def test_invalid_audit_session_falls_back_to_unique_sender(self):
        resolver = DbusIdentityResolver(IdentityBus())

        def read_proc(_pid, name, _limit):
            if name == "status":
                return "Uid:\t1000\t1000\t1000\t1000\n"
            return "4294967295\n"

        account = SimpleNamespace(pw_name="deck", pw_dir="/home/deck")
        with patch.object(
            DbusIdentityResolver, "_read_proc_file", side_effect=read_proc
        ), patch(
            "bc250_control_service.dbus_adapter.pwd.getpwuid",
            return_value=account,
        ):
            caller = await resolver.resolve(":1.20")
        self.assertEqual(caller.session, "sender::1.20")


class AdapterHandlerTests(unittest.IsolatedAsyncioTestCase):
    def test_cpu_unlock_dbus_signatures_are_declared(self):
        self.assertEqual(
            DbusAdapter._METHODS["GetCpuUnlockStatus"],
            ("", "s", "get_cpu_unlock_status"),
        )
        self.assertEqual(
            DbusAdapter._METHODS["CpuUnlockAction"],
            ("s", "s", "cpu_unlock_action"),
        )
        self.assertIn('<method name="GetCpuUnlockStatus">', INTROSPECTION_XML)
        self.assertIn('<method name="CpuUnlockAction">', INTROSPECTION_XML)

    def test_ram_dbus_signatures_are_declared(self):
        self.assertEqual(DbusAdapter._METHODS["SetUmaSize"], ("u", "s", "set_uma_size"))
        self.assertEqual(DbusAdapter._METHODS["SetTtmPages"], ("u", "s", "set_ttm_pages"))
        self.assertEqual(
            DbusAdapter._METHODS["RemoveTtmOverride"],
            ("", "s", "remove_ttm_override"),
        )
        self.assertIn('<method name="SetUmaSize">', INTROSPECTION_XML)
        self.assertIn('<method name="SetTtmPages">', INTROSPECTION_XML)
        self.assertIn('<method name="RemoveTtmOverride">', INTROSPECTION_XML)

    async def test_rejects_calls_above_dispatch_limit(self):
        adapter = DbusAdapter(HandlerBus(), FakeControl(), dispatch_limit=0)
        call = Message(
            path=OBJECT_PATH,
            interface=INTERFACE,
            member="GetTelemetry",
            sender=":1.20",
            serial=42,
        )

        reply = adapter.handle(call)

        self.assertEqual(reply.message_type, MessageType.ERROR)
        self.assertTrue(reply.error_name.endswith(".LimitsExceeded"))

    async def test_async_call_is_claimed_and_only_message_reply_is_sent(self):
        bus = HandlerBus()
        control = FakeControl()
        adapter = DbusAdapter(bus, control)
        bus._user_message_handlers.append(adapter.handle)
        call = Message(
            path=OBJECT_PATH,
            interface=INTERFACE,
            member="GetTelemetry",
            sender=":1.20",
            serial=42,
        )

        BaseMessageBus._process_message(bus, call)
        self.assertEqual(bus.sent, [])
        await asyncio.sleep(0)
        await asyncio.sleep(0)

        self.assertEqual(control.senders, [":1.20"])
        self.assertEqual(len(bus.sent), 1)
        self.assertIs(type(bus.sent[0]), Message)
        self.assertEqual(bus.sent[0].message_type, MessageType.METHOD_RETURN)
        self.assertEqual(bus.sent[0].body, ["{}"])

    async def test_cpu_unlock_action_propagates_sender_and_argument(self):
        bus = HandlerBus()
        control = FakeControl()
        adapter = DbusAdapter(bus, control)
        call = Message(
            path=OBJECT_PATH,
            interface=INTERFACE,
            member="CpuUnlockAction",
            signature="s",
            body=["test"],
            sender=":1.21",
            serial=43,
        )

        self.assertTrue(adapter.handle(call))
        await asyncio.sleep(0)
        await asyncio.sleep(0)

        self.assertEqual(control.senders, [(":1.21", "test")])
        self.assertEqual(bus.sent[0].body, ["operation"])
