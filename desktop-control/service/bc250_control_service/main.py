import asyncio
import logging
import os

from dbus_next import BusType, RequestNameReply
from dbus_next.aio import MessageBus

from bc250_control import ToolkitBackend

from .authorization import PolkitAuthorizer
from .control import ControlService
from .dbus_adapter import BUS_NAME, DbusAdapter, DbusIdentityResolver


async def run() -> None:
    if os.geteuid() != 0:
        raise RuntimeError("BC-250 Control must run as root.")
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    resolver = DbusIdentityResolver(bus)
    authorizer = PolkitAuthorizer()
    control = ControlService(ToolkitBackend, resolver, authorizer)
    def sender_disconnected(sender: str) -> None:
        resolver.forget_sender(sender)
        authorizer.forget_sender(sender)

    adapter = DbusAdapter(bus, control, sender_disconnected)
    await adapter.install()
    reply = await bus.request_name(BUS_NAME)
    if reply not in (RequestNameReply.PRIMARY_OWNER, RequestNameReply.ALREADY_OWNER):
        raise RuntimeError("Could not acquire " + BUS_NAME)
    logging.info("BC-250 Control system service started")
    try:
        await bus.wait_for_disconnect()
    finally:
        await control.close()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    asyncio.run(run())
