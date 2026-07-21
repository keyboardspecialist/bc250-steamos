#!/usr/bin/env python3
"""Build a self-contained, deterministic Decky runtime tree."""

import argparse
import json
import os
import shutil
import stat
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Iterable


REPOSITORY = Path(__file__).resolve().parent.parent
PLUGIN_SOURCE = REPOSITORY / "decky-plugin"
BACKEND_SOURCE = REPOSITORY / "backend"
DEFAULT_OUTPUT = PLUGIN_SOURCE / "out"
DEFAULT_EPOCH = 315532800  # 1980-01-01, the earliest timestamp supported by ZIP.


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
    destination.chmod(0o644)


def copy_tree(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise SystemExit("required runtime directory is missing or unsafe: {}".format(source))
    destination.mkdir(parents=True, exist_ok=True)
    for child in sorted(source.iterdir(), key=lambda path: path.name):
        if child.name == "__pycache__" or child.suffix in {".pyc", ".pyo"}:
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
    paths = sorted(root.rglob("*"), key=lambda path: str(path), reverse=True)
    for path in paths:
        path.chmod(0o755 if path.is_dir() else 0o644)
        os.utime(str(path), (epoch, epoch), follow_symlinks=False)
    root.chmod(0o755)
    os.utime(str(root), (epoch, epoch), follow_symlinks=False)


def stage(output: Path, epoch: int) -> None:
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".decky-runtime-", dir=str(output.parent)))
    try:
        for name in ("LICENSE", "main.py", "package.json", "plugin.json"):
            copy_file(PLUGIN_SOURCE / name, temporary / name)
        copy_file(PLUGIN_SOURCE / "dist/index.js", temporary / "dist/index.js")
        copy_tree(
            BACKEND_SOURCE / "bc250_control",
            temporary / "py_modules/bc250_control",
        )
        copy_tree(BACKEND_SOURCE / "vendor/tomli", temporary / "py_modules/tomli")
        copy_tree(
            BACKEND_SOURCE / "vendor/tomli-2.0.1.dist-info",
            temporary / "py_modules/tomli-2.0.1.dist-info",
        )
        normalize_tree(temporary, epoch)
        if output.exists():
            if output.is_symlink() or not output.is_dir():
                raise SystemExit("refusing to replace unsafe output: {}".format(output))
            shutil.rmtree(str(output))
        os.replace(str(temporary), str(output))
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))


def archive_paths(root: Path) -> Iterable[Path]:
    yield root
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        yield path


def write_archive(runtime: Path, archive: Path, epoch: int) -> None:
    plugin_name = json.loads((runtime / "plugin.json").read_text(encoding="utf-8"))["name"]
    timestamp = time.gmtime(epoch)[:6]
    archive = archive.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".{}-".format(archive.name), dir=str(archive.parent)
    )
    os.close(descriptor)
    try:
        with zipfile.ZipFile(
            temporary_name,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as stream:
            for path in archive_paths(runtime):
                relative = path.relative_to(runtime)
                name = plugin_name if relative == Path(".") else "{}/{}".format(
                    plugin_name, relative.as_posix()
                )
                if path.is_dir():
                    name += "/"
                info = zipfile.ZipInfo(name, timestamp)
                info.create_system = 3
                mode = stat.S_IFDIR | 0o755 if path.is_dir() else stat.S_IFREG | 0o644
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                content = b"" if path.is_dir() else path.read_bytes()
                stream.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED)
        os.replace(temporary_name, str(archive))
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--archive", type=Path)
    arguments = parser.parse_args()

    epoch = source_date_epoch()
    stage(arguments.output, epoch)
    if arguments.archive is not None:
        write_archive(arguments.output.resolve(), arguments.archive, epoch)


if __name__ == "__main__":
    main()
