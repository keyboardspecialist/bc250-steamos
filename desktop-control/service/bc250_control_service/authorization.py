import asyncio
import re
from typing import Dict, Set, Tuple

from .errors import AccessDenied


PRIVILEGED_CATEGORIES = {"cu", "gpu", "cpu"}
UNPRIVILEGED_CATEGORIES = {"read", "cec"}


class PolkitAuthorizer:
    """Caches grants for a UID's stable login session until service restart."""

    def __init__(
        self,
        action_id: str = "io.github.keyboardspecialist.bc250-control.modify",
        pkcheck_path: str = "/usr/bin/pkcheck",
        timeout: float = 120,
    ) -> None:
        self.action_id = action_id
        self.pkcheck_path = pkcheck_path
        self.timeout = timeout
        self._grants: Set[Tuple[int, str, str]] = set()
        self._inflight: Dict[
            str, Tuple[Tuple[int, str, str], "asyncio.Task[None]"]
        ] = {}

    async def authorize(
        self, sender: str, uid: int, session: str, category: str
    ) -> None:
        if category in UNPRIVILEGED_CATEGORIES:
            return
        if category not in PRIVILEGED_CATEGORIES:
            raise AccessDenied("Unknown authorization category.")
        if not re.fullmatch(r":[0-9]+\.[0-9]+", sender):
            raise AccessDenied("A unique system D-Bus sender is required.")

        if type(uid) is not int or uid < 0 or type(session) is not str or not session:
            raise AccessDenied("The caller session identity is invalid.")

        key = (uid, session, self.action_id)
        if key in self._grants:
            return
        inflight = self._inflight.get(sender)
        if inflight is None or inflight[0] != key:
            task = asyncio.get_running_loop().create_task(self._check(sender))
            self._inflight[sender] = (key, task)
        else:
            task = inflight[1]
        try:
            await asyncio.shield(task)
            self._grants.add(key)
        finally:
            current = self._inflight.get(sender)
            if task.done() and current is not None and current[1] is task:
                self._inflight.pop(sender, None)

    async def _check(self, sender: str) -> None:
        process = None
        try:
            process = await asyncio.create_subprocess_exec(
                self.pkcheck_path,
                "--action-id",
                self.action_id,
                "--system-bus-name",
                sender,
                "--allow-user-interaction",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _stdout, stderr = await asyncio.wait_for(
                process.communicate(), self.timeout
            )
        except asyncio.TimeoutError as error:
            if process is not None:
                process.kill()
                await process.communicate()
            raise AccessDenied("Polkit authorization timed out.") from error
        except asyncio.CancelledError:
            if process is not None and process.returncode is None:
                process.terminate()
                await process.communicate()
            raise
        except OSError as error:
            raise AccessDenied("Polkit authorization is unavailable.") from error
        if process.returncode != 0:
            detail = stderr.decode("utf-8", "replace").strip()
            if process.returncode == 1:
                detail = "Authorization was denied."
            raise AccessDenied(detail[-400:] or "Authorization failed.")

    def forget_sender(self, sender: str) -> None:
        inflight = self._inflight.pop(sender, None)
        if inflight is not None:
            inflight[1].cancel()
