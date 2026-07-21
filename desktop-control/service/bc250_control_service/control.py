import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict

from .errors import InvalidArguments
from .operations import OperationManager


@dataclass(frozen=True)
class Caller:
    sender: str
    uid: int
    pid: int
    session: str
    user: str
    home: Path


BackendFactory = Callable[[str, str], Any]


def _compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))


def _whole(value: Any, message: str) -> int:
    if type(value) is not int:
        raise InvalidArguments(message)
    return value


def _text(value: Any, message: str) -> str:
    if type(value) is not str:
        raise InvalidArguments(message)
    return value


class ControlService:
    """D-Bus-independent service API, suitable for direct unit testing."""

    def __init__(
        self,
        backend_factory: BackendFactory,
        identity_resolver: Any,
        authorizer: Any,
        operations: OperationManager = None,
    ) -> None:
        self._backend_factory = backend_factory
        self._identity_resolver = identity_resolver
        self._authorizer = authorizer
        self._operations = operations or OperationManager()
        self._backends: Dict[int, Any] = {}

    async def _caller(self, sender: str) -> Caller:
        if type(sender) is not str or not sender.startswith(":"):
            raise InvalidArguments("A D-Bus sender is required.")
        return await self._identity_resolver.resolve(sender)

    def _backend(self, caller: Caller) -> Any:
        backend = self._backends.get(caller.uid)
        if backend is None:
            backend = self._backend_factory(caller.user, str(caller.home))
            self._backends[caller.uid] = backend
        return backend

    async def get_snapshot(self, sender: str) -> str:
        caller = await self._caller(sender)
        return _compact_json(await self._backend(caller).get_snapshot())

    async def get_telemetry(self, sender: str) -> str:
        caller = await self._caller(sender)
        return _compact_json(await self._backend(caller).get_telemetry())

    async def get_operation(self, sender: str, operation_id: str) -> str:
        caller = await self._caller(sender)
        return _compact_json(self._operations.get(operation_id, caller.uid))

    async def cancel_operation(self, sender: str, operation_id: str) -> bool:
        caller = await self._caller(sender)
        return self._operations.cancel(operation_id, caller.uid)

    async def _submit(
        self, sender: str, category: str, method: str, callback: Callable[[Any], Any]
    ) -> str:
        caller = await self._caller(sender)
        await self._authorizer.authorize(
            sender, caller.uid, caller.session, category
        )
        backend = self._backend(caller)
        return self._operations.submit(
            caller.uid, method, lambda: callback(backend)
        )

    async def set_cu_wgp(
        self, sender: str, se: int, sh: int, wgp: int, enabled: bool
    ) -> str:
        _whole(se, "CU routing coordinates must be whole numbers.")
        _whole(sh, "CU routing coordinates must be whole numbers.")
        _whole(wgp, "CU routing coordinates must be whole numbers.")
        if se not in (0, 1) or sh not in (0, 1) or wgp not in range(5):
            raise InvalidArguments("CU routing coordinates are out of range.")
        if type(enabled) is not bool:
            raise InvalidArguments("CU routing state must be a boolean.")
        return await self._submit(
            sender,
            "cu",
            "SetCuWgp",
            lambda backend: backend.set_cu_wgp(se, sh, wgp, enabled),
        )

    async def set_gpu_frequency(
        self, sender: str, mode: str, minimum: int, maximum: int
    ) -> str:
        _text(mode, "Unknown GPU frequency mode.")
        _whole(minimum, "GPU frequencies must be whole numbers.")
        _whole(maximum, "GPU frequencies must be whole numbers.")
        if mode not in ("adaptive", "max", "pin", "range"):
            raise InvalidArguments("Unknown GPU frequency mode.")
        if mode == "pin" and not 100 <= maximum <= 2150:
            raise InvalidArguments("Pinned frequency must be 100-2150 MHz.")
        if mode == "range" and (
            not 0 <= minimum <= 2150
            or not 100 <= maximum <= 2150
            or (minimum != 0 and minimum > maximum)
        ):
            raise InvalidArguments("GPU frequency range is invalid.")
        return await self._submit(
            sender,
            "gpu",
            "SetGpuFrequency",
            lambda backend: backend.set_gpu_frequency(mode, minimum, maximum),
        )

    async def set_load_target(self, sender: str, preset: str) -> str:
        if _text(preset, "Unknown load-target preset.") not in ("eager", "reset"):
            raise InvalidArguments("Unknown load-target preset.")
        return await self._submit(
            sender,
            "gpu",
            "SetLoadTarget",
            lambda backend: backend.set_load_target(preset),
        )

    async def set_custom_load_target(
        self, sender: str, minimum: int, maximum: int
    ) -> str:
        _whole(minimum, "GPU load targets must be whole percentages.")
        _whole(maximum, "GPU load targets must be whole percentages.")
        if not 0 < minimum < maximum < 100:
            raise InvalidArguments(
                "Minimum GPU load must be below maximum load and both must be 1-99%."
            )
        return await self._submit(
            sender,
            "gpu",
            "SetCustomLoadTarget",
            lambda backend: backend.set_custom_load_target(minimum, maximum),
        )

    async def set_ramp(self, sender: str, climb_ms: int) -> str:
        _whole(climb_ms, "Ramp time must be a whole number from 200-5000 ms.")
        if not 200 <= climb_ms <= 5000:
            raise InvalidArguments("Ramp time must be a whole number from 200-5000 ms.")
        return await self._submit(
            sender,
            "gpu",
            "SetRamp",
            lambda backend: backend.set_ramp(climb_ms),
        )

    async def cpu_oc_action(
        self,
        sender: str,
        action: str,
        frequency: int,
        voltage: int,
        temperature: int,
    ) -> str:
        if _text(action, "Unknown CPU overclock action.") not in (
            "detect",
            "apply",
            "enable",
            "off",
        ):
            raise InvalidArguments("Unknown CPU overclock action.")
        for value in (frequency, voltage, temperature):
            _whole(value, "CPU tuning values must be whole numbers.")
        if action == "detect":
            if not 3500 <= frequency <= 4500:
                raise InvalidArguments("CPU target must be between 3500 and 4500 MHz.")
            if not 950 <= voltage <= 1325:
                raise InvalidArguments("CPU VID limit must be between 950 and 1325 mV.")
            if not 50 <= temperature <= 100:
                raise InvalidArguments(
                    "CPU temperature limit must be between 50 and 100 C."
                )
        return await self._submit(
            sender,
            "cpu",
            "CpuOcAction",
            lambda backend: backend.cpu_oc_action(
                action, frequency, voltage, temperature
            ),
        )

    async def cec_action(self, sender: str, action: str) -> str:
        allowed = (
            "tv-on",
            "tv-off",
            "amp-on",
            "amp-off",
            "switch",
            "release",
            "vol-up",
            "vol-down",
            "mute",
        )
        if _text(action, "Unknown CEC action.") not in allowed:
            raise InvalidArguments("Unknown CEC action.")
        return await self._submit(
            sender, "cec", "CecAction", lambda backend: backend.cec_action(action)
        )

    async def set_cec_toggle(
        self, sender: str, key: str, enabled: bool
    ) -> str:
        if _text(key, "Unknown CEC toggle.") not in (
            "wake-tv",
            "suspend-tv",
            "allow-standby",
            "uinput",
        ):
            raise InvalidArguments("Unknown CEC toggle.")
        if type(enabled) is not bool:
            raise InvalidArguments("CEC toggle state must be a boolean.")
        return await self._submit(
            sender,
            "cec",
            "SetCecToggle",
            lambda backend: backend.set_cec_toggle(key, enabled),
        )

    async def set_cec_name(self, sender: str, name: str) -> str:
        _text(name, "CEC broadcast name must be text.")
        try:
            byte_length = len(name.encode("utf-8"))
        except UnicodeEncodeError as error:
            raise InvalidArguments(
                "CEC broadcast name contains invalid text."
            ) from error
        if not name.strip() or byte_length > 14:
            raise InvalidArguments("CEC broadcast name must be 1-14 bytes.")
        if not name.isprintable() or '"' in name or "\\" in name:
            raise InvalidArguments(
                "CEC broadcast name cannot contain control characters, quotes, or backslashes."
            )
        return await self._submit(
            sender,
            "cec",
            "SetCecName",
            lambda backend: backend.set_cec_name(name),
        )

    async def close(self) -> None:
        await self._operations.close()
