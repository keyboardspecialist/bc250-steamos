#!/bin/bash
# Fetch one coherent, host-channel build environment. Never mix rolling main
# packages into a versioned SteamOS image or overlay a previously extracted set.
set -euo pipefail

case "${1:-}" in
    -h|--help)
        echo "Usage: $0 (no arguments; optional MIRROR and DEP_REPOS environment overrides)"
        exit 0
        ;;
    '') ;;
    *) echo "Usage: $0 (no arguments)" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
MIRROR=${MIRROR:-https://steamdeck-packages.steamos.cloud/archlinux-mirror}
DEPS=$HERE/deps
DEP_PKGS=(pahole bc libelf openssl zlib glibc linux-api-headers bison flex cpio gettext perl python)
die() { echo "FATAL: $*" >&2; exit 1; }

if [ -n "${DEP_REPOS:-}" ]; then
    read -r -a REPOS <<< "$DEP_REPOS"
else
    command -v pacman-conf >/dev/null \
        || die "Cannot discover SteamOS repositories; set DEP_REPOS='extra-3.9 core-3.9' for cross-host fetching."
    CONFIGURED=$(pacman-conf --repo-list) || die "Could not read the installed pacman repository configuration"
    mapfile -t REPOS < <(printf '%s\n' "$CONFIGURED" | grep -E '^(extra|core)-[A-Za-z0-9._-]+$' || true)
fi
[ "${#REPOS[@]}" = 2 ] || die "Expected one matching extra/core repository pair; set DEP_REPOS explicitly if needed"
CHANNEL=
EXTRA= CORE=
for repo in "${REPOS[@]}"; do
    [[ "$repo" =~ ^(extra|core)-([A-Za-z0-9._-]+)$ ]] || die "Invalid dependency repository: $repo"
    suffix=${BASH_REMATCH[2]}
    [ -z "$CHANNEL" ] || [ "$CHANNEL" = "$suffix" ] || die "Refusing mixed dependency repository channels"
    CHANNEL=$suffix
    case "$repo" in extra-*) EXTRA=$repo ;; core-*) CORE=$repo ;; esac
done
[ -n "$EXTRA" ] && [ -n "$CORE" ] || die "Both extra and core repositories are required"
REPOS=("$EXTRA" "$CORE")
echo "Build dependency repositories: ${REPOS[*]}"
[ ! -L "$HERE/.build-deps.lock" ] || die "Refusing symlinked dependency lock"
exec 8>"$HERE/.build-deps.lock"
flock 8

[ ! -L "$DEPS" ] || die "Refusing symlinked build dependencies: $DEPS"
if [ -e "$DEPS" ]; then
    [ -d "$DEPS" ] && [ "$(stat -c '%u' "$DEPS")" = "$(id -u)" ] \
        || die "Build dependencies must be a directory owned by the build user: $DEPS"
fi
TMPD=$(mktemp -d "$HERE/.deps-fetch.XXXXXX")
STAGE= PREVIOUS=
cleanup() {
    local rc=$?
    if [ -n "$PREVIOUS" ] && [ ! -e "$DEPS" ]; then
        mv -- "$PREVIOUS" "$DEPS" || rc=1
    fi
    [ -z "$STAGE" ] || rm -rf -- "$STAGE"
    rm -rf -- "$TMPD"
    exit "$rc"
}
trap cleanup EXIT

for repo in "${REPOS[@]}"; do
    curl --retry 3 --retry-all-errors -fsSL -o "$TMPD/$repo.db" \
        "$MIRROR/$repo/os/x86_64/$repo.db" || die "Could not fetch package database for $repo"
    tar -tf "$TMPD/$repo.db" > "$TMPD/$repo.entries" || die "Invalid package database for $repo"
done
field() { awk -v key="%$1%" '$0 == key { getline; print }' "$TMPD/desc"; }
printf 'bc250-build-deps-v1\n%s\n%s\n' "${REPOS[*]}" "$(getconf GNU_LIBC_VERSION)" > "$TMPD/manifest"
for pkg in "${DEP_PKGS[@]}"; do
    ENTRY= REPO=
    for repo in "${REPOS[@]}"; do
        ENTRY=$(awk -F/ -v p="$pkg" '$2 == "desc" {
            n=$1; sub(/-[^-]+-[^-]+$/, "", n)
            if (n == p && !found) { print $0; found=1 }
        }' "$TMPD/$repo.entries")
        [ -z "$ENTRY" ] || { REPO=$repo; break; }
    done
    [ -n "$ENTRY" ] || die "Package '$pkg' not found in: ${REPOS[*]}"
    tar -xOf "$TMPD/$REPO.db" "$ENTRY" > "$TMPD/desc"
    FILE=$(field FILENAME)
    SHA=$(field SHA256SUM)
    [ "$(field NAME)" = "$pkg" ] || die "Unexpected package metadata for $pkg"
    [[ "$FILE" != */* && "$FILE" == "$pkg"-*-x86_64.pkg.tar.zst && "$SHA" =~ ^[0-9a-f]{64}$ ]] \
        || die "Invalid filename or checksum for $pkg"
    printf '%s %s %s\n' "$REPO" "$FILE" "$SHA" >> "$TMPD/manifest"
done

if [ -f "$DEPS/.bc250-build-deps" ] && [ ! -L "$DEPS/.bc250-build-deps" ] \
    && cmp -s "$TMPD/manifest" "$DEPS/.bc250-build-deps" \
    && (BC250_BUILD_DEPS="$DEPS" source "$HERE/build-env.sh"); then
    echo "Build dependencies already match $CHANNEL and pass runtime checks"
    exit 0
fi

STAGE=$(mktemp -d "$HERE/.deps-stage.XXXXXX")
while read -r repo file sha; do
    ARCHIVE=$HERE/$file
    if [ -L "$ARCHIVE" ]; then die "Refusing symlinked package cache: $ARCHIVE"; fi
    if [ ! -f "$ARCHIVE" ] || [ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" != "$sha" ]; then
        curl --retry 3 --retry-all-errors -fsSL -o "$TMPD/package" \
            "$MIRROR/$repo/os/x86_64/${file//:/%3A}" || die "Download failed: $file"
        [ "$(sha256sum "$TMPD/package" | awk '{print $1}')" = "$sha" ] || die "Checksum mismatch: $file"
        mv -f -- "$TMPD/package" "$ARCHIVE"
    fi
    # The host's libc and loader remain authoritative. Extracting libc itself
    # would shadow the system runtime through LD_LIBRARY_PATH.
    case "$file" in glibc-*|linux-api-headers-*) SUBTREE=usr/include ;; *) SUBTREE=usr ;; esac
    tar --zstd -xf "$ARCHIVE" -C "$STAGE" "$SUBTREE"
    echo "Extracted $file from $repo"
done < <(tail -n +4 "$TMPD/manifest")
(BC250_BUILD_DEPS="$STAGE" source "$HERE/build-env.sh") \
    || die "Downloaded dependencies do not run on this host; the previous cache was preserved"
cp "$TMPD/manifest" "$STAGE/.bc250-build-deps"
if [ -d "$DEPS" ]; then
    PREVIOUS=$(mktemp -d "$HERE/.deps-previous.XXXXXX")
    rmdir "$PREVIOUS"
    mv -- "$DEPS" "$PREVIOUS"
fi
mv -- "$STAGE" "$DEPS"
STAGE=
echo "Build dependencies installed for $CHANNEL"
if [ -n "$PREVIOUS" ]; then echo "Previous dependency cache retained at $PREVIOUS"; fi
