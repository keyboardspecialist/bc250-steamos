#!/usr/bin/env python3
"""Check for and atomically install BC-250 SteamOS toolkit releases."""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


REPOSITORY = "keyboardspecialist/bc250-steamos"
RELEASES_API = "https://api.github.com/repos/{}/releases".format(REPOSITORY)
DOWNLOAD_ROOT = "https://github.com/{}/releases/download".format(REPOSITORY)
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SHA256_PATTERN = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)\n?")
ARCHIVE_ROOT = "bc250-steamos"
MAX_API_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_BYTES = 768 * 1024 * 1024
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 20000


class UpdateError(RuntimeError):
    pass


def version_tuple(version):
    match = TAG_PATTERN.fullmatch(version)
    if match is None:
        raise UpdateError("Toolkit version must use vMAJOR.MINOR.PATCH format")
    return tuple(int(value) for value in match.groups())


def request_headers(api=False):
    headers = {
        "Accept": "application/vnd.github+json" if api else "application/octet-stream",
        "User-Agent": "bc250-trainer-toolkit-updater/1",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if api and token:
        headers["Authorization"] = "Bearer {}".format(token)
    return headers


def read_limited(response, limit):
    chunks = []
    total = 0
    while True:
        chunk = response.read(min(1024 * 1024, limit - total + 1))
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise UpdateError("GitHub response exceeded the safety limit")
        chunks.append(chunk)


def fetch_release_page(page):
    query = urllib.parse.urlencode({"per_page": 100, "page": page})
    request = urllib.request.Request(
        "{}?{}".format(RELEASES_API, query), headers=request_headers(api=True)
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = read_limited(response, MAX_API_BYTES)
    except (OSError, urllib.error.URLError) as error:
        raise UpdateError("Could not query GitHub releases: {}".format(error)) from error
    try:
        releases = json.loads(payload.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise UpdateError("GitHub returned invalid release metadata") from error
    if not isinstance(releases, list):
        raise UpdateError("GitHub returned unexpected release metadata")
    return releases


def fetch_releases():
    releases = []
    for page in range(1, 101):
        batch = fetch_release_page(page)
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise UpdateError("GitHub release pagination exceeded the safety limit")


def select_release(releases):
    candidates = []
    for release in releases:
        if (
            not isinstance(release, dict)
            or release.get("draft") is True
            or release.get("prerelease") is True
        ):
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or TAG_PATTERN.fullmatch(tag) is None:
            continue
        candidates.append((version_tuple(tag), release))
    if not candidates:
        raise UpdateError("No published vMAJOR.MINOR.PATCH toolkit release was found")
    return max(candidates, key=lambda candidate: candidate[0])[1]


def expected_asset_url(tag, name):
    return "{}/{}/{}".format(
        DOWNLOAD_ROOT,
        urllib.parse.quote(tag, safe=""),
        urllib.parse.quote(name, safe=""),
    )


def select_asset(release, name, maximum_size):
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise UpdateError("Toolkit release has no asset list")
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
    if len(matches) != 1:
        raise UpdateError("Toolkit release must contain exactly one {} asset".format(name))
    asset = matches[0]
    size = asset.get("size")
    url = asset.get("browser_download_url")
    if (
        not isinstance(size, int)
        or isinstance(size, bool)
        or size <= 0
        or size > maximum_size
    ):
        raise UpdateError("Toolkit release asset has an invalid size: {}".format(name))
    if asset.get("state") != "uploaded" or url != expected_asset_url(release["tag_name"], name):
        raise UpdateError("Toolkit release asset metadata is invalid: {}".format(name))
    digest = asset.get("digest")
    if digest is not None and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise UpdateError("Toolkit release asset digest is invalid: {}".format(name))
    return asset


def select_release_assets(release):
    archive_name = "bc250-steamos-toolkit-{}.zip".format(release["tag_name"])
    archive = select_asset(release, archive_name, MAX_ARCHIVE_BYTES)
    checksum = select_asset(release, archive_name + ".sha256", 4096)
    return archive, checksum


def read_current_version(toolkit_directory):
    directory = Path(toolkit_directory)
    if not directory.is_absolute() or directory.is_symlink() or not directory.is_dir():
        raise UpdateError("Toolkit directory is missing or unsafe")
    try:
        resolved = directory.resolve(strict=True)
    except OSError as error:
        raise UpdateError("Could not resolve the toolkit directory") from error
    if resolved != directory:
        raise UpdateError("Toolkit directory must use its canonical path")
    launcher = directory / "bc250-toolkit.sh"
    version_file = directory / "VERSION"
    for path in (launcher, version_file):
        if path.is_symlink() or not path.is_file():
            raise UpdateError("Toolkit installation is missing required regular files")
        if path.stat().st_uid != os.geteuid():
            raise UpdateError("Toolkit installation must be owned by the current user")
    if directory.stat().st_uid != os.geteuid() or directory.parent.stat().st_uid != os.geteuid():
        raise UpdateError("Toolkit directory and its parent must be owned by the current user")
    try:
        version = version_file.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        raise UpdateError("Could not read the installed toolkit version") from error
    version_tuple(version)
    return version


def download_asset(asset, destination):
    request = urllib.request.Request(asset["browser_download_url"], headers=request_headers())
    received = 0
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(request, timeout=60) as response, destination.open("xb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                received += len(chunk)
                if received > asset["size"]:
                    raise UpdateError("Downloaded asset exceeded its published size")
                output.write(chunk)
                digest.update(chunk)
    except UpdateError:
        raise
    except (OSError, urllib.error.URLError) as error:
        raise UpdateError("Could not download {}: {}".format(asset["name"], error)) from error
    if received != asset["size"]:
        raise UpdateError("Downloaded asset size does not match GitHub metadata")
    actual = digest.hexdigest()
    published = asset.get("digest")
    if published is not None and published != "sha256:{}".format(actual):
        raise UpdateError("Downloaded asset does not match the GitHub digest")
    return actual


def parse_checksum(path, archive_name):
    try:
        content = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise UpdateError("Could not read the toolkit checksum asset") from error
    match = SHA256_PATTERN.fullmatch(content)
    if match is None or match.group(2) != archive_name:
        raise UpdateError("Toolkit checksum asset has an invalid format or filename")
    return match.group(1)


def validate_member(info, seen):
    name = info.filename
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        raise UpdateError("Toolkit archive contains an unsafe path")
    directory = name.endswith("/")
    normalized = name[:-1] if directory else name
    components = normalized.split("/")
    if any(component in ("", ".", "..") for component in components):
        raise UpdateError("Toolkit archive contains an unsafe path")
    if PurePosixPath(normalized).parts[0] != ARCHIVE_ROOT:
        raise UpdateError("Toolkit archive has an unexpected top-level directory")
    if normalized in seen:
        raise UpdateError("Toolkit archive contains a duplicate path")
    seen.add(normalized)
    if info.flag_bits & 0x1:
        raise UpdateError("Toolkit archive contains an encrypted member")
    if info.file_size < 0 or info.file_size > MAX_MEMBER_BYTES:
        raise UpdateError("Toolkit archive member exceeded the safety limit")
    if info.create_system != 3:
        raise UpdateError("Toolkit archive member has no Unix file type")
    mode = (info.external_attr >> 16) & 0xFFFF
    if directory:
        if not stat.S_ISDIR(mode):
            raise UpdateError("Toolkit archive directory has an invalid file type")
    elif not stat.S_ISREG(mode):
        raise UpdateError("Toolkit archive contains a non-regular file")
    return normalized, directory, mode


def safe_extract(archive, destination, expected_version):
    destination.mkdir(mode=0o700)
    seen = set()
    entries = []
    total = 0
    try:
        with zipfile.ZipFile(str(archive), "r") as stream:
            infos = stream.infolist()
            if not infos or len(infos) > MAX_MEMBERS:
                raise UpdateError("Toolkit archive has an invalid member count")
            for info in infos:
                normalized, directory, mode = validate_member(info, seen)
                total += info.file_size
                if total > MAX_EXTRACTED_BYTES:
                    raise UpdateError("Toolkit archive exceeded the extraction safety limit")
                entries.append((info, normalized, directory, mode))
            required = {
                "{}/VERSION".format(ARCHIVE_ROOT),
                "{}/bc250-toolkit.sh".format(ARCHIVE_ROOT),
            }
            if not required.issubset(seen):
                raise UpdateError("Toolkit archive is missing its version or launcher")
            for _info, normalized, _directory, mode in sorted(
                (entry for entry in entries if entry[2]),
                key=lambda entry: len(PurePosixPath(entry[1]).parts),
            ):
                target = destination.joinpath(*PurePosixPath(normalized).parts)
                target.mkdir(parents=True, exist_ok=True)
                target.chmod((mode & 0o055) | 0o700)
            for info, normalized, directory, mode in entries:
                if directory:
                    continue
                target = destination.joinpath(*PurePosixPath(normalized).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.open(info, "r") as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                target.chmod((mode & 0o111) | 0o600)
    except UpdateError:
        raise
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise UpdateError("Toolkit archive is invalid: {}".format(error)) from error
    root = destination / ARCHIVE_ROOT
    if root.is_symlink() or not root.is_dir():
        raise UpdateError("Extracted toolkit root is unsafe")
    installed_version = read_current_version(root.resolve())
    if installed_version != expected_version:
        raise UpdateError("Toolkit archive version does not match its release tag")
    return root


def check_for_update(toolkit_directory, releases=None):
    current = read_current_version(toolkit_directory)
    release = select_release(fetch_releases() if releases is None else releases)
    latest = release["tag_name"]
    return {
        "currentVersion": current,
        "latestVersion": latest,
        "updateAvailable": version_tuple(latest) > version_tuple(current),
    }


def format_check_env(result):
    return "\n".join(
        (
            "CURRENT_VERSION={}".format(result["currentVersion"]),
            "LATEST_VERSION={}".format(result["latestVersion"]),
            "UPDATE_AVAILABLE={}".format("1" if result["updateAvailable"] else "0"),
        )
    )


def replace_installation(target, replacement):
    target = Path(target)
    replacement = Path(replacement)
    backup = target.parent / ".{}.previous-{}".format(target.name, os.getpid())
    if backup.exists() or backup.is_symlink():
        raise UpdateError("Toolkit update backup path already exists")
    try:
        os.replace(str(target), str(backup))
    except OSError as error:
        raise UpdateError("Could not stage the previous toolkit installation") from error
    try:
        os.replace(str(replacement), str(target))
    except OSError as error:
        try:
            os.replace(str(backup), str(target))
        except OSError as restore_error:
            raise UpdateError(
                "Toolkit replacement failed and the previous installation could not be restored"
            ) from restore_error
        raise UpdateError("Could not activate the new toolkit installation") from error
    try:
        shutil.rmtree(str(backup))
    except OSError as error:
        raise UpdateError("Toolkit updated, but the previous installation could not be removed") from error


def install_update(toolkit_directory, expected_version):
    current = read_current_version(toolkit_directory)
    version_tuple(expected_version)
    release = select_release(fetch_releases())
    if release["tag_name"] != expected_version:
        raise UpdateError("The available toolkit release changed; check for updates again")
    if version_tuple(expected_version) <= version_tuple(current):
        raise UpdateError("The selected toolkit release is not newer than the installed version")
    archive_asset, checksum_asset = select_release_assets(release)
    target = Path(toolkit_directory)
    with tempfile.TemporaryDirectory(prefix=".bc250-toolkit-update-", dir=str(target.parent)) as temporary_name:
        temporary = Path(temporary_name)
        archive = temporary / archive_asset["name"]
        checksum = temporary / checksum_asset["name"]
        actual_digest = download_asset(archive_asset, archive)
        download_asset(checksum_asset, checksum)
        if actual_digest != parse_checksum(checksum, archive.name):
            raise UpdateError("Toolkit archive does not match its checksum asset")
        extracted = safe_extract(archive, temporary / "extracted", expected_version)
        replace_installation(target, extracted)
    return {"previousVersion": current, "installedVersion": expected_version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("check", "install"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--toolkit-dir", required=True)
        if command == "install":
            subparser.add_argument("--expected-version", required=True)
        else:
            subparser.add_argument("--format", choices=("json", "env"), default="json")
    arguments = parser.parse_args()
    try:
        if os.geteuid() == 0:
            raise UpdateError("Run the updater as the logged-in desktop user, not with sudo")
        if arguments.command == "check":
            result = check_for_update(arguments.toolkit_dir)
        else:
            result = install_update(arguments.toolkit_dir, arguments.expected_version)
        if arguments.command == "check" and arguments.format == "env":
            print(format_check_env(result))
        else:
            print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    except (OSError, UpdateError) as error:
        print("[bc250-toolkit-update] {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
