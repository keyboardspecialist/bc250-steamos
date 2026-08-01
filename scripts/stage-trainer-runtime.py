#!/usr/bin/env python3
"""Build a self-contained, deterministic BC250 Trainer archive."""

import argparse
import hashlib
import os
import shutil
import stat
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Iterable


REPOSITORY = Path(__file__).resolve().parent.parent
TRAINER_SOURCE = REPOSITORY / "trainer"
DESKTOP_SOURCE = REPOSITORY / "desktop-control"
BACKEND_SOURCE = REPOSITORY / "backend"
DEFAULT_OUTPUT = TRAINER_SOURCE / "out"
DEFAULT_EPOCH = 315532800
ARCHIVE_ROOT = "bc250-trainer"
CORE_UNLOCK_FILES = (
    "bc250-unlock-cores.py",
    "bc250-unlock-cores-efi.c",
    "EFI-LICENSE",
    "EFI-HEADERS-LICENSE",
    "LICENSE",
    "README.md",
)
EXECUTABLES = {
    Path("bc250-storage.sh"),
    Path("bc250-update-persistence.sh"),
    Path("bc250-power.sh"),
    Path("bc250-ram-split.sh"),
    Path("topology.sh"),
    Path("core-unlock/bc250-unlock-cores.py"),
    Path("trainer/install.sh"),
    Path("trainer/install-flatpak.sh"),
    Path("trainer/bc250-trainer"),
    Path("desktop-control/shared-service-install.sh"),
    Path("desktop-control/bc250-desktop-control-repair"),
    Path("desktop-control/service/bc250-control-service"),
}


def source_date_epoch() -> int:
    value = os.environ.get("SOURCE_DATE_EPOCH", str(DEFAULT_EPOCH))
    try:
        epoch = int(value)
    except ValueError as error:
        raise SystemExit("SOURCE_DATE_EPOCH must be an integer") from error
    return max(epoch, DEFAULT_EPOCH)


def copy_file(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise SystemExit("required runtime file is missing or unsafe: {}".format(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(str(source), str(destination))


def copy_tree(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise SystemExit("required runtime directory is missing or unsafe: {}".format(source))
    destination.mkdir(parents=True, exist_ok=True)
    for child in sorted(source.iterdir(), key=lambda path: path.name):
        if child.name in {".DS_Store", "__pycache__", "out"} or child.suffix in {".pyc", ".pyo"}:
            continue
        target = destination / child.name
        if child.is_symlink():
            raise SystemExit("runtime sources cannot contain symlinks: {}".format(child))
        if child.is_dir():
            copy_tree(child, target)
        elif child.is_file():
            copy_file(child, target)
        else:
            raise SystemExit("runtime source has an unsupported node: {}".format(child))


def normalize_tree(root: Path, epoch: int) -> None:
    for path in sorted(root.rglob("*"), key=lambda item: str(item), reverse=True):
        relative = path.relative_to(root)
        path.chmod(0o755 if path.is_dir() or relative in EXECUTABLES else 0o644)
        os.utime(str(path), (epoch, epoch), follow_symlinks=False)
    root.chmod(0o755)
    os.utime(str(root), (epoch, epoch), follow_symlinks=False)


def copy_host_runtime(temporary: Path) -> None:
    for name in ("bc250-storage.sh", "bc250-update-persistence.sh", "bc250-power.sh", "bc250-ram-split.sh", "topology.sh"):
        copy_file(REPOSITORY / name, temporary / name)
    for name in CORE_UNLOCK_FILES:
        copy_file(
            REPOSITORY / "core-unlock" / name,
            temporary / "core-unlock" / name,
        )
    for name in ("shared-service-install.sh", "bc250-desktop-control-repair"):
        copy_file(DESKTOP_SOURCE / name, temporary / "desktop-control" / name)
    copy_tree(DESKTOP_SOURCE / "templates", temporary / "desktop-control/templates")
    copy_tree(DESKTOP_SOURCE / "vendor", temporary / "desktop-control/vendor")
    service = DESKTOP_SOURCE / "service"
    for name in ("bc250-control-service", "io.github.keyboardspecialist.bc250-control.policy"):
        copy_file(service / name, temporary / "desktop-control/service" / name)
    copy_tree(service / "bc250_control_service", temporary / "desktop-control/service/bc250_control_service")
    copy_tree(BACKEND_SOURCE / "bc250_control", temporary / "backend/bc250_control")
    copy_tree(BACKEND_SOURCE / "vendor", temporary / "backend/vendor")


def commit_runtime(temporary: Path, output: Path, epoch: int) -> None:
    normalize_tree(temporary, epoch)
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise SystemExit("refusing to replace unsafe output: {}".format(output))
        shutil.rmtree(str(output))
    os.replace(str(temporary), str(output))


def stage_native(binary: Path, output: Path, epoch: int) -> None:
    if binary.is_symlink():
        raise SystemExit("BC250 Trainer binary is missing, unsafe, or not executable: {}".format(binary))
    binary = binary.resolve()
    if not binary.is_file() or not os.access(str(binary), os.X_OK):
        raise SystemExit("BC250 Trainer binary is missing, unsafe, or not executable: {}".format(binary))
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".trainer-runtime-", dir=str(output.parent)))
    try:
        copy_host_runtime(temporary)
        copy_file(TRAINER_SOURCE / "install.sh", temporary / "trainer/install.sh")
        copy_file(binary, temporary / "trainer/bc250-trainer")
        copy_tree(TRAINER_SOURCE / "packaging", temporary / "trainer/packaging")
        copy_tree(TRAINER_SOURCE / "tracks", temporary / "trainer/tracks")
        for optional in ("README.md", "ASSETS.md", "ASSET-LICENSE"):
            source = TRAINER_SOURCE / optional
            if source.is_file() and not source.is_symlink():
                copy_file(source, temporary / "trainer" / optional)

        commit_runtime(temporary, output, epoch)
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))


def stage_flatpak(bundle: Path, output: Path, epoch: int) -> None:
    if bundle.is_symlink():
        raise SystemExit("Flatpak bundle is missing or unsafe: {}".format(bundle))
    bundle = bundle.resolve()
    if not bundle.is_file():
        raise SystemExit("Flatpak bundle is missing or unsafe: {}".format(bundle))
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".trainer-flatpak-runtime-", dir=str(output.parent)))
    try:
        copy_host_runtime(temporary)
        copy_file(TRAINER_SOURCE / "install-flatpak.sh", temporary / "trainer/install-flatpak.sh")
        copy_file(TRAINER_SOURCE / "install.sh", temporary / "trainer/install.sh")
        copy_file(
            bundle,
            temporary / "trainer/io.github.keyboardspecialist.bc250trainer.flatpak",
        )
        for optional in ("README.md", "ASSETS.md", "ASSET-LICENSE"):
            source = TRAINER_SOURCE / optional
            if source.is_file() and not source.is_symlink():
                copy_file(source, temporary / "trainer" / optional)
        commit_runtime(temporary, output, epoch)
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))


def archive_paths(root: Path) -> Iterable[Path]:
    yield root
    yield from sorted(root.rglob("*"), key=lambda item: item.as_posix())


def write_archive(runtime: Path, archive: Path, epoch: int, archive_root: str) -> None:
    timestamp = time.gmtime(epoch)[:6]
    archive = archive.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".{}-".format(archive.name), dir=str(archive.parent))
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary_name, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as stream:
            for path in archive_paths(runtime):
                relative = path.relative_to(runtime)
                name = archive_root if relative == Path(".") else "{}/{}".format(archive_root, relative.as_posix())
                if path.is_dir():
                    name += "/"
                info = zipfile.ZipInfo(name, timestamp)
                info.create_system = 3
                mode = stat.S_IFDIR | 0o755 if path.is_dir() else stat.S_IFREG | (path.stat().st_mode & 0o777)
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                stream.writestr(info, b"" if path.is_dir() else path.read_bytes())
        os.replace(temporary_name, str(archive))
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def write_checksum(archive: Path, checksum: Path) -> None:
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum.parent.mkdir(parents=True, exist_ok=True)
    checksum.write_text("{}  {}\n".format(digest, archive.name), encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--binary", type=Path)
    source.add_argument("--flatpak", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--sha256", type=Path)
    arguments = parser.parse_args()
    if arguments.sha256 is not None and arguments.archive is None:
        parser.error("--sha256 requires --archive")

    epoch = source_date_epoch()
    if arguments.binary is not None:
        stage_native(arguments.binary, arguments.output, epoch)
        archive_root = ARCHIVE_ROOT
    else:
        stage_flatpak(arguments.flatpak, arguments.output, epoch)
        archive_root = "bc250-trainer-flatpak-installer"
    if arguments.archive is not None:
        write_archive(arguments.output.resolve(), arguments.archive, epoch, archive_root)
        if arguments.sha256 is not None:
            write_checksum(arguments.archive.resolve(), arguments.sha256.resolve())


if __name__ == "__main__":
    main()
