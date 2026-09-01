from __future__ import annotations

import asyncio
import fcntl
import glob
import hashlib
import json
import math
import os
import pwd
import re
import shlex
import signal
import stat
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator, Optional, Union

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - used by older SteamOS Python
    import tomli as tomllib


BASH = "/usr/bin/bash"
BUSCTL = "/usr/bin/busctl"
ENV = "/usr/bin/env"
EFIBOOTMGR = "/usr/bin/efibootmgr"
FINDMNT = "/usr/bin/findmnt"
LSBLK = "/usr/bin/lsblk"
RUNUSER = "/usr/bin/runuser"
PYTHON3 = "/usr/bin/python3"
SYSTEMCTL = "/usr/bin/systemctl"
GPU_CONFIG_PATH = Path("/etc/cyan-skillfish-governor-smu/config.toml")
GPU_STATE_PATH = Path("/var/lib/bc250-control/governor/freq-state")
CPU_HELPER_PATH = Path("/var/lib/bc250-control/helper/bc250-power.sh")
HDMI_AUDIO_HELPER_PATH = Path(
    "/var/lib/bc250-control/helper/hdmi-ac3/hdmi-ac3.sh"
)
HDMI_AUDIO_REQUIRED_PATHS = (
    HDMI_AUDIO_HELPER_PATH,
    HDMI_AUDIO_HELPER_PATH.parent.parent / "bc250-update-persistence.sh",
    HDMI_AUDIO_HELPER_PATH.parent.parent / ".decky-helper-manifest",
)
CPU_HELPER_REQUIRED_PATHS = (
    CPU_HELPER_PATH,
    CPU_HELPER_PATH.parent / "bc250-storage.sh",
    CPU_HELPER_PATH.parent / "bc250-update-persistence.sh",
    CPU_HELPER_PATH.parent / "smu-oc-patches/bc250_detect.py",
    CPU_HELPER_PATH.parent / "smu-oc-patches/stress_helper.py",
    CPU_HELPER_PATH.parent / "smu-oc-patches/transport.py",
    CPU_HELPER_PATH.parent / ".decky-helper-manifest",
)
RAM_HELPER_PATH = Path("/var/lib/bc250-control/desktop/bc250-ram-split.sh")
CPU_STATE_DIR = Path("/var/lib/bc250-control/smu-oc")
CPU_UNLOCK_PAYLOAD_PATH = Path("/var/lib/bc250-control/desktop")
CPU_UNLOCK_HELPER_PATH = Path(
    "/var/lib/bc250-control/helper/bc250-unlock-cores"
)
CPU_UNLOCK_LICENSE_PATH = Path(
    "/var/lib/bc250-control/licenses/bc250-core-unlock-LICENSE"
)
CPU_UNLOCK_STATE_PATH = Path(
    "/var/lib/bc250-control/core-unlock/reboot-pending"
)
CPU_UNLOCK_UNIT_PATH = Path("/etc/systemd/system/bc250-core-unlock.service")
CPU_UNLOCK_PERSISTENCE_PATH = Path(
    "/etc/atomic-update.conf.d/bc250-power.conf"
)
CPU_UNLOCK_EFI_MASTER_PATH = Path(
    "/var/lib/bc250-control/core-unlock/bc250-core-unlock.efi"
)
CPU_UNLOCK_EFI_STATE_PATH = Path(
    "/var/lib/bc250-control/core-unlock/efi-state"
)
CPU_UNLOCK_EFI_BOOTNUM_PATH = Path(
    "/var/lib/bc250-control/core-unlock/efi-bootnum"
)
CPU_UNLOCK_EFI_IMAGE_HASH_PATH = Path(
    "/var/lib/bc250-control/core-unlock/efi-image.sha256"
)
CPU_UNLOCK_EFI_RECOVERY_PATH = Path(
    "/var/lib/bc250-control/core-unlock/efi-recovery"
)
CPU_UNLOCK_EFI_ESP_IMAGE_PATH = Path("/efi/EFI/bc250/bc250-core-unlock.efi")
CPU_UNLOCK_EFI_ESP_ROOT_PATH = Path("/efi")
CPU_UNLOCK_STEAMOS_EFI_PARTSET_PATH = Path("/dev/disk/by-partsets/self/efi")
CPU_UNLOCK_EFI_GUARD_PATH = Path(
    "/sys/firmware/efi/efivars/"
    "BC250CoreUnlockAttempt-4f6f6f13-1ec2-4f26-a250-bc250c0e77ff"
)
CPU_UNLOCK_EFIVARS_DIR_PATH = Path("/sys/firmware/efi/efivars")
CPU_UNLOCK_EFI_LICENSE_PATH = Path(
    "/var/lib/bc250-control/licenses/bc250-core-unlock-efi-LICENSE"
)
CPU_UNLOCK_EFI_HEADER_LICENSE_PATH = Path(
    "/var/lib/bc250-control/licenses/yoppeh-efi-LICENSE"
)
CPU_SYSFS_PATH = Path("/sys/devices/system/cpu")
PCI_SYSFS_PATH = Path("/sys/bus/pci/devices")
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
CPU_UNLOCK_PAYLOAD_FILES = (
    Path("bc250-power.sh"),
    Path("bc250-storage.sh"),
    Path("bc250-update-persistence.sh"),
    Path("core-unlock/bc250-unlock-cores.py"),
    Path("core-unlock/bc250-unlock-cores-efi.c"),
    Path("core-unlock/EFI-LICENSE"),
    Path("core-unlock/EFI-HEADERS-LICENSE"),
    Path("core-unlock/LICENSE"),
)
ROOT_UMR_PATH = Path("/var/lib/bc250-control/umr/bin/umr")
ROOT_UMR_DATABASE_PATH = Path("/var/lib/bc250-control/umr/share/umr/database")
MIGRATED_UMR_DATABASE_PATH = Path(
    "/var/lib/bc250-control/legacy-bc250-40cu/share/umr/database"
)
LEGACY_UMR_DATABASE_PATH = Path("/var/lib/bc250-40cu/share/umr/database")
CU_CONFIG_PATH = Path("/etc/bc250-cu-live-manager.conf")
BACKEND_LOCK_PATH = Path("/run/lock/bc250-control/backend.lock")
BACKEND_LOCK_TIMEOUT = 10.0
BACKEND_LOCK_POLL_INTERVAL = 0.05
CU_MANAGER_PATHS = (
    Path("/var/lib/bc250-control/helper/bc250-cu-live-manager"),
    Path("/var/lib/bc250-40cu/bc250-cu-live-manager"),
    Path("/var/lib/bc250-40cu/bc250-cu-live-manager.sh"),
    Path("/usr/local/bin/bc250-cu-live-manager"),
    Path("/var/usrlocal/bin/bc250-cu-live-manager"),
)

CU_MAP_SCRIPT = r"""
import ctypes
import glob
import os
import struct
import sys

render_nodes = []
for device in glob.glob("/sys/class/drm/renderD*/device"):
    try:
        with open(os.path.join(device, "vendor"), encoding="ascii") as stream:
            vendor = stream.read().strip().lower()
        with open(os.path.join(device, "device"), encoding="ascii") as stream:
            product = stream.read().strip().lower()
    except OSError:
        continue
    if vendor == "0x1002" and product == "0x13fe":
        render_nodes.append("/dev/dri/" + os.path.basename(os.path.dirname(device)))

if len(render_nodes) != 1:
    sys.exit(1)

fd = -1
dev = ctypes.c_void_p()
try:
    libdrm = ctypes.CDLL("libdrm_amdgpu.so.1")
    fd = os.open(render_nodes[0], os.O_RDWR)
    major = ctypes.c_uint32()
    minor = ctypes.c_uint32()
    if libdrm.amdgpu_device_initialize(
        fd, ctypes.byref(major), ctypes.byref(minor), ctypes.byref(dev)
    ) != 0:
        sys.exit(1)
    buffer = (ctypes.c_uint8 * 1024)()
    if libdrm.amdgpu_query_info(dev, 0x16, 1024, ctypes.byref(buffer)) != 0:
        sys.exit(1)
    raw = bytes(buffer)
    if struct.unpack_from("<I", raw, 20)[0] < 2:
        sys.exit(1)
    if struct.unpack_from("<I", raw, 24)[0] < 2:
        sys.exit(1)
    for se in range(2):
        for sh in range(2):
            mask = struct.unpack_from("<I", raw, 56 + (se * 4 + sh) * 4)[0]
            print(f"{se} {sh} 0x{mask & 0x3ff:03x}")
finally:
    if dev:
        try:
            libdrm.amdgpu_device_deinitialize(dev)
        except Exception:
            pass
    if fd >= 0:
        os.close(fd)
"""

# Decky Loader's PyInstaller environment can shadow system libraries used by
# busctl and systemctl. Subprocesses must resolve the SteamOS libraries instead.
CLEAN_ENV = {
    key: value for key, value in os.environ.items() if key != "LD_LIBRARY_PATH"
}


class CommandError(RuntimeError):
    pass


class BusyError(CommandError):
    pass


class ToolkitBackend:
    def __init__(
        self,
        user: str,
        user_home: str,
        *,
        lock_path: Optional[Path] = None,
    ) -> None:
        self.user = user
        self.user_home = Path(user_home)
        self.user_uid = pwd.getpwnam(user).pw_uid
        override = os.environ.get("BC250_TOOLKIT_DIR")
        self.toolkit = Path(override) if override else (
            self.user_home / ".local/share/bc250-fixes/bc250-steamos"
        )
        self._mutation_lock = asyncio.Lock()
        self._umr_lock = asyncio.Lock()
        self._backend_lock_path = lock_path or BACKEND_LOCK_PATH
        self._test_lock_path = lock_path is not None

    def _open_backend_lock(self) -> int:
        path = self._backend_lock_path
        if not path.is_absolute() or path.name in {"", ".", ".."}:
            raise CommandError(f"Backend lock path is invalid: {path}")

        parent = path.parent
        try:
            parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            parent_metadata = parent.lstat()
            if not stat.S_ISDIR(parent_metadata.st_mode):
                raise CommandError(f"Backend lock directory is unsafe: {parent}")
            if parent_metadata.st_mode & 0o022:
                raise CommandError(f"Backend lock directory is writable: {parent}")
            if not self._test_lock_path and parent_metadata.st_uid != 0:
                raise CommandError(f"Backend lock directory is not root-owned: {parent}")

            directory = os.open(
                str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
            )
        except CommandError:
            raise
        except OSError as error:
            raise CommandError(f"Cannot prepare backend lock: {error}") from error

        descriptor = -1
        try:
            flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW
            if os.open in os.supports_dir_fd:
                descriptor = os.open(path.name, flags, 0o600, dir_fd=directory)
            else:  # pragma: no cover - Python on macOS lacks openat support
                descriptor = os.open(str(path), flags, 0o600)
            metadata = os.fstat(descriptor)
            path_metadata = path.lstat()
            open_parent_metadata = os.fstat(directory)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise CommandError(f"Backend lock file is unsafe: {path}")
            if (metadata.st_dev, metadata.st_ino) != (
                path_metadata.st_dev,
                path_metadata.st_ino,
            ) or (parent_metadata.st_dev, parent_metadata.st_ino) != (
                open_parent_metadata.st_dev,
                open_parent_metadata.st_ino,
            ):
                raise CommandError(f"Backend lock path changed while opening: {path}")
            if metadata.st_mode & 0o022:
                raise CommandError(f"Backend lock file is writable: {path}")
            if not self._test_lock_path and metadata.st_uid != 0:
                raise CommandError(f"Backend lock file is not root-owned: {path}")
            return descriptor
        except CommandError:
            if descriptor >= 0:
                os.close(descriptor)
            raise
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise CommandError(f"Cannot open backend lock: {error}") from error
        finally:
            os.close(directory)

    @asynccontextmanager
    async def _process_lock(self) -> AsyncIterator[None]:
        descriptor = self._open_backend_lock()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + BACKEND_LOCK_TIMEOUT
        acquired = False
        try:
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                    break
                except BlockingIOError:
                    if loop.time() >= deadline:
                        raise BusyError("Another BC-250 control operation is still running.")
                    await asyncio.sleep(BACKEND_LOCK_POLL_INTERVAL)
            yield
        finally:
            if acquired:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    async def _exec(
        self,
        argv: list[str],
        *,
        timeout: float = 20,
        check: bool = True,
        env: Optional[dict[str, str]] = None,
    ) -> tuple[int, str, str]:
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env if env is not None else CLEAN_ENV,
            start_new_session=True,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
        except asyncio.CancelledError:
            await asyncio.shield(self._terminate(process))
            raise
        except asyncio.TimeoutError as error:
            await self._terminate(process)
            raise CommandError(f"Command timed out: {argv[0]}") from error
        out = stdout.decode("utf-8", "replace").strip()
        err = stderr.decode("utf-8", "replace").strip()
        if check and process.returncode != 0:
            detail = err or out or f"exit {process.returncode}"
            raise CommandError(detail[-1200:])
        return process.returncode or 0, out, err

    @staticmethod
    async def _terminate(process: asyncio.subprocess.Process) -> None:
        if process.returncode is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            await asyncio.wait_for(process.wait(), 10)
        except asyncio.TimeoutError:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await process.wait()

    def _user_argv(self, argv: list[str]) -> list[str]:
        runtime = f"/run/user/{self.user_uid}"
        environment = [
            ENV,
            "-i",
            "PATH=/usr/local/bin:/usr/bin",
            f"HOME={self.user_home}",
            f"USER={self.user}",
            f"LOGNAME={self.user}",
            f"XDG_RUNTIME_DIR={runtime}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path={runtime}/bus",
            *argv,
        ]
        if os.geteuid() == self.user_uid:
            return environment
        return [RUNUSER, "-u", self.user, "--", *environment]

    async def _user_exec(
        self, argv: list[str], *, timeout: float = 20, check: bool = True
    ) -> tuple[int, str, str]:
        return await self._exec(
            self._user_argv(argv), timeout=timeout, check=check
        )

    def _user_script(self, name: str) -> Path:
        script = self.toolkit / name
        if not self._user_script_available(name):
            raise CommandError(f"Toolkit script is missing: {script}")
        return script

    def _user_script_available(self, name: str) -> bool:
        script = self.toolkit / name
        return script.is_file() and not script.is_symlink()

    async def _user_tool(self, name: str, *args: str, timeout: float = 30) -> str:
        argv = [BASH, str(self._user_script(name)), *args]
        _, out, _ = await self._user_exec(argv, timeout=timeout)
        return out

    @staticmethod
    def _trusted_root_path(path: Path, expected_type: int) -> bool:
        try:
            if not path.is_absolute():
                return False
            current = path
            first = True
            while True:
                metadata = current.lstat()
                if stat.S_ISLNK(metadata.st_mode):
                    return False
                if first:
                    if stat.S_IFMT(metadata.st_mode) != expected_type:
                        return False
                elif not stat.S_ISDIR(metadata.st_mode):
                    return False
                if metadata.st_uid != 0 or metadata.st_mode & 0o022:
                    return False
                if current.parent == current:
                    return True
                current = current.parent
                first = False
        except OSError:
            return False

    @classmethod
    def _trusted_root_file(cls, path: Path) -> bool:
        return cls._trusted_root_path(path, stat.S_IFREG)

    @classmethod
    def _trusted_root_directory(cls, path: Path) -> bool:
        return cls._trusted_root_path(path, stat.S_IFDIR)

    @classmethod
    def _cpu_helper_available(cls) -> bool:
        return all(cls._trusted_root_file(path) for path in CPU_HELPER_REQUIRED_PATHS)

    async def _cpu_tool(self, *args: str, timeout: float = 30) -> str:
        if not self._cpu_helper_available():
            raise CommandError(
                "CPU tuning helper is missing or unsafe; reinstall the plugin."
            )
        env = {
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
            "REAL_HOME": str(self.user_home),
            "FIXES_REPO_DIR": str(self.toolkit),
            "BC250_OC_DIR": str(CPU_STATE_DIR),
            "BC250_STORAGE_SKIP_LEGACY_AIC": "1",
        }
        _, out, _ = await self._exec(
            [BASH, str(CPU_HELPER_PATH), *args], timeout=timeout, env=env
        )
        return out

    async def _ram_tool(self, *args: str, timeout: float = 30) -> str:
        if not self._trusted_root_file(RAM_HELPER_PATH):
            raise CommandError(
                "RAM configuration helper is missing or unsafe; reinstall the frontend."
            )
        env = {
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
        }
        _, out, _ = await self._exec(
            [BASH, str(RAM_HELPER_PATH), *args], timeout=timeout, env=env
        )
        return out

    def _hdmi_audio_helper_available(self) -> bool:
        return all(
            self._trusted_root_file(path) for path in HDMI_AUDIO_REQUIRED_PATHS
        )

    async def _hdmi_audio_user_exec(
        self, command: str, *, check: bool = True
    ) -> tuple[int, str, str]:
        if not self._hdmi_audio_helper_available():
            raise CommandError(
                "HDMI audio helper is missing or unsafe; reinstall the plugin."
            )
        return await self._user_exec(
            [BASH, str(HDMI_AUDIO_HELPER_PATH), command],
            timeout=120,
            check=check,
        )

    async def _hdmi_audio_root_exec(self, command: str) -> None:
        if not self._hdmi_audio_helper_available():
            raise CommandError(
                "HDMI audio helper is missing or unsafe; reinstall the plugin."
            )
        env = {
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
            "PERSISTENCE_SH": str(
                HDMI_AUDIO_HELPER_PATH.parent.parent
                / "bc250-update-persistence.sh"
            ),
        }
        await self._exec(
            [BASH, str(HDMI_AUDIO_HELPER_PATH), command],
            timeout=120,
            env=env,
        )

    async def _service(self, name: str, *, user: bool = False) -> dict[str, str]:
        runner = self._user_exec if user else self._exec
        enabled_args = (
            [SYSTEMCTL, "--user", "is-enabled", name]
            if user
            else [SYSTEMCTL, "is-enabled", name]
        )
        enabled_rc, enabled, _ = await runner(
            enabled_args,
            check=False,
            timeout=5,
        )
        if user:
            active_rc, active, _ = await runner(
                [SYSTEMCTL, "--user", "is-active", name],
                check=False,
                timeout=5,
            )
        else:
            active_rc, active, _ = await runner(
                [SYSTEMCTL, "is-active", name], check=False, timeout=5
            )
        return {
            "enabled": enabled if enabled_rc == 0 else (enabled or "disabled"),
            "active": active if active_rc == 0 else (active or "inactive"),
        }

    @staticmethod
    def _read(path: Union[str, Path], default: str = "") -> str:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except (OSError, UnicodeError):
            return default

    @staticmethod
    def _read_bounded_bytes(path: Path, limit: int) -> Optional[bytes]:
        if limit <= 0:
            return None
        descriptor = -1
        try:
            descriptor = os.open(
                str(path), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
            )
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                return None
            content = os.read(descriptor, limit + 1)
            if len(content) > limit:
                return None
            return content
        except OSError:
            return None
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    @classmethod
    def _read_bounded(cls, path: Path, limit: int) -> Optional[str]:
        content = cls._read_bounded_bytes(path, limit)
        if content is None:
            return None
        try:
            return content.decode("ascii", "strict").strip()
        except UnicodeError:
            return None

    @staticmethod
    def _read_key_values(path: Union[str, Path]) -> dict[str, str]:
        values: dict[str, str] = {}
        text = ToolkitBackend._read(path)
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key.strip()):
                values[key.strip()] = value.strip().strip('"\'')
        return values

    @staticmethod
    def _safe_int(value: Optional[str], default: int = 0) -> int:
        try:
            return int(value or default)
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _number(value: Any) -> Optional[Union[int, float]]:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return value if math.isfinite(value) else None

    @staticmethod
    def _read_toml(path: Union[str, Path]) -> dict[str, Any]:
        try:
            with Path(path).open("rb") as stream:
                return tomllib.load(stream)
        except (OSError, ValueError):
            return {}

    @staticmethod
    def _last_hex(text: str) -> Optional[int]:
        matches = re.findall(r"0x[0-9a-fA-F]+", text)
        return int(matches[-1], 16) if matches else None

    def _trusted_umr(self) -> Optional[Path]:
        configured = self._read_key_values(CU_CONFIG_PATH).get("UMR", "")
        candidates = [
            ROOT_UMR_PATH,
            Path(configured) if configured.startswith("/") else None,
            Path("/var/lib/bc250-40cu/bin/umr"),
            Path("/usr/bin/umr"),
            Path("/usr/local/bin/umr"),
        ]
        for candidate in candidates:
            if candidate is None or not self._trusted_root_file(candidate):
                continue
            try:
                if candidate.stat().st_mode & 0o111:
                    return candidate
            except OSError:
                continue
        return None

    def _trusted_umr_database(self, umr: Path) -> Optional[Path]:
        configured = self._read_key_values(CU_CONFIG_PATH).get(
            "UMR_DATABASE_PATH", ""
        )
        candidates = [
            Path(configured) if configured.startswith("/") else None,
            ROOT_UMR_DATABASE_PATH,
            umr.parent.parent / "share/umr/database",
            MIGRATED_UMR_DATABASE_PATH,
            LEGACY_UMR_DATABASE_PATH,
        ]
        seen: set[Path] = set()
        for candidate in candidates:
            if candidate is None or candidate in seen:
                continue
            seen.add(candidate)
            required = (
                candidate / "cyan_skillfish.asic",
                candidate / "cyan_skillfish.soc15",
                candidate / "ip/gc_10_1_0.reg",
            )
            if not self._trusted_root_directory(candidate):
                continue
            try:
                if all(
                    self._trusted_root_file(path) and path.stat().st_size > 0
                    for path in required
                ):
                    return candidate
            except OSError:
                continue
        return None

    def _umr_database_args(self, umr: Path) -> list[str]:
        database = self._trusted_umr_database(umr)
        return ["--database-path", str(database)] if database is not None else []

    def _trusted_cu_manager(self) -> Optional[Path]:
        for candidate in CU_MANAGER_PATHS:
            if not self._trusted_root_file(candidate):
                continue
            try:
                if candidate.stat().st_mode & 0o111:
                    return candidate
            except OSError:
                continue
        return None

    def _bc250_present(self) -> bool:
        for device in glob.glob("/sys/bus/pci/devices/*"):
            path = Path(device)
            if (
                self._read(path / "vendor").lower() == "0x1002"
                and self._read(path / "device").lower() == "0x13fe"
            ):
                return True
        return False

    def _bc250_present_secure(self) -> bool:
        try:
            devices = list(PCI_SYSFS_PATH.iterdir())
        except OSError:
            return False
        for path in devices:
            vendor = self._read_bounded(path / "vendor", 32)
            device = self._read_bounded(path / "device", 32)
            if vendor is not None and device is not None and (
                vendor.lower(), device.lower()
            ) == ("0x1002", "0x13fe"):
                return True
        return False

    def _cpu_topology(self) -> dict[str, Any]:
        logical: dict[tuple[int, int], list[int]] = {}
        ccx_ids: dict[tuple[int, int], Optional[int]] = {}
        invalid = False
        try:
            cpu_paths = sorted(
                (
                    path
                    for path in CPU_SYSFS_PATH.iterdir()
                    if re.fullmatch(r"cpu[0-9]+", path.name)
                ),
                key=lambda path: int(path.name[3:]),
            )
        except OSError:
            cpu_paths = []

        for cpu_path in cpu_paths:
            cpu = int(cpu_path.name[3:])
            online_path = cpu_path / "online"
            if online_path.exists():
                online = self._read_bounded(online_path, 8)
                if online not in {"0", "1"}:
                    invalid = True
                    continue
                if online == "0":
                    continue
            package_text = self._read_bounded(
                cpu_path / "topology/physical_package_id", 32
            )
            core_text = self._read_bounded(cpu_path / "topology/core_id", 32)
            if (
                package_text is None
                or core_text is None
                or re.fullmatch(r"-?[0-9]+", package_text) is None
                or re.fullmatch(r"-?[0-9]+", core_text) is None
            ):
                invalid = True
                continue
            key = (int(package_text), int(core_text))
            logical.setdefault(key, []).append(cpu)
            ccx_text = self._read_bounded(cpu_path / "cache/index3/id", 32)
            ccx = int(ccx_text) if ccx_text and ccx_text.isdigit() else None
            if key not in ccx_ids or ccx_ids[key] is None:
                ccx_ids[key] = ccx

        physical_cores = len(logical)
        logical_threads = sum(len(cpus) for cpus in logical.values())
        if invalid or not logical:
            state = "unavailable"
        elif physical_cores == 6:
            state = "locked"
        elif physical_cores == 8:
            state = "unlocked"
        else:
            state = "unexpected"

        cores = []
        grouped: dict[int, list[dict[str, Any]]] = {}
        for package_core in sorted(logical):
            ccx = ccx_ids.get(package_core)
            package, core = package_core
            entry = {
                "packageId": package,
                "coreId": core,
                "logicalCpus": logical[package_core],
                "ccxId": ccx,
            }
            cores.append(entry)
            if ccx is not None:
                grouped.setdefault(ccx, []).append(entry)
        return {
            "physicalCores": physical_cores,
            "logicalThreads": logical_threads,
            "topologyState": state,
            "cores": cores,
            "ccxGroups": [
                {"ccxId": ccx, "cores": grouped[ccx]} for ccx in sorted(grouped)
            ],
            "ccxAvailable": bool(grouped),
        }

    def _cpu_unlock_guard(self) -> dict[str, Any]:
        try:
            exists = os.path.lexists(CPU_UNLOCK_STATE_PATH)
        except OSError:
            exists = True
        if not exists:
            return {"state": "clear", "active": False, "currentBoot": False}
        if not self._trusted_root_file(CPU_UNLOCK_STATE_PATH):
            return {"state": "unavailable", "active": True, "currentBoot": False}
        marker = self._read_bounded(CPU_UNLOCK_STATE_PATH, 128)
        match = re.fullmatch(
            r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}) (manual|automatic)",
            marker or "",
        )
        if match is None:
            return {"state": "unavailable", "active": True, "currentBoot": False}
        boot_id = self._read_bounded(BOOT_ID_PATH, 64)
        current_boot = boot_id is not None and boot_id.lower() == match[1].lower()
        return {
            "state": match[2],
            "active": True,
            "currentBoot": current_boot,
        }

    def _cpu_unlock_payload_available(self) -> bool:
        return self._trusted_root_directory(CPU_UNLOCK_PAYLOAD_PATH) and all(
            self._trusted_root_file(CPU_UNLOCK_PAYLOAD_PATH / relative)
            for relative in CPU_UNLOCK_PAYLOAD_FILES
        )

    def _cpu_unlock_off_payload_available(self) -> bool:
        return self._trusted_root_directory(
            CPU_UNLOCK_PAYLOAD_PATH
        ) and self._trusted_root_file(CPU_UNLOCK_PAYLOAD_PATH / "bc250-power.sh")

    def _cpu_unlock_persistent(self) -> bool:
        if not self._trusted_root_file(CPU_UNLOCK_PERSISTENCE_PATH):
            return False
        content = self._read_bounded(CPU_UNLOCK_PERSISTENCE_PATH, 65536)
        if content is None:
            return False
        paths = set(content.splitlines())
        return {
            "/etc/systemd/system/bc250-core-unlock.service",
            "/etc/systemd/system/multi-user.target.wants/bc250-core-unlock.service",
        }.issubset(paths)

    @staticmethod
    def _path_represented(path: Path) -> bool:
        try:
            return os.path.lexists(path)
        except OSError:
            return True

    @staticmethod
    def _file_sha256(path: Path) -> Optional[str]:
        descriptor = -1
        try:
            descriptor = os.open(
                str(path), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
            )
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return None
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    return digest.hexdigest()
                digest.update(chunk)
        except OSError:
            return None
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _cpu_unlock_efi_file_status(self) -> dict[str, Any]:
        master_installed = self._trusted_root_file(CPU_UNLOCK_EFI_MASTER_PATH)
        image_installed = self._trusted_root_file(CPU_UNLOCK_EFI_ESP_IMAGE_PATH)
        state_installed = self._trusted_root_file(CPU_UNLOCK_EFI_STATE_PATH)
        license_installed = self._trusted_root_file(CPU_UNLOCK_EFI_LICENSE_PATH)
        header_license_installed = self._trusted_root_file(
            CPU_UNLOCK_EFI_HEADER_LICENSE_PATH
        )
        recovery_present = self._path_represented(CPU_UNLOCK_EFI_RECOVERY_PATH)
        bootnum_trusted = self._trusted_root_file(CPU_UNLOCK_EFI_BOOTNUM_PATH)
        bootnum = (
            self._read_bounded_bytes(CPU_UNLOCK_EFI_BOOTNUM_PATH, 5)
            if bootnum_trusted
            else None
        )
        bootnum_valid = bool(
            bootnum is not None and re.fullmatch(rb"[0-9a-fA-F]{4}\n?", bootnum)
        )
        bootnum_text = bootnum.rstrip(b"\n").decode("ascii") if bootnum_valid else None

        state_valid = False
        values: dict[str, str] = {}
        state_content = (
            self._read_bounded_bytes(CPU_UNLOCK_EFI_STATE_PATH, 4096)
            if state_installed
            else None
        )
        if state_content is not None:
            try:
                state_text = state_content.decode("ascii", "strict")
            except UnicodeError:
                state_text = ""
            allowed = {
                "BOOTNUM",
                "ESP_SOURCE",
                "DISK",
                "PART",
                "PARTUUID",
                "LABEL",
                "LOADER",
            }
            for line in state_text.splitlines():
                if not line or "=" not in line:
                    state_text = ""
                    break
                key, value = line.split("=", 1)
                if key not in allowed or key in values:
                    state_text = ""
                    break
                values[key] = value
            state_valid = bool(
                state_text
                and values.keys() == allowed
                and bootnum_text is not None
                and re.fullmatch(r"[0-9a-fA-F]{4}", values["BOOTNUM"])
                and values["BOOTNUM"].lower() == bootnum_text.lower()
                and re.fullmatch(r"/dev/\S+", values["ESP_SOURCE"])
                and re.fullmatch(r"/dev/\S+", values["DISK"])
                and re.fullmatch(r"[1-9][0-9]*", values["PART"])
                and re.fullmatch(
                    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                    values["PARTUUID"],
                )
                and values["LABEL"] == "BC250 Core Unlock"
                and values["LOADER"] == r"\EFI\bc250\bc250-core-unlock.efi"
            )

        master_hash = (
            self._file_sha256(CPU_UNLOCK_EFI_MASTER_PATH)
            if master_installed
            else None
        )
        image_hash = (
            self._file_sha256(CPU_UNLOCK_EFI_ESP_IMAGE_PATH)
            if image_installed
            else None
        )
        images_match = master_hash is not None and master_hash == image_hash

        hash_present = self._path_represented(CPU_UNLOCK_EFI_IMAGE_HASH_PATH)
        hash_trusted = False
        hash_valid: Optional[bool] = None
        if hash_present:
            hash_trusted = self._trusted_root_file(CPU_UNLOCK_EFI_IMAGE_HASH_PATH)
            hash_content = (
                self._read_bounded_bytes(CPU_UNLOCK_EFI_IMAGE_HASH_PATH, 65)
                if hash_trusted
                else None
            )
            hash_match = (
                re.fullmatch(rb"([0-9a-f]{64})\n?", hash_content)
                if hash_content is not None
                else None
            )
            hash_valid = bool(
                hash_match is not None
                and master_hash is not None
                and image_hash is not None
                and hash_match[1].decode("ascii").lower() == master_hash == image_hash
            )

        files_valid = bool(
            master_installed
            and image_installed
            and state_installed
            and state_valid
            and license_installed
            and header_license_installed
            and images_match
            and hash_valid is True
        )
        files_complete = files_valid and not recovery_present
        required_represented = any(
            self._path_represented(path)
            for path in (
                CPU_UNLOCK_EFI_MASTER_PATH,
                CPU_UNLOCK_EFI_STATE_PATH,
                CPU_UNLOCK_EFI_BOOTNUM_PATH,
                CPU_UNLOCK_EFI_IMAGE_HASH_PATH,
                CPU_UNLOCK_EFI_RECOVERY_PATH,
                CPU_UNLOCK_EFI_ESP_IMAGE_PATH,
                CPU_UNLOCK_EFI_LICENSE_PATH,
                CPU_UNLOCK_EFI_HEADER_LICENSE_PATH,
            )
        )
        return {
            "installed": False,
            "partial": required_represented,
            "masterInstalled": master_installed,
            "stateInstalled": state_installed,
            "stateValid": state_valid,
            "licenseInstalled": license_installed,
            "headerLicenseInstalled": header_license_installed,
            "headersLicenseInstalled": header_license_installed,
            "licensesInstalled": license_installed and header_license_installed,
            "imageInstalled": image_installed,
            "espImageInstalled": image_installed,
            "imagesMatch": images_match,
            "bootnumStateInstalled": bootnum_trusted,
            "bootEntryConfigured": state_valid,
            "bootEntry": {
                "present": False,
                "active": False,
                "matching": False,
                "firstInBootOrder": False,
                "effective": False,
                "queryAvailable": False,
            },
            "imageHashPresent": hash_present,
            "imageHashStateInstalled": hash_trusted,
            "imageHashValid": hash_valid,
            "recoveryStatePresent": recovery_present,
            "_artifactsRepresented": required_represented,
            "_filesComplete": files_complete,
            "_filesValid": files_valid,
            "_bootnum": values.get("BOOTNUM") if state_valid else None,
            "_source": values.get("ESP_SOURCE") if state_valid else None,
            "_disk": values.get("DISK") if state_valid else None,
            "_part": values.get("PART") if state_valid else None,
            "_partuuid": values.get("PARTUUID") if state_valid else None,
        }

    @staticmethod
    def _cpu_unlock_boot_entry_status(
        output: str,
        *,
        bootnum: Optional[str],
        part: Optional[str],
        partuuid: Optional[str],
    ) -> dict[str, bool]:
        result = {
            "present": False,
            "active": False,
            "matching": False,
            "firstInBootOrder": False,
            "effective": False,
            "queryAvailable": True,
        }
        if bootnum is None or part is None or partuuid is None:
            return result

        recorded = bootnum.upper()
        order_match = re.search(
            r"^BootOrder:\s*([0-9a-fA-F]{4}(?:,[0-9a-fA-F]{4})*)\s*$",
            output,
            re.MULTILINE,
        )
        if order_match is not None:
            result["firstInBootOrder"] = (
                order_match[1].split(",", 1)[0].upper() == recorded
            )

        entry_match = re.search(
            rf"^Boot{re.escape(recorded)}(\*)?\s+(.+)$",
            output,
            re.MULTILINE | re.IGNORECASE,
        )
        if entry_match is None:
            return result
        result["present"] = True
        result["active"] = entry_match[1] == "*"
        identity_match = re.fullmatch(
            r"BC250 Core Unlock HD\(([1-9][0-9]*),GPT,"
            r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}),[^)]*\)"
            r"(?:(?:/\\?)?File\(\\EFI\\bc250\\bc250-core-unlock\.efi\)"
            r"|/\\EFI\\bc250\\bc250-core-unlock\.efi)\s*",
            entry_match[2],
            re.IGNORECASE,
        )
        result["matching"] = bool(
            identity_match is not None
            and entry_match[2].startswith("BC250 Core Unlock HD(")
            and identity_match[1] == part
            and identity_match[2].lower() == partuuid.lower()
        )
        result["effective"] = all(
            result[key]
            for key in ("present", "active", "matching", "firstInBootOrder")
        )
        return result

    @staticmethod
    def _cpu_unlock_matching_boot_numbers(output: str) -> list[str]:
        pattern = re.compile(
            r"^Boot([0-9a-fA-F]{4})\*?\s+BC250 Core Unlock "
            r"HD\([^)]*\)(?:(?:/\\?)?File\(\\EFI\\bc250\\bc250-core-unlock\.efi\)"
            r"|/\\EFI\\bc250\\bc250-core-unlock\.efi)\s*$",
            re.MULTILINE | re.IGNORECASE,
        )
        return [match[1].upper() for match in pattern.finditer(output)]

    async def _cpu_unlock_efi_esp_identity_valid(
        self,
        *,
        source: Optional[str],
        disk: Optional[str],
        part: Optional[str],
        partuuid: Optional[str],
    ) -> Optional[bool]:
        if None in (source, disk, part, partuuid):
            return False
        try:
            returncode, output, _ = await self._exec(
                [
                    FINDMNT,
                    "-nro",
                    "SOURCE,TARGET,FSTYPE,OPTIONS",
                    "--target",
                    str(CPU_UNLOCK_EFI_ESP_ROOT_PATH),
                ],
                timeout=5,
                check=False,
            )
            if returncode != 0:
                return None
            concrete_mounts = []
            for line in output.splitlines():
                fields = line.split()
                if (
                    len(fields) == 4
                    and fields[1] == str(CPU_UNLOCK_EFI_ESP_ROOT_PATH)
                    and fields[2].lower() != "autofs"
                ):
                    concrete_mounts.append(fields)
            if len(concrete_mounts) != 1:
                return False
            mount_source, target, filesystem, options = concrete_mounts[0]
            if (
                target != str(CPU_UNLOCK_EFI_ESP_ROOT_PATH)
                or filesystem.lower() not in {"vfat", "fat", "fat32"}
                or "rw" not in options.split(",")
            ):
                return False
            returncode, output, _ = await self._exec(
                [
                    LSBLK,
                    "-dnpro",
                    "NAME,TYPE,PKNAME,PARTN,PARTUUID,PARTTYPE",
                    mount_source,
                ],
                timeout=5,
                check=False,
            )
            if returncode != 0:
                return None
            fields = output.split()
            if len(fields) != 6:
                return False
            name, kind, parent, actual_part, actual_uuid, parttype = fields
            partition_type_valid = (
                parttype.lower() == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
            )
            if parttype.lower() == "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7":
                try:
                    partition_type_valid = (
                        CPU_UNLOCK_STEAMOS_EFI_PARTSET_PATH.is_symlink()
                        and CPU_UNLOCK_STEAMOS_EFI_PARTSET_PATH.resolve(strict=True)
                        == Path(name).resolve(strict=True)
                    )
                except (OSError, RuntimeError):
                    partition_type_valid = False
            return bool(
                name == source
                and kind == "part"
                and parent == disk
                and actual_part == part
                and actual_uuid.lower() == partuuid.lower()
                and partition_type_valid
            )
        except (CommandError, OSError):
            return None

    async def _cpu_unlock_efi_status(self) -> dict[str, Any]:
        status = self._cpu_unlock_efi_file_status()
        represented = status.pop("_artifactsRepresented")
        files_complete = status.pop("_filesComplete")
        files_valid = status.pop("_filesValid")
        bootnum = status.pop("_bootnum")
        source = status.pop("_source")
        disk = status.pop("_disk")
        part = status.pop("_part")
        partuuid = status.pop("_partuuid")
        guard_present = self._path_represented(CPU_UNLOCK_EFI_GUARD_PATH)
        uefi_runtime_available = CPU_UNLOCK_EFIVARS_DIR_PATH.is_dir()
        boot_entry = {
            "present": False,
            "active": False,
            "matching": False,
            "firstInBootOrder": False,
            "effective": False,
            "queryAvailable": False,
        }
        matching_numbers: list[str] = []
        try:
            returncode, output, _ = await self._exec(
                [EFIBOOTMGR, "-v"], timeout=5, check=False
            )
            if returncode == 0 and re.search(r"^BootOrder:", output, re.MULTILINE):
                boot_entry = self._cpu_unlock_boot_entry_status(
                    output, bootnum=bootnum, part=part, partuuid=partuuid
                )
                matching_numbers = self._cpu_unlock_matching_boot_numbers(output)
        except (CommandError, OSError):
            pass
        esp_identity_valid = await self._cpu_unlock_efi_esp_identity_valid(
            source=source,
            disk=disk,
            part=part,
            partuuid=partuuid,
        )
        represented = bool(
            represented
            or guard_present
            or matching_numbers
            or (uefi_runtime_available and not boot_entry["queryAvailable"])
        )
        unique_recorded_entry = bool(
            bootnum is not None
            and matching_numbers == [bootnum.upper()]
        )
        status["bootEntry"] = boot_entry
        status["efiGuardPresent"] = guard_present
        status["uefiRuntimeAvailable"] = uefi_runtime_available
        status["espIdentityValid"] = esp_identity_valid
        status["matchingEntryCount"] = len(matching_numbers)
        status["unrecordedMatchingEntries"] = bool(
            matching_numbers
            and (bootnum is None or matching_numbers != [bootnum.upper()])
        )
        status["installed"] = bool(
            files_complete
            and not guard_present
            and esp_identity_valid is True
            and boot_entry["effective"]
            and unique_recorded_entry
        )
        status["recoverable"] = bool(
            files_valid
            and status["recoveryStatePresent"]
            and not guard_present
            and esp_identity_valid is True
            and boot_entry["effective"]
            and unique_recorded_entry
        )
        status["partial"] = represented and not status["installed"]
        return status

    @staticmethod
    def _cpu_unlock_action_status(
        action: str,
        *,
        device_present: bool,
        topology_state: str,
        payload_available: bool,
        service_enabled: bool,
        mode: str,
        guard: dict[str, Any],
        efi_recoverable: bool = False,
    ) -> dict[str, Any]:
        blockers = []
        if action == "off":
            if not payload_available:
                blockers.append("helper-bundle-unavailable")
            if guard["state"] == "automatic" and guard["currentBoot"]:
                blockers.append("automatic-reboot-pending")
            return {"available": not blockers, "blockers": blockers}
        if not payload_available:
            blockers.append("helper-bundle-unavailable")
        if not device_present:
            blockers.append("device-not-detected")
        if topology_state == "unavailable":
            blockers.append("topology-unavailable")
        elif topology_state == "unexpected":
            blockers.append("topology-unexpected")
        if guard["state"] == "unavailable":
            blockers.append("guard-unavailable")
        elif guard["state"] == "automatic":
            blockers.append("automatic-reboot-pending")
        elif action == "test" and guard["currentBoot"] and topology_state == "locked":
            blockers.append("unlock-already-attempted-this-boot")
        if action == "test":
            if mode in ("linux-replay", "conflict"):
                blockers.append("persistent-replay-enabled")
            if mode in ("efi", "conflict"):
                blockers.append("efi-unlock-enabled")
            if mode == "partial":
                blockers.append("efi-installation-partial")
        if action == "enable" and topology_state != "unlocked":
            blockers.append("eight-cores-required")
        if action == "enable" and service_enabled:
            blockers.append("persistent-replay-enabled")
        if action == "enable" and mode in ("efi", "conflict"):
            blockers.append("efi-unlock-enabled")
        if action == "enable" and mode == "partial":
            blockers.append("efi-installation-partial")
        if action == "efi-enable" and topology_state != "unlocked":
            blockers.append("eight-cores-required")
        if action == "efi-enable" and mode in ("linux-replay", "conflict"):
            blockers.append("persistent-replay-enabled")
        if action == "efi-enable" and mode == "efi":
            blockers.append("efi-unlock-enabled")
        if action == "efi-enable" and mode == "partial" and not efi_recoverable:
            blockers.append("efi-installation-partial")
        return {"available": not blockers, "blockers": blockers}

    async def get_cpu_unlock_status(self) -> dict[str, Any]:
        service_task = asyncio.create_task(
            self._service("bc250-core-unlock.service")
        )
        efi_task = asyncio.create_task(self._cpu_unlock_efi_status())
        topology = self._cpu_topology()
        guard = self._cpu_unlock_guard()
        service, efi = await asyncio.gather(service_task, efi_task)
        service_enabled = service["enabled"] == "enabled"
        device_present = self._bc250_present_secure()
        payload_available = self._cpu_unlock_payload_available()
        off_payload_available = self._cpu_unlock_off_payload_available()
        helper_installed = self._trusted_root_file(CPU_UNLOCK_HELPER_PATH)
        license_installed = self._trusted_root_file(CPU_UNLOCK_LICENSE_PATH)
        unit_installed = self._trusted_root_file(CPU_UNLOCK_UNIT_PATH)
        update_persistence = self._cpu_unlock_persistent()
        linux_replay = {
            "installed": helper_installed and license_installed and unit_installed,
            "enabled": service_enabled,
            "service": service,
            "updatePersistence": update_persistence,
        }
        if service_enabled and (efi["installed"] or efi["partial"]):
            mode = "conflict"
        elif efi["partial"]:
            mode = "partial"
        elif service_enabled:
            mode = "linux-replay"
        elif efi["installed"]:
            mode = "efi"
        elif topology["topologyState"] == "unlocked":
            mode = "temporary"
        else:
            mode = "none"
        actions = {
            action: self._cpu_unlock_action_status(
                action,
                device_present=device_present,
                topology_state=topology["topologyState"],
                payload_available=(
                    off_payload_available if action == "off" else payload_available
                ),
                service_enabled=service_enabled,
                mode=mode,
                guard=guard,
                efi_recoverable=efi.get("recoverable", False),
            )
            for action in ("test", "enable", "efi-enable", "off")
        }
        return {
            "schemaVersion": 1,
            "devicePresent": device_present,
            **topology,
            "helperInstalled": helper_installed,
            "licenseInstalled": license_installed,
            "unitInstalled": unit_installed,
            "helperBundleAvailable": payload_available,
            "service": service,
            "updatePersistence": update_persistence,
            "guard": guard,
            "mode": mode,
            "linuxReplay": linux_replay,
            "efi": efi,
            "actions": actions,
            "semantics": {
                "test": "A six-core test requires a warm reboot before Linux can enumerate eight cores.",
                "off": "Disabling automatic unlock does not relock this boot; eight active cores require a full power-off.",
            },
        }

    def _umr_instance(self) -> Optional[int]:
        configured = self._read_key_values(CU_CONFIG_PATH).get("UMR_INSTANCE", "")
        if configured.isdigit():
            return int(configured)

        slots = []
        for device in glob.glob("/sys/bus/pci/devices/*"):
            path = Path(device)
            if (
                self._read(path / "vendor").lower() == "0x1002"
                and self._read(path / "device").lower() == "0x13fe"
            ):
                slots.append(path.name)

        instances = []
        for name_path in glob.glob("/sys/kernel/debug/dri/[0-9]*/name"):
            instance = Path(name_path).parent.name
            if not instance.isdigit() or int(instance) >= 128:
                continue
            instances.append(int(instance))
            name = self._read(name_path).lower()
            if any(slot.lower() in name for slot in slots):
                return int(instance)
        return instances[0] if len(instances) == 1 else None

    async def _umr_register(self, register: str, se: int, sh: int) -> Optional[int]:
        if os.geteuid() != 0:
            return None
        umr = self._trusted_umr()
        if umr is None:
            return None
        instance = self._umr_instance()
        instance_args = ["-i", str(instance)] if instance is not None else []
        database_args = self._umr_database_args(umr)
        asic = self._read_key_values(CU_CONFIG_PATH).get(
            "UMR_ASIC", "cyan_skillfish.gfx1013"
        )
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", asic):
            return None
        async with self._umr_lock:
            for bank_args in (
                ["-b", str(se), str(sh), "0xffffffff"],
                ["-b", str(se), str(sh)],
            ):
                _rc, out, err = await self._exec(
                    [
                        str(umr),
                        *database_args,
                        *instance_args,
                        "-r",
                        f"{asic}.{register}",
                        *bank_args,
                    ],
                    timeout=5,
                    check=False,
                )
                value = self._last_hex(f"{out}\n{err}")
                # Some UMR builds return a nonzero status after printing a valid
                # register value. The CU manager uses the parsed value as the
                # success signal as well, so keep both callers consistent.
                if value is not None:
                    return value
        return None

    async def _factory_cu_masks(self) -> Optional[list[int]]:
        try:
            rc, out, _ = await self._exec(
                [PYTHON3, "-c", CU_MAP_SCRIPT], timeout=5, check=False
            )
        except (CommandError, OSError):
            return None
        if rc != 0:
            return None
        rows: dict[tuple[int, int], int] = {}
        for line in out.splitlines():
            match = re.fullmatch(r"([01]) ([01]) (0x[0-9a-fA-F]+)", line.strip())
            if match is None:
                return None
            se, sh, mask = int(match[1]), int(match[2]), int(match[3], 16)
            if mask > 0x3FF or (se, sh) in rows:
                return None
            rows[(se, sh)] = mask
        if set(rows) != {(0, 0), (0, 1), (1, 0), (1, 1)}:
            return None
        masks = [rows[(se, sh)] for se in range(2) for sh in range(2)]
        if sum(bin(mask).count("1") for mask in masks) != 24:
            return None
        return masks

    async def get_cu_status(self) -> dict[str, Any]:
        service_task = asyncio.create_task(
            self._service("bc250-cu-live-manager.service")
        )
        factory_masks = await self._factory_cu_masks()
        reads = []
        for se in range(2):
            for sh in range(2):
                reads.append(
                    self._umr_register("mmSPI_PG_ENABLE_STATIC_WGP_MASK", se, sh)
                )
        values = await asyncio.gather(*reads)
        rows = []
        total = 0
        for index, spi in enumerate(values):
            mask = (spi or 0) & 0x1F
            factory_mask = factory_masks[index] if factory_masks is not None else None
            count = bin(mask).count("1") * 2 if spi is not None else 0
            total += count
            rows.append(
                {
                    "se": index // 2,
                    "sh": index % 2,
                    "spi": spi,
                    "cc": None,
                    "wgps": [bool(mask & (1 << bit)) for bit in range(5)],
                    "cus": count,
                    "factoryCuMask": factory_mask,
                    "factoryWgps": [
                        bool(factory_mask & (0x3 << (bit * 2)))
                        for bit in range(5)
                    ]
                    if factory_mask is not None
                    else [False] * 5,
                }
            )
        saved = self._read_key_values(CU_CONFIG_PATH)
        saved_masks = []
        saved_values = saved.get("BC250_WGP_MASKS", "").split(",")
        try:
            parsed_masks = [int(value, 0) for value in saved_values]
        except ValueError:
            parsed_masks = []
        if len(parsed_masks) == 4 and all(0 <= mask <= 0x1F for mask in parsed_masks):
            saved_masks = parsed_masks
        available = all(row["spi"] is not None for row in rows)
        privileged = os.geteuid() == 0
        trusted_umr = self._trusted_umr()
        trusted_database = (
            self._trusted_umr_database(trusted_umr)
            if trusted_umr is not None
            else None
        )
        return {
            "available": available,
            "controllable": (
                available
                and privileged
                and factory_masks is not None
                and self._trusted_cu_manager() is not None
                and self._bc250_present()
            ),
            "liveReason": None
            if available
            else (
                "Decky launched the plugin without root access; reinstall it with the root flag."
                if not privileged
                else "Live status requires the plugin's root-owned UMR copy; reinstall the plugin after installing UMR."
                if trusted_umr is None
                else "The trusted UMR ASIC database is incomplete; reinstall the plugin."
                if trusted_database is None
                else "The trusted UMR installation could not read GPU registers."
            ),
            "total": total,
            "maximum": 40,
            "rows": rows,
            "savedMasks": saved_masks,
            "factoryMapAvailable": factory_masks is not None,
            "factoryTotal": 24 if factory_masks is not None else None,
            "service": await service_task,
            "protected": Path(
                "/etc/atomic-update.conf.d/bc250-compute.conf"
            ).is_file(),
        }

    def _temperatures(self) -> list[dict[str, Any]]:
        temperatures = []
        for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
            name = self._read(Path(hwmon) / "name", Path(hwmon).name)
            for source in glob.glob(f"{hwmon}/temp*_input"):
                match = re.search(r"temp(\d+)_input$", source)
                if not match:
                    continue
                index = match.group(1)
                raw = self._read(source)
                try:
                    value = round(int(raw) / 1000, 1)
                except ValueError:
                    continue
                label = self._read(
                    Path(hwmon) / f"temp{index}_label", f"temp{index}"
                )
                temperatures.append(
                    {"device": name, "label": label, "celsius": value}
                )
        return temperatures

    def _cpu_current_mhz(self) -> Optional[int]:
        effective = [
            float(match.group(1))
            for match in re.finditer(
                r"^cpu MHz\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*$",
                self._read(Path("/proc/cpuinfo")),
                re.MULTILINE,
            )
        ]
        if effective:
            return round(max(effective))

        candidates = [
            Path(path)
            for path in sorted(
                glob.glob("/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq")
            )
        ]
        if not candidates:
            candidates = [
                Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
            ]
        current_values = []
        for path in candidates:
            current = self._read(path)
            if current.isdigit():
                current_values.append(int(current))
        return round(max(current_values) / 1000) if current_values else None

    def _cpu_governor(self) -> str:
        candidates = [Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")]
        candidates.extend(
            Path(path)
            for path in sorted(
                glob.glob("/sys/devices/system/cpu/cpufreq/policy*/scaling_governor")
            )
        )
        for path in candidates:
            governor = self._read(path)
            if governor:
                return governor
        return ""

    def _active_gpu_mhz(self) -> Optional[int]:
        for path in glob.glob("/sys/class/drm/card*/device/pp_dpm_sclk"):
            levels = self._read(path)
            match = re.search(r"(\d+)Mhz\s+\*", levels, re.IGNORECASE)
            if match:
                return int(match.group(1))
        return None

    @staticmethod
    def _matching_temperature(
        temperatures: list[dict[str, Any]], pattern: str
    ) -> Optional[Union[int, float]]:
        matcher = re.compile(pattern, re.IGNORECASE)
        for temperature in temperatures:
            if matcher.search(f"{temperature['device']} {temperature['label']}"):
                return temperature["celsius"]
        return None

    async def get_telemetry(self) -> dict[str, Optional[Union[int, float]]]:
        temperatures = self._temperatures()
        return {
            "cpuClock": self._cpu_current_mhz(),
            "gpuClock": self._active_gpu_mhz(),
            "cpuTemp": self._matching_temperature(
                temperatures, r"k10temp|cpu|tctl|package"
            ),
            "gpuTemp": self._matching_temperature(
                temperatures, r"amdgpu|gpu|edge|junction"
            ),
        }

    async def get_power_status(self) -> dict[str, Any]:
        governor, acpi, cpufreq, restore = await asyncio.gather(
            self._service("cyan-skillfish-governor-smu.service"),
            self._service("bc250-acpi-heal.service"),
            self._service("bc250-cpufreq.service"),
            self._service("bc250-gpu-freq-restore.service"),
        )
        cpu_roots = sorted(
            path
            for path in Path("/sys/devices/system/cpu").glob("cpu[0-9]*")
            if path.name[3:].isdigit()
            and (
                not (path / "online").is_file()
                or self._read(path / "online") != "0"
            )
        )
        c_state_counts = [
            len(list((path / "cpuidle").glob("state*"))) for path in cpu_roots
        ]
        return {
            "acpiActive": bool(cpu_roots)
            and all((path / "cpufreq").is_dir() for path in cpu_roots),
            "cStates": min(c_state_counts, default=0),
            "cpuGovernor": self._cpu_governor(),
            "cpuCurrentMhz": self._cpu_current_mhz(),
            "governor": governor,
            "acpiService": acpi,
            "cpufreqService": cpufreq,
            "frequencyRestore": restore,
            "temperatures": self._temperatures(),
            "protected": Path(
                "/etc/atomic-update.conf.d/bc250-power.conf"
            ).is_file(),
        }

    def _gpu_config(self) -> dict[str, Any]:
        config = self._read_toml(GPU_CONFIG_PATH)
        points = []
        safe_points = config.get("safe-points", [])
        if not isinstance(safe_points, list):
            safe_points = []
        for point in safe_points:
            if isinstance(point, dict):
                points.append(
                    {
                        "frequency": self._number(point.get("frequency")),
                        "voltage": self._number(point.get("voltage")),
                    }
                )
        load = config.get("load-target", {})
        if not isinstance(load, dict):
            load = {}
        timing = config.get("timing", {})
        if not isinstance(timing, dict):
            timing = {}
        intervals = timing.get("intervals", {})
        if not isinstance(intervals, dict):
            intervals = {}
        rates = timing.get("ramp-rates", {})
        if not isinstance(rates, dict):
            rates = {}
        frequency_range = config.get("frequency-range", {})
        if not isinstance(frequency_range, dict):
            frequency_range = {}
        return {
            "safePoints": points,
            "configuredMax": self._number(frequency_range.get("max")),
            "loadUpper": self._number(load.get("upper")),
            "loadLower": self._number(load.get("lower")),
            "adjustMicros": self._number(intervals.get("adjust")),
            "rampNormal": self._number(rates.get("normal")),
            "downEvents": self._number(timing.get("down-events")),
        }

    @staticmethod
    def _atomic_write(path: Path, content: str, mode: int = 0o644) -> None:
        if path.is_symlink():
            raise CommandError(f"Refusing to replace symlink: {path}")
        metadata = None
        if path.exists():
            metadata = path.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise CommandError(f"Refusing to replace non-file: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) if metadata else mode)
            if metadata:
                os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    @classmethod
    def _update_toml_values(
        cls, path: Path, updates: dict[str, dict[str, str]]
    ) -> None:
        if not path.is_file() or path.is_symlink():
            raise CommandError(f"Governor config is unavailable: {path}")
        lines = path.read_text(encoding="utf-8").splitlines()
        for section, values in updates.items():
            header = f"[{section}]"
            try:
                start = lines.index(header)
            except ValueError:
                if lines and lines[-1] != "":
                    lines.append("")
                lines.append(header)
                start = len(lines) - 1
            end = len(lines)
            for index in range(start + 1, len(lines)):
                if lines[index].startswith("["):
                    end = index
                    break
            for key, value in values.items():
                key_pattern = re.compile(rf"^{re.escape(key)}\s*=")
                found = None
                for index in range(start + 1, end):
                    if key_pattern.match(lines[index]):
                        found = index
                        break
                rendered = f"{key} = {value}"
                if found is None:
                    lines.insert(end, rendered)
                    end += 1
                else:
                    lines[found] = rendered
        candidate = "\n".join(lines) + "\n"
        try:
            tomllib.loads(candidate)
        except (TypeError, ValueError) as error:
            raise CommandError(f"Governor config update is invalid: {error}") from error
        cls._atomic_write(path, candidate)

    async def _gpu_call(self, method: str, *signature_and_args: str) -> None:
        await self._exec(
            [
                BUSCTL,
                "--system",
                "call",
                "com.cyanskillfish.Governor",
                "/com/cyanskillfish/Governor",
                "com.cyanskillfish.Governor.PerformanceMode",
                method,
                *signature_and_args,
            ],
            timeout=8,
        )

    async def _set_gpu_enabled(self, enabled: bool) -> None:
        await self._exec(
            [
                BUSCTL,
                "--system",
                "set-property",
                "com.cyanskillfish.Governor",
                "/com/cyanskillfish/Governor",
                "com.cyanskillfish.Governor.PerformanceMode",
                "Enabled",
                "b",
                "true" if enabled else "false",
            ],
            timeout=8,
        )

    async def _system_bus_property(
        self, path: str, interface: str, prop: str
    ) -> Optional[int]:
        rc, out, _ = await self._exec(
            [
                BUSCTL,
                "--system",
                "get-property",
                "com.cyanskillfish.Governor",
                path,
                interface,
                prop,
            ],
            timeout=5,
            check=False,
        )
        value = self._bus_value(out) if rc == 0 else None
        return value if isinstance(value, int) else None

    def _write_frequency_state(
        self, mode: str, first: int = 0, second: int = 0
    ) -> None:
        state = GPU_STATE_PATH
        if str(state).startswith("/var/lib/bc250-control/"):
            parent = state.parent
            if not self._trusted_root_directory(parent):
                raise CommandError(f"GPU frequency state directory is unsafe: {parent}")
            if state.exists() and not self._trusted_root_file(state):
                raise CommandError(f"GPU frequency state is unsafe: {state}")
        if state.is_symlink():
            raise CommandError(f"Refusing to modify symlink: {state}")
        if mode == "adaptive":
            if state.exists():
                if not state.is_file():
                    raise CommandError(f"Refusing to remove non-file: {state}")
                state.unlink()
            return
        self._atomic_write(state, f"MODE={mode}\nA={first or ''}\nB={second or ''}\n")
        if os.geteuid() == 0:
            os.chown(state, 0, 0)
            os.chmod(state, 0o644)

    async def _apply_frequency(
        self, mode: str, first: int = 0, second: int = 0
    ) -> None:
        if mode == "adaptive":
            await self._set_gpu_enabled(False)
        elif mode == "max":
            await self._set_gpu_enabled(True)
        elif mode == "pin" and first:
            await self._gpu_call("SetFixedFrequency", "u", str(first))
        elif mode == "range" and second:
            await self._gpu_call("SetRange", "uu", str(first), str(second))
        else:
            raise CommandError("Saved GPU frequency state is invalid.")

    async def _apply_frequency_state(self) -> None:
        state = self._read_key_values(GPU_STATE_PATH)
        mode = state.get("MODE", "adaptive")
        first = self._safe_int(state.get("A"))
        second = self._safe_int(state.get("B"))
        await self._apply_frequency(mode, first, second)

    async def _wait_for_governor(self, timeout: int = 30) -> None:
        for _ in range(timeout):
            rc, _, _ = await self._exec(
                [BUSCTL, "--system", "status", "com.cyanskillfish.Governor"],
                timeout=3,
                check=False,
            )
            if rc == 0:
                return
            await asyncio.sleep(1)
        raise CommandError("GPU governor D-Bus service did not become ready.")

    async def _restart_governor_and_reapply(self) -> None:
        await self._exec(
            [SYSTEMCTL, "restart", "cyan-skillfish-governor-smu.service"]
        )
        await self._wait_for_governor()
        await self._apply_frequency_state()

    async def _restore_gpu_config(
        self, path: Path, content: str, was_active: bool
    ) -> None:
        self._atomic_write(path, content)
        if was_active:
            await self._restart_governor_and_reapply()

    async def _update_gpu_config(
        self,
        updates: dict[str, dict[str, str]],
        *,
        live_callback: Any = None,
        restart: bool = False,
    ) -> None:
        path = GPU_CONFIG_PATH
        if not path.is_file() or path.is_symlink():
            raise CommandError(f"Governor config is unavailable: {path}")
        governor = await self._service("cyan-skillfish-governor-smu.service")
        was_active = governor["active"] == "active"
        original = path.read_text(encoding="utf-8")
        self._update_toml_values(path, updates)
        try:
            if not was_active:
                return
            if live_callback is not None:
                try:
                    await live_callback()
                    return
                except CommandError:
                    pass
            if restart or live_callback is not None:
                await self._restart_governor_and_reapply()
        except BaseException as error:
            rollback = asyncio.ensure_future(
                self._restore_gpu_config(path, original, was_active)
            )
            try:
                await asyncio.shield(rollback)
            except asyncio.CancelledError:
                await rollback
            except Exception as rollback_error:
                raise CommandError(
                    f"{error}; config rollback failed: {rollback_error}"
                ) from error
            raise error

    async def get_gpu_status(self) -> dict[str, Any]:
        governor_service, restore_service = await asyncio.gather(
            self._service("cyan-skillfish-governor-smu.service"),
            self._service("bc250-gpu-freq-restore.service"),
        )
        state = self._read_key_values(GPU_STATE_PATH)
        config = self._gpu_config()
        active_mhz = self._active_gpu_mhz()
        levels = ""
        for path in glob.glob("/sys/class/drm/card*/device/pp_dpm_sclk"):
            levels = self._read(path)
            if levels:
                break
        requested_mode = state.get("MODE", "adaptive")
        requested_min = self._safe_int(state.get("A"))
        requested_max = self._safe_int(state.get("B") or state.get("A"))
        (
            allowed_min,
            allowed_max,
            current_min,
            current_max,
            initial_min,
            initial_max,
            enabled,
        ) = await asyncio.gather(
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Allowed",
                "com.cyanskillfish.Governor.Range",
                "Min",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Allowed",
                "com.cyanskillfish.Governor.Range",
                "Max",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Current",
                "com.cyanskillfish.Governor.Range",
                "Min",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Current",
                "com.cyanskillfish.Governor.Range",
                "Max",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Initial",
                "com.cyanskillfish.Governor.Range",
                "Min",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor/Range/Initial",
                "com.cyanskillfish.Governor.Range",
                "Max",
            ),
            self._system_bus_property(
                "/com/cyanskillfish/Governor",
                "com.cyanskillfish.Governor.PerformanceMode",
                "Enabled",
            ),
        )
        dbus_ready = enabled is not None
        privileged = os.geteuid() == 0
        mode = requested_mode
        if dbus_ready and current_min is not None and current_max is not None:
            if requested_mode == "pin" and (
                current_min == requested_max and current_max == requested_max
            ):
                mode = "pin"
            elif requested_mode == "range" and (
                current_max == requested_max
                and (requested_min == 0 or current_min == requested_min)
            ):
                mode = "range"
            elif requested_mode == "max" and enabled is True:
                mode = "max"
            elif current_min == current_max:
                mode = "pin"
            elif current_min == initial_min and current_max == initial_max:
                mode = "adaptive"
            else:
                mode = "range"
        replay_applied = False
        if dbus_ready and requested_mode == "pin":
            replay_applied = (
                current_min == requested_max and current_max == requested_max
            )
        elif dbus_ready and requested_mode == "range":
            replay_applied = (
                current_max == requested_max
                and (requested_min == 0 or current_min == requested_min)
            )
        elif dbus_ready and requested_mode == "max":
            replay_applied = enabled is True
        elif dbus_ready and requested_mode == "adaptive":
            replay_applied = enabled is False and (
                current_min == initial_min and current_max == initial_max
            )
        span_min = allowed_min or 300
        span_max = config.get("configuredMax") or allowed_max or 2200
        normal = config.get("rampNormal")
        climb_ms = (
            round((span_max - span_min) / normal)
            if isinstance(normal, (int, float)) and normal > 0 and span_max > span_min
            else None
        )
        return {
            "available": GPU_CONFIG_PATH.is_file(),
            "controllable": dbus_ready and privileged,
            "dbusReady": dbus_ready,
            "mode": mode,
            "requestedMode": requested_mode,
            "requestedMinimum": requested_min,
            "requestedMaximum": requested_max,
            "minimum": current_min
            if dbus_ready and current_min is not None
            else self._safe_int(state.get("A")),
            "maximum": current_max
            if dbus_ready and current_max is not None
            else self._safe_int(state.get("B") or state.get("A")),
            "liveMinimum": current_min,
            "liveMaximum": current_max,
            "initialMinimum": initial_min,
            "initialMaximum": initial_max,
            "activeMhz": active_mhz,
            "levels": levels.splitlines(),
            "allowedMinimum": allowed_min,
            "allowedMaximum": allowed_max,
            "climbMs": climb_ms,
            "governorService": governor_service,
            "frequencyRestore": restore_service,
            "persistent": restore_service["enabled"] == "enabled",
            "replayApplied": replay_applied,
            **config,
        }

    def _cpu_config(self, path: Union[str, Path]) -> dict[str, Any]:
        values = self._read_key_values(path)
        detected = ""
        for line in self._read(path).splitlines():
            if line.startswith("# detected:"):
                detected = line[len("# detected:") :].strip()
        return {"values": values, "detected": detected}

    def _toolkit_file(self, path: Path) -> bool:
        try:
            metadata = path.stat()
            resolved = path.resolve(strict=True)
            toolkit = self.toolkit.resolve(strict=True)
        except OSError:
            return False
        return (
            not path.is_symlink()
            and stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid in {0, self.user_uid}
            and os.path.commonpath((str(resolved), str(toolkit))) == str(toolkit)
        )

    async def get_cpu_status(self) -> dict[str, Any]:
        service = await self._service("bc250-smu-oc.service")
        installed_path = Path("/etc/bc250-smu-oc.conf")
        staged_path = CPU_STATE_DIR / "overclock.conf"
        mitigations = {
            "schemaVersion": 1,
            "available": False,
            "state": "unavailable",
            "configuredEnabled": None,
            "bootEnabled": None,
            "rebootRequired": False,
            "protected": False,
        }
        if self._cpu_helper_available():
            try:
                value = json.loads(
                    await self._cpu_tool("cpu-mitigations", "status-json")
                )
            except (CommandError, json.JSONDecodeError):
                value = None
            if (
                isinstance(value, dict)
                and {
                    "schemaVersion",
                    "available",
                    "state",
                    "configuredEnabled",
                    "bootEnabled",
                    "rebootRequired",
                    "protected",
                }.issubset(value)
                and type(value.get("schemaVersion")) is int
                and value.get("schemaVersion") == 1
                and value.get("available") is True
                and value.get("state")
                in {"enabled", "disabled", "foreign", "incomplete"}
                and type(value.get("rebootRequired")) is bool
                and type(value.get("protected")) is bool
                and (
                    value.get("configuredEnabled") is None
                    or type(value.get("configuredEnabled")) is bool
                )
                and (
                    value.get("bootEnabled") is None
                    or type(value.get("bootEnabled")) is bool
                )
                and (
                    (value.get("state") == "enabled" and value.get("configuredEnabled") is True)
                    or (value.get("state") == "disabled" and value.get("configuredEnabled") is False)
                    or (
                        value.get("state") in {"foreign", "incomplete"}
                        and value.get("configuredEnabled") is None
                    )
                )
            ):
                mitigations = value
        return {
            "service": service,
            "installed": self._cpu_config(installed_path)
            if installed_path.is_file()
            else None,
            "staged": self._cpu_config(staged_path)
            if self._trusted_root_file(staged_path)
            else None,
            "toolAvailable": self._trusted_root_file(
                CPU_STATE_DIR / "bc250_apply.py"
            ),
            "mitigations": mitigations,
        }

    @staticmethod
    def _bus_value(output: str) -> Any:
        try:
            parts = shlex.split(output)
        except ValueError:
            return output
        if len(parts) < 2:
            return None
        if parts[0] == "b":
            return parts[1] == "true"
        if parts[0] in {"y", "u", "i", "q", "n", "x", "t"}:
            try:
                return int(parts[1])
            except ValueError:
                return parts[1]
        if parts[0] == "s":
            return parts[1]
        return parts[1:]

    async def _cec_properties(
        self, path: str, interface: str, properties: tuple[str, ...]
    ) -> list[Any]:
        rc, out, _ = await self._user_exec(
            [
                BUSCTL,
                "--user",
                "--timeout=3",
                "get-property",
                "com.steampowered.CecDaemon1",
                path,
                interface,
                *properties,
            ],
            timeout=5,
            check=False,
        )
        if rc != 0:
            return [None] * len(properties)
        values = [self._bus_value(line) for line in out.splitlines()]
        return values if len(values) == len(properties) else [None] * len(properties)

    async def get_cec_status(self) -> dict[str, Any]:
        daemon_path = "/com/steampowered/CecDaemon1/Daemon"
        device_path = "/com/steampowered/CecDaemon1/Devices/Cec0"
        config_if = "com.steampowered.CecDaemon1.Config1"
        device_if = "com.steampowered.CecDaemon1.CecDevice1"
        config = await self._cec_properties(
            daemon_path,
            config_if,
            ("OsdName", "WakeTv", "SuspendTv", "AllowStandby", "Uinput"),
        )
        device = await self._cec_properties(
            device_path,
            device_if,
            ("Active", "PhysicalAddress", "AudioLogicalAddress"),
        )
        properties = [*config, *device]
        # Property access can D-Bus-activate cecd, so capture service state after it.
        service = await self._service("cecd.service", user=True)
        if any(value is not None for value in properties):
            service["active"] = "active"
        return {
            "devicePresent": Path("/dev/cec0").exists(),
            "service": service,
            "osdName": properties[0],
            "wakeTv": properties[1],
            "suspendTv": properties[2],
            "allowStandby": properties[3],
            "uinput": properties[4],
            "active": properties[5],
            "physicalAddress": properties[6],
            "audioLogicalAddress": properties[7],
            "poweroffIntegration": Path(
                "/etc/systemd/system/bc250-cec-poweroff-standby.service"
            ).is_file(),
            "sleepIntegration": Path(
                "/etc/systemd/system-sleep/bc250-cec-amp.sh"
            ).is_file(),
            "protected": Path(
                "/etc/atomic-update.conf.d/bc250-cec.conf"
            ).is_file(),
        }

    async def get_ram_status(self) -> dict[str, Any]:
        unavailable = {
            "schemaVersion": 1,
            "available": False,
            "toolState": "not-installed",
            "toolVersion": None,
            "umaLastRequestedMiB": None,
            "ttmState": "default",
            "ttmConfiguredPages": None,
            "ttmBootPages": None,
            "ttmLivePages": None,
            "rebootRequired": False,
            "protected": False,
        }
        if not self._trusted_root_file(RAM_HELPER_PATH):
            return unavailable
        output = await self._ram_tool("status-json", timeout=10)
        try:
            status = json.loads(output)
        except (TypeError, ValueError) as error:
            raise CommandError("RAM status returned invalid JSON.") from error
        if not isinstance(status, dict):
            raise CommandError("RAM status returned invalid data.")

        integer_fields = (
            "umaLastRequestedMiB",
            "ttmConfiguredPages",
            "ttmBootPages",
            "ttmLivePages",
        )
        if (
            status.get("schemaVersion") != 1
            or status.get("available") is not True
            or status.get("toolState") not in {"verified", "invalid", "not-installed"}
            or status.get("ttmState") not in {"configured", "foreign", "default"}
            or type(status.get("rebootRequired")) is not bool
            or type(status.get("protected")) is not bool
            or any(
                status.get(field) is not None and type(status.get(field)) is not int
                for field in integer_fields
            )
        ):
            raise CommandError("RAM status returned invalid data.")
        version = status.get("toolVersion")
        if version is not None and (
            not isinstance(version, str)
            or re.fullmatch(r"v[0-9][0-9A-Za-z._-]*", version) is None
        ):
            raise CommandError("RAM status returned an invalid tool version.")
        return status

    async def get_hdmi_audio_status(self) -> dict[str, Any]:
        unavailable = {
            "available": False,
            "controllable": False,
            "state": "unavailable",
            "enabled": False,
            "active": False,
            "udevState": "missing",
            "wireplumberState": "missing",
            "persistenceState": "missing",
            "activeProfile": "unknown",
        }
        if not self._hdmi_audio_helper_available():
            return unavailable

        rc, output, error = await self._hdmi_audio_user_exec(
            "status", check=False
        )
        if rc not in {0, 1}:
            raise CommandError(
                (error or output or "HDMI audio status failed.")[-1200:]
            )

        prefix = r"^\[bc250-hdmi-ac3\] "
        patterns = {
            "udevState": prefix + r"udev rule: (installed|missing|foreign)$",
            "wireplumberState": prefix
            + r"WirePlumber config: (installed|missing|foreign)$",
            "persistenceState": prefix
            + r"update persistence: (installed|missing|foreign)$",
            "activeProfile": prefix
            + r"active profile: (unknown|[A-Za-z0-9_.:+-]{1,160})$",
            "state": prefix
            + r"state: (active|configured|not-installed|incomplete)$",
        }
        parsed: dict[str, str] = {}
        for line in output.splitlines():
            for key, pattern in patterns.items():
                match = re.fullmatch(pattern, line)
                if match is not None:
                    if key in parsed:
                        raise CommandError(
                            "HDMI audio status contained duplicate fields."
                        )
                    parsed[key] = match.group(1)
        if set(parsed) != set(patterns):
            raise CommandError("HDMI audio status returned incomplete data.")

        installed = (
            parsed["udevState"] == "installed"
            and parsed["wireplumberState"] == "installed"
            and parsed["persistenceState"] == "installed"
        )
        missing = (
            parsed["udevState"] == "missing"
            and parsed["wireplumberState"] == "missing"
            and parsed["persistenceState"] == "missing"
        )
        if (
            parsed["state"] in {"active", "configured"} and not installed
        ) or (parsed["state"] == "not-installed" and not missing):
            raise CommandError("HDMI audio status was internally inconsistent.")
        if parsed["state"] == "incomplete" and (installed or missing):
            raise CommandError("HDMI audio status was internally inconsistent.")
        if rc == 0 and parsed["state"] not in {"active", "configured"}:
            raise CommandError("HDMI audio status exit code was inconsistent.")
        if rc == 1 and parsed["state"] in {"active", "configured"}:
            raise CommandError("HDMI audio status exit code was inconsistent.")

        return {
            "available": True,
            "controllable": parsed["state"] != "incomplete",
            "state": parsed["state"],
            "enabled": parsed["state"] in {"active", "configured"},
            "active": parsed["state"] == "active",
            "udevState": parsed["udevState"],
            "wireplumberState": parsed["wireplumberState"],
            "persistenceState": parsed["persistenceState"],
            "activeProfile": parsed["activeProfile"],
        }

    async def _get_snapshot(self) -> dict[str, Any]:
        power_available = self._user_script_available("bc250-power.sh")
        cec_available = self._user_script_available("bc250-cec.sh")
        cpu_control_available = self._cpu_helper_available()
        toolkit_available = (
            self._user_script_available("bc250-40cu.sh")
            and power_available
            and cec_available
        )
        cu, power, gpu, cpu, cec, ram, audio = await asyncio.gather(
            self.get_cu_status(),
            self.get_power_status(),
            self.get_gpu_status(),
            self.get_cpu_status(),
            self.get_cec_status(),
            self.get_ram_status(),
            self.get_hdmi_audio_status(),
        )
        return {
            "toolkit": {
                "available": toolkit_available,
                "privileged": os.geteuid() == 0,
                "powerAvailable": power_available,
                "cpuControlAvailable": cpu_control_available,
                "cecAvailable": cec_available,
                "ramControlAvailable": ram["available"],
                "audioAvailable": audio["available"],
                "path": str(self.toolkit),
            },
            "cu": cu,
            "power": power,
            "gpu": gpu,
            "cpu": cpu,
            "cec": cec,
            "ram": ram,
            "audio": audio,
        }

    async def get_snapshot(self) -> dict[str, Any]:
        async with self._mutation_lock:
            async with self._process_lock():
                return await self._get_snapshot()

    async def get_mesh_status(self) -> dict[str, Any]:
        if not self._user_script_available("bc250-mesh-shader.sh"):
            return {
                "scriptAvailable": False,
                "runtimeState": "not-installed",
                "mesaVersion": None,
                "icdPath": str(
                    self.user_home / "radeon_driconf_icd.x86_64.json"
                ),
                "configValid": True,
                "kernelReady": False,
                "schedulerConfigured": False,
                "schedulerActive": False,
                "globalEnabled": False,
                "restartRequired": False,
                "error": None,
                "games": [],
            }

        async with self._mutation_lock:
            async with self._process_lock():
                output = await self._user_tool(
                    "bc250-mesh-shader.sh", "status-json", timeout=30
                )
        try:
            status = json.loads(output)
        except (TypeError, ValueError) as error:
            raise CommandError("Mesa / RADV status returned invalid JSON.") from error
        if not isinstance(status, dict):
            raise CommandError("Mesa / RADV status returned invalid data.")

        runtime_state = status.get("runtimeState")
        games = status.get("games")
        if runtime_state not in {"ready", "not-installed", "invalid"} or not isinstance(
            games, list
        ):
            raise CommandError("Mesa / RADV status returned invalid data.")
        normalized_games = []
        for game in games:
            if not isinstance(game, dict):
                raise CommandError("Mesa / RADV legacy-game status returned invalid data.")
            executable = game.get("executable")
            name = game.get("name")
            if not isinstance(executable, str) or not isinstance(name, str):
                raise CommandError("Mesa / RADV legacy-game status returned invalid data.")
            normalized_games.append({"executable": executable, "name": name})

        mesa_version = status.get("mesaVersion")
        icd_path = status.get("icdPath")
        config_valid = status.get("configValid")
        kernel_ready = status.get("kernelReady", False)
        scheduler_configured = status.get("schedulerConfigured", False)
        scheduler_active = status.get("schedulerActive", False)
        global_enabled = status.get("globalEnabled", False)
        restart_required = status.get("restartRequired", False)
        status_error = status.get("error")
        if mesa_version is not None and not isinstance(mesa_version, str):
            raise CommandError("Mesa / RADV status returned an invalid Mesa version.")
        if (
            not isinstance(icd_path, str)
            or not icd_path.startswith("/")
            or len(icd_path) > 4096
            or not icd_path.isprintable()
        ):
            raise CommandError("Mesa / RADV status returned an invalid ICD path.")
        if type(config_valid) is not bool:
            raise CommandError("Mesa / RADV status returned invalid configuration state.")
        if type(kernel_ready) is not bool:
            raise CommandError("Mesa / RADV status returned invalid kernel state.")
        if type(scheduler_configured) is not bool or type(scheduler_active) is not bool:
            raise CommandError("Mesa / RADV status returned invalid scheduler state.")
        if type(global_enabled) is not bool:
            raise CommandError("Mesa / RADV status returned invalid global state.")
        if type(restart_required) is not bool:
            raise CommandError("Mesa / RADV status returned invalid restart state.")
        if status_error is not None and not isinstance(status_error, str):
            raise CommandError("Mesa / RADV status returned an invalid error message.")
        return {
            "scriptAvailable": True,
            "runtimeState": runtime_state,
            "mesaVersion": mesa_version,
            "icdPath": icd_path,
            "configValid": config_valid,
            "kernelReady": kernel_ready,
            "schedulerConfigured": scheduler_configured,
            "schedulerActive": scheduler_active,
            "globalEnabled": global_enabled,
            "restartRequired": restart_required,
            "error": status_error,
            "games": normalized_games,
        }

    async def _mutate(self, callback: Any) -> Any:
        async with self._mutation_lock:
            async with self._process_lock():
                return await callback()

    async def set_uma_size(self, uma_mib: int) -> dict[str, str]:
        if (
            type(uma_mib) is not int
            or not 256 <= uma_mib <= 12288
            or uma_mib % 16 != 0
            or uma_mib == 2048
        ):
            raise CommandError(
                "UMA size must be 256-12288 MiB, aligned to 16 MiB, and not 2048 MiB."
            )

        async def action() -> dict[str, str]:
            await self._ram_tool("set", str(uma_mib), "--yes", timeout=120)
            return {
                "message": f"CMOS minimum VRAM set to {uma_mib} MiB.",
                "nextStep": "warm-reboot",
            }

        return await self._mutate(action)

    async def set_ttm_pages(self, pages: int) -> dict[str, str]:
        if type(pages) is not int or not 65536 <= pages <= 3145728:
            raise CommandError("TTM limit must be 65536-3145728 pages.")

        async def action() -> dict[str, str]:
            await self._ram_tool("ttm-set", str(pages), "--yes", timeout=120)
            return {
                "message": f"TTM dynamic VRAM limit set to {pages} pages.",
                "nextStep": "warm-reboot",
            }

        return await self._mutate(action)

    async def remove_ttm_override(self) -> dict[str, str]:
        async def action() -> dict[str, str]:
            await self._ram_tool("ttm-remove", timeout=120)
            return {
                "message": "TTM dynamic VRAM override removed.",
                "nextStep": "warm-reboot",
            }

        return await self._mutate(action)

    async def set_mesh_game_enabled(
        self, app_id: int, friendly_name: str, enabled: bool
    ) -> None:
        raise CommandError(
            "Per-game controls were removed; the Mesa / RADV async-compute patch is global."
        )

    async def set_cu_wgp(
        self, se: int, sh: int, wgp: int, enabled: bool
    ) -> None:
        if any(type(value) is not int for value in (se, sh, wgp)):
            raise CommandError("CU routing coordinates must be whole numbers.")
        if se not in {0, 1} or sh not in {0, 1} or wgp not in range(5):
            raise CommandError("CU routing coordinates are out of range.")
        if type(enabled) is not bool:
            raise CommandError("CU routing state must be a boolean.")

        async def action() -> None:
            if not self._bc250_present():
                raise CommandError("BC-250 GPU was not detected; refusing register writes.")
            umr = self._trusted_umr()
            manager = self._trusted_cu_manager()
            if umr is None or manager is None:
                raise CommandError(
                    "A root-owned UMR and CU manager installation is required."
                )
            if await self._umr_register(
                "mmSPI_PG_ENABLE_STATIC_WGP_MASK", se, sh
            ) is None:
                raise CommandError(
                    "UMR could not verify the live routing register; no change was made."
                )
            factory_masks = await self._factory_cu_masks()
            if factory_masks is None:
                raise CommandError(
                    "The factory 24-CU map is unavailable; no change was made."
                )
            factory_mask = factory_masks[se * 2 + sh]
            if factory_mask & (0x3 << (wgp * 2)):
                raise CommandError("Factory-enabled CUs are locked and cannot be changed.")

            config = self._read_key_values(CU_CONFIG_PATH)
            asic = config.get("UMR_ASIC", "cyan_skillfish.gfx1013")
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", asic):
                raise CommandError("The configured UMR ASIC selector is invalid.")
            env = {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": "/root",
                "USER": "root",
                "LOGNAME": "root",
                "UMR": str(umr),
                "UMR_ASIC": asic,
            }
            database = self._trusted_umr_database(umr)
            if database is not None:
                env["UMR_DATABASE_PATH"] = str(database)
            instance = self._umr_instance()
            if instance is not None:
                env["UMR_INSTANCE"] = str(instance)
            command = "enable-wgp" if enabled else "disable-wgp"
            await self._exec(
                [str(manager), "--yes", command, f"{se}.{sh}.{wgp}"],
                timeout=30,
                env=env,
            )

        return await self._mutate(action)

    async def set_gpu_frequency(
        self, mode: str, minimum: int, maximum: int
    ) -> None:
        if type(mode) is not str or mode not in {"adaptive", "max", "pin", "range"}:
            raise CommandError("Unknown GPU frequency mode.")
        if type(minimum) is not int or type(maximum) is not int:
            raise CommandError("GPU frequencies must be whole numbers.")
        if mode == "pin" and not 300 <= maximum <= 2230:
            raise CommandError("Pinned frequency must be 300-2230 MHz.")
        if mode == "range":
            if (minimum != 0 and not 300 <= minimum <= 2230) or not 300 <= maximum <= 2230:
                raise CommandError(
                    "Frequency range must use 0 for no floor or stay within 300-2230 MHz."
                )
            if minimum and minimum > maximum:
                raise CommandError("Minimum frequency exceeds maximum frequency.")

        async def action() -> None:
            state_path = GPU_STATE_PATH
            if state_path.is_symlink() or (
                state_path.exists() and not state_path.is_file()
            ):
                raise CommandError(f"GPU frequency state is unsafe: {state_path}")
            previous = (
                state_path.read_text(encoding="utf-8") if state_path.exists() else None
            )
            previous_values = self._read_key_values(state_path)
            previous_mode = previous_values.get("MODE", "adaptive")
            previous_first = self._safe_int(previous_values.get("A"))
            previous_second = self._safe_int(previous_values.get("B"))

            first = maximum if mode == "pin" else minimum if mode == "range" else 0
            second = maximum if mode == "range" else 0
            self._write_frequency_state(mode, first, second)
            try:
                await self._apply_frequency(mode, first, second)
            except BaseException as error:
                async def rollback() -> None:
                    if previous is None:
                        self._write_frequency_state("adaptive")
                    else:
                        self._atomic_write(state_path, previous)
                    await self._apply_frequency(
                        previous_mode, previous_first, previous_second
                    )

                rollback_task = asyncio.ensure_future(rollback())
                try:
                    await asyncio.shield(rollback_task)
                except asyncio.CancelledError:
                    await rollback_task
                except Exception as rollback_error:
                    raise CommandError(
                        f"{error}; frequency rollback failed: {rollback_error}"
                    ) from error
                raise error

        return await self._mutate(action)

    async def set_load_target(self, preset: str) -> None:
        if type(preset) is not str or preset not in {"eager", "reset"}:
            raise CommandError("Unknown load-target preset.")

        async def action() -> None:
            upper, lower = (0.40, 0.10) if preset == "eager" else (0.80, 0.65)

            async def apply_live() -> None:
                await self._gpu_call(
                    "SetLoadTarget", "dd", f"{lower:.2f}", f"{upper:.2f}"
                )

            await self._update_gpu_config(
                {"load-target": {"upper": f"{upper:.2f}", "lower": f"{lower:.2f}"}},
                live_callback=apply_live,
            )

        return await self._mutate(action)

    async def set_custom_load_target(self, minimum: int, maximum: int) -> None:
        if type(minimum) is not int or type(maximum) is not int:
            raise CommandError("GPU load targets must be whole percentages.")
        if not 0 < minimum < maximum < 100:
            raise CommandError(
                "Minimum GPU load must be below maximum load and both must be 1-99%."
            )

        async def action() -> None:
            lower = minimum / 100
            upper = maximum / 100

            async def apply_live() -> None:
                await self._gpu_call(
                    "SetLoadTarget", "dd", f"{lower:.2f}", f"{upper:.2f}"
                )

            await self._update_gpu_config(
                {"load-target": {"upper": f"{upper:.2f}", "lower": f"{lower:.2f}"}},
                live_callback=apply_live,
            )

        return await self._mutate(action)

    async def set_ramp(self, climb_ms: int) -> None:
        if type(climb_ms) is not int or not 200 <= climb_ms <= 5000:
            raise CommandError("Ramp time must be a whole number from 200-5000 ms.")

        async def action() -> None:
            config = self._read_toml(GPU_CONFIG_PATH)
            frequency = config.get("frequency-range", {})
            load = config.get("load-target", {})
            allowed_min, allowed_max = await asyncio.gather(
                self._system_bus_property(
                    "/com/cyanskillfish/Governor/Range/Allowed",
                    "com.cyanskillfish.Governor.Range",
                    "Min",
                ),
                self._system_bus_property(
                    "/com/cyanskillfish/Governor/Range/Allowed",
                    "com.cyanskillfish.Governor.Range",
                    "Max",
                ),
            )
            configured_min = (
                self._number(frequency.get("min"))
                if isinstance(frequency, dict)
                else None
            )
            configured_max = (
                self._number(frequency.get("max"))
                if isinstance(frequency, dict)
                else None
            )
            minimum = max(configured_min or allowed_min or 500, allowed_min or 0)
            maximum = min(configured_max or allowed_max or 2200, allowed_max or 9999)
            if maximum <= minimum:
                raise CommandError("GPU operating range is invalid.")
            upper = self._number(load.get("upper")) if isinstance(load, dict) else None
            lower = self._number(load.get("lower")) if isinstance(load, dict) else None
            upper = float(upper if upper is not None else 0.80)
            lower = float(lower if lower is not None else 0.65)
            if not 0 < lower < upper < 1:
                raise CommandError("GPU load targets are invalid.")
            span = maximum - minimum
            normal = span / climb_ms
            ceiling = minimum * (upper - lower) / upper
            step = max(30.0, 0.7 * ceiling)
            adjust_ms = max(50, min(200, round(step / normal)))
            actual_step = normal * adjust_ms
            if actual_step > ceiling >= 30:
                actual_step = ceiling
                normal = actual_step / adjust_ms
            down_events = max(2, round(1000 / adjust_ms))
            timing = config.get("timing", {})
            rates = (
                timing.get("ramp-rates", {}) if isinstance(timing, dict) else {}
            )
            burst_value = (
                self._number(rates.get("burst"))
                if isinstance(rates, dict)
                else None
            )
            burst = float(burst_value if burst_value is not None else 50)
            if burst <= normal:
                burst = 200 * normal
            await self._update_gpu_config(
                {
                    "timing.intervals": {"adjust": str(adjust_ms * 1000)},
                    "timing.ramp-rates": {
                        "normal": f"{normal:.3g}",
                        "burst": f"{burst:.3g}",
                    },
                    "timing": {"down-events": str(down_events)},
                },
                restart=True,
            )

        return await self._mutate(action)

    async def cpu_oc_action(
        self, action_name: str, frequency: int, voltage: int, temperature: int
    ) -> None:
        if type(action_name) is not str or action_name not in {
            "detect",
            "apply",
            "enable",
            "off",
        }:
            raise CommandError("Unknown CPU overclock action.")
        if action_name == "detect":
            if any(
                type(value) is not int
                for value in (frequency, voltage, temperature)
            ):
                raise CommandError("CPU tuning values must be whole numbers.")
            if not 3500 <= frequency <= 4500:
                raise CommandError("CPU target must be between 3500 and 4500 MHz.")
            if not 950 <= voltage <= 1325:
                raise CommandError("CPU VID limit must be between 950 and 1325 mV.")
            if not 50 <= temperature <= 100:
                raise CommandError(
                    "CPU temperature limit must be between 50 and 100 C."
                )

        async def action() -> None:
            args = ["cpu-oc", action_name]
            if action_name == "detect":
                args.extend((str(frequency), str(voltage), str(temperature)))
            await self._cpu_tool(
                *args,
                timeout=1800 if action_name == "detect" else 180,
            )

        return await self._mutate(action)

    async def set_cpu_mitigations(self, enabled: bool) -> None:
        if type(enabled) is not bool:
            raise CommandError("CPU mitigations state must be a boolean.")

        async def action() -> None:
            await self._cpu_tool(
                "cpu-mitigations", "enable" if enabled else "disable", timeout=180
            )

        return await self._mutate(action)

    async def set_hdmi_surround(self, enabled: bool) -> None:
        if type(enabled) is not bool:
            raise CommandError("HDMI surround state must be a boolean.")

        async def action() -> None:
            status = await self.get_hdmi_audio_status()
            state = status["state"]
            if not status["controllable"]:
                raise CommandError(
                    "HDMI audio configuration is incomplete; repair it from the toolkit."
                )
            if enabled:
                if state == "active":
                    return
                if state == "configured":
                    await self._hdmi_audio_user_exec("install-user")
                    return
                await self._hdmi_audio_root_exec("install-system")
                try:
                    await self._hdmi_audio_user_exec("install-user")
                except BaseException as error:
                    rollback_task = asyncio.ensure_future(
                        self._hdmi_audio_root_exec("remove-system")
                    )
                    try:
                        await asyncio.shield(rollback_task)
                    except asyncio.CancelledError:
                        await rollback_task
                        raise
                    except Exception as rollback_error:
                        raise CommandError(
                            f"{error}; HDMI audio rollback failed: {rollback_error}"
                        ) from error
                    raise
                return
            if state == "not-installed":
                return
            await self._hdmi_audio_root_exec("remove-system")
            try:
                await self._hdmi_audio_user_exec("revert-user")
            except BaseException as error:
                rollback_task = asyncio.ensure_future(
                    self._hdmi_audio_root_exec("install-system")
                )
                try:
                    await asyncio.shield(rollback_task)
                except asyncio.CancelledError:
                    await rollback_task
                    raise
                except Exception as rollback_error:
                    raise CommandError(
                        f"{error}; HDMI audio rollback failed: {rollback_error}"
                    ) from error
                raise

        return await self._mutate(action)

    async def cpu_unlock_action(self, action_name: str) -> dict[str, Any]:
        if type(action_name) is not str or action_name not in {
            "test",
            "enable",
            "efi-enable",
            "off",
        }:
            raise CommandError("Unknown CPU core-unlock action.")

        async def action() -> dict[str, Any]:
            payload_available = (
                self._cpu_unlock_off_payload_available()
                if action_name == "off"
                else self._cpu_unlock_payload_available()
            )
            if not payload_available:
                raise CommandError(
                    "CPU core-unlock helper bundle is missing or unsafe; reinstall the service."
                )
            if action_name == "off":
                try:
                    physical_cores = self._cpu_topology()["physicalCores"]
                except Exception:
                    physical_cores = None
            else:
                physical_cores = self._cpu_topology()["physicalCores"]
            env = {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": "/root",
                "USER": "root",
                "LOGNAME": "root",
                "BC250_STORAGE_SKIP_LEGACY_AIC": "1",
            }
            await self._exec(
                [
                    BASH,
                    str(CPU_UNLOCK_PAYLOAD_PATH / "bc250-power.sh"),
                    "cpu-unlock",
                    action_name,
                ],
                timeout=1800 if action_name == "efi-enable" else 180,
                env=env,
            )
            if action_name == "test" and physical_cores == 6:
                next_step = "warm-reboot"
            elif action_name == "off" and physical_cores == 8:
                next_step = "full-power-off"
            else:
                next_step = "none"
            return {"action": action_name, "nextStep": next_step}

        return await self._mutate(action)

    async def cec_action(self, action_name: str) -> None:
        if type(action_name) is not str or action_name not in {
            "tv-on",
            "tv-off",
            "amp-on",
            "amp-off",
            "switch",
            "release",
            "vol-up",
            "vol-down",
            "mute",
        }:
            raise CommandError("Unknown CEC action.")

        async def action() -> None:
            await self._user_tool("bc250-cec.sh", action_name, timeout=15)

        return await self._mutate(action)

    async def set_cec_toggle(self, key: str, enabled: bool) -> None:
        if type(key) is not str or key not in {
            "wake-tv",
            "suspend-tv",
            "allow-standby",
            "uinput",
        }:
            raise CommandError("Unknown CEC toggle.")
        if type(enabled) is not bool:
            raise CommandError("CEC toggle state must be a boolean.")

        async def action() -> None:
            await self._user_tool(
                "bc250-cec.sh",
                "toggle",
                key,
                "on" if enabled else "off",
                timeout=20,
            )
            if key == "uinput":
                await self._user_exec(
                    [SYSTEMCTL, "--user", "restart", "cecd.service"],
                    timeout=10,
                )

        return await self._mutate(action)

    async def set_cec_name(self, name: str) -> None:
        if type(name) is not str:
            raise CommandError("CEC broadcast name must be text.")
        try:
            byte_length = len(name.encode("utf-8"))
        except UnicodeEncodeError as error:
            raise CommandError("CEC broadcast name contains invalid text.") from error
        if not name.strip() or byte_length > 14:
            raise CommandError("CEC broadcast name must be 1-14 bytes.")
        if not name.isprintable() or '"' in name or "\\" in name:
            raise CommandError(
                "CEC broadcast name cannot contain control characters, quotes, or backslashes."
            )

        async def action() -> None:
            await self._user_tool("bc250-cec.sh", "osd-name", name, timeout=20)

        return await self._mutate(action)
