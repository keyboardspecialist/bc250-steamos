import asyncio
import inspect
import os
import pwd
import re
import stat
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from dbus_next import Message, MessageType

from .control import Caller
from .errors import AccessDenied, InvalidArguments, OperationNotFound, ServiceError


BUS_NAME = "io.github.keyboardspecialist.BC250Control1"
OBJECT_PATH = "/io/github/keyboardspecialist/BC250Control1"
INTERFACE = BUS_NAME
NAME_OWNER_MATCH = (
    "type='signal',sender='org.freedesktop.DBus',"
    "interface='org.freedesktop.DBus',member='NameOwnerChanged'"
)

INTROSPECTION_XML = """<node>
  <interface name="io.github.keyboardspecialist.BC250Control1">
    <method name="GetSnapshot"><arg name="json" type="s" direction="out"/></method>
    <method name="GetTelemetry"><arg name="json" type="s" direction="out"/></method>
    <method name="SetCuWgp"><arg name="se" type="y" direction="in"/><arg name="sh" type="y" direction="in"/><arg name="wgp" type="y" direction="in"/><arg name="enabled" type="b" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetGpuFrequency"><arg name="mode" type="s" direction="in"/><arg name="minimum" type="u" direction="in"/><arg name="maximum" type="u" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetLoadTarget"><arg name="preset" type="s" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetCustomLoadTarget"><arg name="minimum" type="y" direction="in"/><arg name="maximum" type="y" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetRamp"><arg name="climb_ms" type="u" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="CpuOcAction"><arg name="action" type="s" direction="in"/><arg name="frequency" type="u" direction="in"/><arg name="voltage" type="u" direction="in"/><arg name="temperature" type="u" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="CecAction"><arg name="action" type="s" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetCecToggle"><arg name="key" type="s" direction="in"/><arg name="enabled" type="b" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="SetCecName"><arg name="name" type="s" direction="in"/><arg name="operation_id" type="s" direction="out"/></method>
    <method name="GetOperation"><arg name="operation_id" type="s" direction="in"/><arg name="json" type="s" direction="out"/></method>
    <method name="CancelOperation"><arg name="operation_id" type="s" direction="in"/><arg name="cancelled" type="b" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg name="xml_data" type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
  </interface>
</node>"""


class DbusIdentityResolver:
    def __init__(self, bus: Any) -> None:
        self._bus = bus
        self._cache: Dict[str, Caller] = {}

    async def resolve(self, sender: str) -> Caller:
        cached = self._cache.get(sender)
        if cached is not None:
            return cached
        uid, pid = await asyncio.gather(
            self._connection_uint(sender, "GetConnectionUnixUser"),
            self._connection_uint(sender, "GetConnectionUnixProcessID"),
        )
        if uid < 0 or pid <= 0:
            raise AccessDenied("The D-Bus caller returned invalid credentials.")
        try:
            account = pwd.getpwuid(uid)
        except KeyError as error:
            raise AccessDenied("The D-Bus caller has no local account.") from error
        home = Path(account.pw_dir)
        if not home.is_absolute() or not account.pw_name:
            raise AccessDenied("The D-Bus caller account is invalid.")
        session = self._session_identity(pid, uid, sender)
        caller = Caller(sender, uid, pid, session, account.pw_name, home)
        self._cache[sender] = caller
        return caller

    async def _connection_uint(self, sender: str, member: str) -> int:
        reply = await self._bus.call(
            Message(
                destination="org.freedesktop.DBus",
                path="/org/freedesktop/DBus",
                interface="org.freedesktop.DBus",
                member=member,
                signature="s",
                body=[sender],
            )
        )
        if (
            reply is None
            or reply.message_type != MessageType.METHOD_RETURN
            or reply.signature != "u"
            or len(reply.body) != 1
        ):
            raise AccessDenied("Could not resolve the D-Bus caller.")
        value = reply.body[0]
        if type(value) is not int:
            raise AccessDenied("The D-Bus caller returned invalid credentials.")
        return value

    @classmethod
    def _session_identity(cls, pid: int, uid: int, sender: str) -> str:
        try:
            status = cls._read_proc_file(pid, "status", 65536)
            uid_match = re.search(
                r"^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$",
                status,
                re.MULTILINE,
            )
            if uid_match is None or any(
                int(value) != uid for value in uid_match.groups()
            ):
                return "sender:" + sender
            session_text = cls._read_proc_file(pid, "sessionid", 64).strip()
            if re.fullmatch(r"[0-9]{1,10}", session_text) is None:
                return "sender:" + sender
            session_id = int(session_text)
            # UINT32_MAX means the process has no audit login session.
            if session_id >= 0xFFFFFFFF:
                return "sender:" + sender
            return "audit:" + str(session_id)
        except (OSError, UnicodeError, ValueError):
            return "sender:" + sender

    @staticmethod
    def _read_proc_file(pid: int, name: str, limit: int) -> str:
        if type(pid) is not int or pid <= 0 or name not in ("status", "sessionid"):
            raise OSError("Invalid proc path.")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open("/proc/{}/{}".format(pid, name), flags)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise OSError("Unexpected proc file type.")
            content = os.read(descriptor, limit + 1)
            if len(content) > limit:
                raise OSError("Proc value is too large.")
            return content.decode("ascii", "strict")
        finally:
            os.close(descriptor)

    def forget_sender(self, sender: str) -> None:
        self._cache.pop(sender, None)


class DbusAdapter:
    """Raw message adapter that keeps the sender through async dispatch."""

    _METHODS: Dict[str, Tuple[str, str, str]] = {
        "GetSnapshot": ("", "s", "get_snapshot"),
        "GetTelemetry": ("", "s", "get_telemetry"),
        "SetCuWgp": ("yyyb", "s", "set_cu_wgp"),
        "SetGpuFrequency": ("suu", "s", "set_gpu_frequency"),
        "SetLoadTarget": ("s", "s", "set_load_target"),
        "SetCustomLoadTarget": ("yy", "s", "set_custom_load_target"),
        "SetRamp": ("u", "s", "set_ramp"),
        "CpuOcAction": ("suuu", "s", "cpu_oc_action"),
        "CecAction": ("s", "s", "cec_action"),
        "SetCecToggle": ("sb", "s", "set_cec_toggle"),
        "SetCecName": ("s", "s", "set_cec_name"),
        "GetOperation": ("s", "s", "get_operation"),
        "CancelOperation": ("s", "b", "cancel_operation"),
    }

    def __init__(
        self,
        bus: Any,
        control: Any,
        sender_disconnected: Optional[Callable[[str], None]] = None,
        dispatch_limit: int = 64,
        sender_dispatch_limit: int = 8,
    ) -> None:
        self._bus = bus
        self._control = control
        self._sender_disconnected = sender_disconnected
        self._dispatch_limit = dispatch_limit
        self._sender_dispatch_limit = sender_dispatch_limit
        self._tasks = set()
        self._sender_tasks: Dict[str, int] = {}

    async def install(self) -> None:
        self._bus.add_message_handler(self.handle)
        reply = await self._bus.call(
            Message(
                destination="org.freedesktop.DBus",
                path="/org/freedesktop/DBus",
                interface="org.freedesktop.DBus",
                member="AddMatch",
                signature="s",
                body=[NAME_OWNER_MATCH],
            )
        )
        if reply is None or reply.message_type != MessageType.METHOD_RETURN:
            raise RuntimeError("Could not monitor D-Bus sender lifetimes.")

    def handle(self, message: Any) -> Any:
        if (
            message.message_type == MessageType.SIGNAL
            and message.sender == "org.freedesktop.DBus"
            and message.path == "/org/freedesktop/DBus"
            and message.interface == "org.freedesktop.DBus"
            and message.member == "NameOwnerChanged"
            and message.signature == "sss"
            and len(message.body) == 3
            and message.body[0].startswith(":")
            and message.body[1]
            and not message.body[2]
            and self._sender_disconnected is not None
        ):
            self._sender_disconnected(message.body[0])
            return False
        if message.message_type != MessageType.METHOD_CALL or message.path != OBJECT_PATH:
            return False
        if (
            message.interface == "org.freedesktop.DBus.Introspectable"
            and message.member == "Introspect"
            and message.signature == ""
        ):
            return Message.new_method_return(message, "s", [INTROSPECTION_XML])
        if (
            message.interface == "org.freedesktop.DBus.Peer"
            and message.member == "Ping"
            and message.signature == ""
        ):
            return Message.new_method_return(message)
        if message.interface != INTERFACE:
            return False
        if (
            len(self._tasks) >= self._dispatch_limit
            or self._sender_tasks.get(message.sender or "", 0)
            >= self._sender_dispatch_limit
        ):
            return Message.new_error(
                message,
                "io.github.keyboardspecialist.BC250Control1.Error.LimitsExceeded",
                "Too many service requests are already in progress.",
            )

        task = asyncio.get_running_loop().create_task(self._dispatch(message))
        self._tasks.add(task)
        self._sender_tasks[message.sender] = self._sender_tasks.get(message.sender, 0) + 1
        task.add_done_callback(
            lambda completed, sender=message.sender: self._dispatch_done(completed, sender)
        )
        return True

    def _dispatch_done(self, task: "asyncio.Task[Any]", sender: str) -> None:
        self._tasks.discard(task)
        remaining = self._sender_tasks.get(sender, 1) - 1
        if remaining > 0:
            self._sender_tasks[sender] = remaining
        else:
            self._sender_tasks.pop(sender, None)

    async def _dispatch(self, message: Any) -> None:
        method = self._METHODS.get(message.member)
        if method is None:
            reply = Message.new_error(
                message,
                "org.freedesktop.DBus.Error.UnknownMethod",
                "Unknown method.",
            )
        elif message.signature != method[0]:
            reply = Message.new_error(
                message,
                "org.freedesktop.DBus.Error.InvalidArgs",
                "The method signature is invalid.",
            )
        elif not message.sender:
            reply = Message.new_error(
                message,
                "org.freedesktop.DBus.Error.AccessDenied",
                "The D-Bus sender is unavailable.",
            )
        else:
            try:
                callback = getattr(self._control, method[2])
                value = await callback(message.sender, *message.body)
                reply = Message.new_method_return(message, method[1], [value])
            except InvalidArguments as error:
                reply = self._error(message, "InvalidArgs", error)
            except AccessDenied as error:
                reply = self._error(message, "AccessDenied", error)
            except OperationNotFound as error:
                reply = self._error(message, "UnknownObject", error)
            except ServiceError as error:
                reply = self._error(message, "Failed", error)
            except Exception as error:
                reply = self._error(message, "Failed", error)
        try:
            pending = self._bus.send(reply)
            if inspect.isawaitable(pending):
                await pending
        except Exception:
            # A reply can race the caller disconnecting; the operation remains owned
            # by the service and can be polled after reconnecting.
            pass

    @staticmethod
    def _error(message: Any, name: str, error: Exception) -> Any:
        detail = str(error) or error.__class__.__name__
        return Message.new_error(
            message,
            "io.github.keyboardspecialist.BC250Control1.Error." + name,
            detail[-1200:],
        )
