import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import AsyncMock, patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bc250_control_service.authorization import PolkitAuthorizer
from bc250_control_service.errors import AccessDenied


class RecordingAuthorizer(PolkitAuthorizer):
    def __init__(self, denied=False):
        super().__init__()
        self.denied = denied
        self.checks = []

    async def _check(self, sender):
        self.checks.append(sender)
        if self.denied:
            raise AccessDenied("denied")


class PolkitAuthorizerTests(unittest.IsolatedAsyncioTestCase):
    async def test_reads_and_cec_never_run_pkcheck(self):
        authorizer = RecordingAuthorizer()
        await authorizer.authorize(":1.20", 1000, "audit:7", "read")
        await authorizer.authorize(":1.20", 1000, "audit:7", "cec")
        self.assertEqual(authorizer.checks, [])

    async def test_privileged_grant_is_cached_for_login_session(self):
        authorizer = RecordingAuthorizer()
        await authorizer.authorize(":1.20", 1000, "audit:7", "cu")
        await authorizer.authorize(":1.20", 1000, "audit:7", "gpu")
        await authorizer.authorize(":1.20", 1000, "audit:7", "cpu")
        self.assertEqual(authorizer.checks, [":1.20"])

    async def test_grant_is_reused_across_busctl_senders_in_same_session(self):
        authorizer = RecordingAuthorizer()
        await authorizer.authorize(":1.20", 1000, "audit:7", "gpu")
        authorizer.forget_sender(":1.20")
        await authorizer.authorize(":1.21", 1000, "audit:7", "cpu")
        self.assertEqual(authorizer.checks, [":1.20"])

    async def test_grant_is_not_reused_across_login_sessions(self):
        authorizer = RecordingAuthorizer()
        await authorizer.authorize(":1.20", 1000, "audit:7", "gpu")
        await authorizer.authorize(":1.21", 1000, "audit:8", "gpu")
        self.assertEqual(authorizer.checks, [":1.20", ":1.21"])

    async def test_denial_is_not_cached(self):
        authorizer = RecordingAuthorizer(denied=True)
        with self.assertRaises(AccessDenied):
            await authorizer.authorize(":1.20", 1000, "audit:7", "cpu")
        with self.assertRaises(AccessDenied):
            await authorizer.authorize(":1.20", 1000, "audit:7", "cpu")
        self.assertEqual(authorizer.checks, [":1.20", ":1.20"])

    async def test_non_unique_sender_is_rejected(self):
        authorizer = RecordingAuthorizer()
        with self.assertRaises(AccessDenied):
            await authorizer.authorize("named.sender", 1000, "audit:7", "gpu")

    async def test_pkcheck_uses_system_bus_name_subject(self):
        process = type("Process", (), {})()
        process.returncode = 0
        process.communicate = AsyncMock(return_value=(b"", b""))
        create_process = AsyncMock(return_value=process)
        authorizer = PolkitAuthorizer(timeout=1)
        with patch(
            "bc250_control_service.authorization.asyncio.create_subprocess_exec",
            create_process,
        ):
            await authorizer.authorize(":1.20", 1000, "audit:7", "cpu")
        arguments = create_process.await_args.args
        self.assertEqual(arguments[0], "/usr/bin/pkcheck")
        self.assertEqual(
            arguments[1:7],
            (
                "--action-id",
                authorizer.action_id,
                "--system-bus-name",
                ":1.20",
                "--allow-user-interaction",
            ),
        )

    def test_policy_declares_authorizer_action(self):
        policy = Path(__file__).resolve().parents[1] / (
            "io.github.keyboardspecialist.bc250-control.policy"
        )
        action = ET.parse(str(policy)).getroot().find("action")
        self.assertIsNotNone(action)
        self.assertEqual(action.attrib["id"], PolkitAuthorizer().action_id)
