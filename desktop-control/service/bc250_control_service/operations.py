import asyncio
import time
import uuid
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Dict, Optional

from .errors import AccessDenied, OperationNotFound, ServiceError


Job = Callable[[], Awaitable[Any]]


@dataclass
class Operation:
    operation_id: str
    owner_uid: int
    method: str
    created_at: float
    status: str = "queued"
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    result: Any = None
    error: Optional[str] = None
    task: Optional["asyncio.Task[Any]"] = None

    def as_dict(self) -> Dict[str, Any]:
        value = {
            "operationId": self.operation_id,
            "method": self.method,
            "status": self.status,
            "createdAt": self.created_at,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
        }
        if self.status == "succeeded" and self.result is not None:
            value["result"] = self.result
        if self.error is not None:
            value["error"] = self.error
        return value


class OperationManager:
    """Owns mutation tasks independently of the requesting D-Bus connection."""

    def __init__(
        self,
        history_limit: int = 256,
        active_limit: int = 16,
        owner_active_limit: int = 4,
    ) -> None:
        self._history_limit = history_limit
        self._active_limit = active_limit
        self._owner_active_limit = owner_active_limit
        self._operations: Dict[str, Operation] = {}
        self._mutation_lock = asyncio.Lock()

    def submit(self, owner_uid: int, method: str, job: Job) -> str:
        self._prune()
        active = sum(
            operation.task is not None and not operation.task.done()
            for operation in self._operations.values()
        )
        owner_active = sum(
            operation.owner_uid == owner_uid
            and operation.task is not None
            and not operation.task.done()
            for operation in self._operations.values()
        )
        if owner_active >= self._owner_active_limit:
            raise ServiceError("Too many hardware operations are queued for this user.")
        if active >= self._active_limit:
            raise ServiceError("Too many hardware operations are already queued.")
        operation_id = uuid.uuid4().hex
        operation = Operation(operation_id, owner_uid, method, time.time())
        self._operations[operation_id] = operation
        operation.task = asyncio.get_running_loop().create_task(
            self._run(operation, job)
        )
        return operation_id

    async def _run(self, operation: Operation, job: Job) -> None:
        try:
            async with self._mutation_lock:
                operation.status = "running"
                operation.started_at = time.time()
                operation.result = await job()
                operation.status = "succeeded"
        except asyncio.CancelledError:
            operation.status = "cancelled"
        except Exception as error:
            operation.status = "failed"
            operation.error = str(error) or error.__class__.__name__
        finally:
            operation.finished_at = time.time()

    def get(self, operation_id: str, owner_uid: int) -> Dict[str, Any]:
        operation = self._lookup(operation_id)
        if operation.owner_uid != owner_uid:
            raise AccessDenied("The operation belongs to another user.")
        return operation.as_dict()

    def cancel(self, operation_id: str, owner_uid: int) -> bool:
        operation = self._lookup(operation_id)
        if operation.owner_uid != owner_uid:
            raise AccessDenied("The operation belongs to another user.")
        if operation.task is None or operation.task.done():
            return False
        operation.task.cancel()
        return True

    def _lookup(self, operation_id: str) -> Operation:
        if not isinstance(operation_id, str) or len(operation_id) != 32:
            raise OperationNotFound("Operation not found.")
        try:
            int(operation_id, 16)
            return self._operations[operation_id]
        except (KeyError, ValueError):
            raise OperationNotFound("Operation not found.")

    def _prune(self) -> None:
        excess = len(self._operations) - self._history_limit + 1
        if excess <= 0:
            return
        completed = [
            operation
            for operation in self._operations.values()
            if operation.task is not None and operation.task.done()
        ]
        completed.sort(key=lambda operation: operation.created_at)
        for operation in completed[:excess]:
            del self._operations[operation.operation_id]

    async def close(self) -> None:
        tasks = [
            operation.task
            for operation in self._operations.values()
            if operation.task is not None and not operation.task.done()
        ]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
