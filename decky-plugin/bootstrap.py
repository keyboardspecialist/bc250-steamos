from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple

from bc250_control import ToolkitBackend


ROOT_HELPER_DIR = Path("/var/lib/bc250-control/helper")
INSTALL_MARKER = Path(".decky-helper-manifest")
PAYLOAD_FILES: Tuple[Tuple[Path, int], ...] = (
    (Path("bc250-storage.sh"), 0o755),
    (Path("bc250-update-persistence.sh"), 0o755),
    (Path("acpi-tables/SSDT-CST.dsl"), 0o644),
    (Path("acpi-tables/SSDT-PST.dsl"), 0o644),
    (Path("smu-oc-patches/0001-transaction-level-flock.patch"), 0o644),
    (Path("smu-oc-patches/0002-steamos-stress-fallback.patch"), 0o644),
    (Path("smu-oc-patches/README.md"), 0o644),
    (Path("smu-oc-patches/stress_helper.py"), 0o644),
    (Path("smu-oc-patches/transport.py"), 0o644),
    (Path("core-unlock/bc250-unlock-cores.py"), 0o644),
    (Path("core-unlock/bc250-unlock-cores-efi.c"), 0o644),
    (Path("core-unlock/EFI-LICENSE"), 0o644),
    (Path("core-unlock/EFI-HEADERS-LICENSE"), 0o644),
    (Path("core-unlock/LICENSE"), 0o644),
    (Path("core-unlock/README.md"), 0o644),
    (Path("topology.sh"), 0o755),
    (Path("bc250-power.sh"), 0o755),
)


def _payload_contents(payload_dir: Path) -> Dict[Path, bytes]:
    try:
        if not stat.S_ISDIR(payload_dir.lstat().st_mode):
            raise RuntimeError("privileged helper payload is not a real directory")
    except OSError as error:
        raise RuntimeError("privileged helper payload is missing") from error

    contents = {}
    checked_directories = {payload_dir}
    for relative, _ in PAYLOAD_FILES:
        source = payload_dir / relative
        for parent in source.parents:
            if parent == payload_dir.parent:
                break
            if parent in checked_directories:
                continue
            try:
                if not stat.S_ISDIR(parent.lstat().st_mode):
                    raise RuntimeError(f"unsafe payload directory: {parent}")
            except OSError as error:
                raise RuntimeError(f"payload directory is missing: {parent}") from error
            checked_directories.add(parent)
        try:
            metadata = source.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeError(f"unsafe payload file: {source}")
            contents[relative] = source.read_bytes()
        except OSError as error:
            raise RuntimeError(f"payload file is missing: {source}") from error
    return contents


def _manifest_content(contents: Dict[Path, bytes]) -> bytes:
    digest = hashlib.sha256()
    for relative, mode in PAYLOAD_FILES:
        digest.update(f"{relative.as_posix()} {mode:o}\0".encode("ascii"))
        digest.update(hashlib.sha256(contents[relative]).digest())
    return f"decky-helper-v1 {digest.hexdigest()}\n".encode("ascii")


def _installed_current(
    helper_dir: Path, contents: Dict[Path, bytes]
) -> bool:
    directories = {helper_dir}
    directories.update(
        helper_dir / relative.parent
        for relative, _ in PAYLOAD_FILES
        if relative.parent != Path(".")
    )
    if not all(
        ToolkitBackend._trusted_root_directory(directory)
        for directory in directories
    ):
        return False
    marker = helper_dir / INSTALL_MARKER
    if not ToolkitBackend._trusted_root_file(marker):
        return False
    try:
        if marker.stat().st_mode & 0o777 != 0o644:
            return False
        if marker.read_bytes() != _manifest_content(contents):
            return False
    except OSError:
        return False
    for relative, mode in PAYLOAD_FILES:
        destination = helper_dir / relative
        if not ToolkitBackend._trusted_root_file(destination):
            return False
        try:
            if destination.stat().st_mode & 0o777 != mode:
                return False
            if destination.read_bytes() != contents[relative]:
                return False
        except OSError:
            return False
    return True


def _sync_directory(path: Path) -> None:
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _run_storage_installer(source: Path) -> None:
    subprocess.run(
        ["/usr/bin/bash", str(source), "install"],
        check=True,
        timeout=120,
        env={
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
            "BC250_STORAGE_SKIP_LEGACY_AIC": "1",
        },
    )


def _atomic_install(destination: Path, content: bytes, mode: int) -> None:
    if os.path.lexists(str(destination)):
        metadata = destination.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f"refusing to replace unsafe helper: {destination}")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=str(destination.parent)
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary_name, str(destination))
        _sync_directory(destination.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def install_privileged_helper(
    payload_dir: Optional[Path] = None,
    helper_dir: Path = ROOT_HELPER_DIR,
    storage_installer: Optional[Callable[[Path], None]] = None,
) -> bool:
    if os.geteuid() != 0:
        raise RuntimeError("privileged helper installation requires root")
    if payload_dir is None:
        payload_dir = Path(__file__).resolve().parent.parent / "privileged-helper"
    contents = _payload_contents(payload_dir)
    if _installed_current(helper_dir, contents):
        return False

    marker = helper_dir / INSTALL_MARKER
    if os.path.lexists(str(marker)):
        if not ToolkitBackend._trusted_root_directory(helper_dir):
            raise RuntimeError("privileged helper directory is unsafe")
        if not stat.S_ISREG(marker.lstat().st_mode):
            raise RuntimeError(f"refusing to replace unsafe helper marker: {marker}")
        marker.unlink()
        _sync_directory(helper_dir)

    installer = storage_installer or _run_storage_installer
    installer(payload_dir / "bc250-storage.sh")
    helper_parent = helper_dir.parent
    if not helper_parent.exists():
        if not ToolkitBackend._trusted_root_directory(helper_parent.parent):
            raise RuntimeError("privileged storage parent is unsafe")
        helper_parent.mkdir(mode=0o755)
        helper_parent.chmod(0o755)
        _sync_directory(helper_parent)
        _sync_directory(helper_parent.parent)
    if not ToolkitBackend._trusted_root_directory(helper_parent):
        raise RuntimeError("privileged storage root is missing or unsafe")

    directories = sorted(
        {
            helper_dir,
            *(
                helper_dir / relative.parent
                for relative, _ in PAYLOAD_FILES
                if relative.parent != Path(".")
            ),
        },
        key=lambda path: len(path.parts),
    )
    for directory in directories:
        if not directory.exists():
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
            _sync_directory(directory)
            _sync_directory(directory.parent)
        if not ToolkitBackend._trusted_root_directory(directory):
            raise RuntimeError(f"privileged helper directory is unsafe: {directory}")

    try:
        for relative, mode in PAYLOAD_FILES:
            _atomic_install(helper_dir / relative, contents[relative], mode)
        _atomic_install(marker, _manifest_content(contents), 0o644)
        if not _installed_current(helper_dir, contents):
            raise RuntimeError("privileged helper installation could not be verified")
    except Exception:
        if os.path.lexists(str(marker)) and stat.S_ISREG(marker.lstat().st_mode):
            marker.unlink()
            _sync_directory(helper_dir)
        raise
    return True
