#!/usr/bin/env python3
"""Download, verify, and install the newest BC250 Trainer native release."""

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
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
TAG_PATTERN = re.compile(r"trainer-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SHA256_PATTERN = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)\n?")
ARCHIVE_ROOT = "bc250-trainer"
MAX_API_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_EXTRACTED_BYTES = 768 * 1024 * 1024
MAX_MEMBERS = 4096


class InstallError(RuntimeError):
    pass


def request_headers(api=False):
    headers = {
        "Accept": "application/vnd.github+json" if api else "application/octet-stream",
        "User-Agent": "bc250-trainer-release-installer/1",
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
            raise InstallError("GitHub response exceeded the safety limit")
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
        raise InstallError("Could not query GitHub releases: {}".format(error)) from error
    try:
        releases = json.loads(payload.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise InstallError("GitHub returned invalid release metadata") from error
    if not isinstance(releases, list):
        raise InstallError("GitHub returned unexpected release metadata")
    return releases


def fetch_releases():
    releases = []
    for page in range(1, 101):
        batch = fetch_release_page(page)
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise InstallError("GitHub release pagination exceeded the safety limit")


def select_release(releases):
    candidates = []
    for release in releases:
        if not isinstance(release, dict) or release.get("draft") is True:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str):
            continue
        match = TAG_PATTERN.fullmatch(tag)
        if match is None:
            continue
        candidates.append((tuple(int(value) for value in match.groups()), release))
    if not candidates:
        raise InstallError("No published trainer-vMAJOR.MINOR.PATCH release was found")
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
        raise InstallError("Trainer release has no asset list")
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
    if len(matches) != 1:
        raise InstallError("Trainer release must contain exactly one {} asset".format(name))
    asset = matches[0]
    tag = release["tag_name"]
    size = asset.get("size")
    url = asset.get("browser_download_url")
    if (
        not isinstance(size, int)
        or isinstance(size, bool)
        or size <= 0
        or size > maximum_size
    ):
        raise InstallError("Trainer release asset has an invalid size: {}".format(name))
    if asset.get("state") != "uploaded" or url != expected_asset_url(tag, name):
        raise InstallError("Trainer release asset metadata is invalid: {}".format(name))
    digest = asset.get("digest")
    if digest is not None and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise InstallError("Trainer release asset digest is invalid: {}".format(name))
    return asset


def select_release_assets(release):
    tag = release["tag_name"]
    archive_name = "bc250-{}.zip".format(tag)
    checksum_name = "{}.sha256".format(archive_name)
    archive = select_asset(release, archive_name, MAX_ARCHIVE_BYTES)
    checksum = select_asset(release, checksum_name, 4096)
    return archive, checksum


def download_asset(asset, destination):
    request = urllib.request.Request(
        asset["browser_download_url"], headers=request_headers(api=False)
    )
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
                    raise InstallError("Downloaded asset exceeded its published size")
                output.write(chunk)
                digest.update(chunk)
    except InstallError:
        raise
    except (OSError, urllib.error.URLError) as error:
        raise InstallError("Could not download {}: {}".format(asset["name"], error)) from error
    if received != asset["size"]:
        raise InstallError("Downloaded asset size does not match GitHub metadata")
    actual = digest.hexdigest()
    published = asset.get("digest")
    if published is not None and published != "sha256:{}".format(actual):
        raise InstallError("Downloaded asset does not match the GitHub digest")
    return actual


def parse_checksum(path, archive_name):
    try:
        content = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise InstallError("Could not read the Trainer checksum asset") from error
    match = SHA256_PATTERN.fullmatch(content)
    if match is None or match.group(2) != archive_name:
        raise InstallError("Trainer checksum asset has an invalid format or filename")
    return match.group(1)


def validate_member(info, seen):
    name = info.filename
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        raise InstallError("Trainer archive contains an unsafe path")
    directory = name.endswith("/")
    normalized = name[:-1] if directory else name
    components = normalized.split("/")
    if any(component in ("", ".", "..") for component in components):
        raise InstallError("Trainer archive contains an unsafe path")
    if PurePosixPath(normalized).parts[0] != ARCHIVE_ROOT:
        raise InstallError("Trainer archive has an unexpected top-level directory")
    if normalized in seen:
        raise InstallError("Trainer archive contains a duplicate path")
    seen.add(normalized)
    if info.flag_bits & 0x1:
        raise InstallError("Trainer archive contains an encrypted member")
    if info.file_size < 0 or info.file_size > MAX_MEMBER_BYTES:
        raise InstallError("Trainer archive member exceeded the safety limit")
    if info.create_system != 3:
        raise InstallError("Trainer archive member has no Unix file type")
    mode = (info.external_attr >> 16) & 0xFFFF
    if directory:
        if not stat.S_ISDIR(mode):
            raise InstallError("Trainer archive directory has an invalid file type")
    elif not stat.S_ISREG(mode):
        raise InstallError("Trainer archive contains a non-regular file")
    return normalized, directory, mode


def safe_extract(archive, destination):
    destination.mkdir(mode=0o700)
    seen = set()
    entries = []
    total = 0
    try:
        with zipfile.ZipFile(str(archive), "r") as stream:
            infos = stream.infolist()
            if not infos or len(infos) > MAX_MEMBERS:
                raise InstallError("Trainer archive has an invalid member count")
            for info in infos:
                normalized, directory, mode = validate_member(info, seen)
                total += info.file_size
                if total > MAX_EXTRACTED_BYTES:
                    raise InstallError("Trainer archive exceeded the extraction safety limit")
                entries.append((info, normalized, directory, mode))
            required = {
                "{}/trainer/install.sh".format(ARCHIVE_ROOT),
                "{}/trainer/bc250-trainer".format(ARCHIVE_ROOT),
            }
            if not required.issubset(seen):
                raise InstallError("Trainer archive is missing its installer or executable")
            directories = sorted(
                (entry for entry in entries if entry[2]),
                key=lambda entry: len(PurePosixPath(entry[1]).parts),
            )
            for _info, normalized, _directory, mode in directories:
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
    except InstallError:
        raise
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise InstallError("Trainer archive is invalid: {}".format(error)) from error
    root = destination / ARCHIVE_ROOT
    installer = root / "trainer/install.sh"
    binary = root / "trainer/bc250-trainer"
    if not installer.is_file() or installer.is_symlink() or not binary.is_file() or binary.is_symlink():
        raise InstallError("Extracted Trainer installer or executable is unsafe")
    installer.chmod(0o755)
    binary.chmod(0o755)
    return root


def install_latest():
    if os.geteuid() == 0:
        raise InstallError("Run as the logged-in desktop user, not with sudo")
    release = select_release(fetch_releases())
    archive_asset, checksum_asset = select_release_assets(release)
    print("[bc250-trainer-release] selected {}".format(release["tag_name"]))
    with tempfile.TemporaryDirectory(prefix="bc250-trainer-release-") as temporary_name:
        temporary = Path(temporary_name)
        archive = temporary / archive_asset["name"]
        checksum = temporary / checksum_asset["name"]
        archive_digest = download_asset(archive_asset, archive)
        download_asset(checksum_asset, checksum)
        expected_digest = parse_checksum(checksum, archive.name)
        if archive_digest != expected_digest:
            raise InstallError("Trainer archive does not match its checksum asset")
        extracted = safe_extract(archive, temporary / "extracted")
        installer = extracted / "trainer/install.sh"
        result = subprocess.run(["bash", str(installer), "install"], cwd=str(extracted))
        if result.returncode != 0:
            raise InstallError("Trainer installer failed with status {}".format(result.returncode))


def main():
    try:
        install_latest()
    except InstallError as error:
        print("[bc250-trainer-release] {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
