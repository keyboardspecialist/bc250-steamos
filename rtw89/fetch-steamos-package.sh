#!/usr/bin/env bash
# Fetch one exact package from a stable SteamOS Jupiter repository.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 PACKAGE.pkg.tar.zst DESTINATION" >&2; exit 2; }
PACKAGE=$1
DEST=$2
MIRROR=${MIRROR:-https://steamdeck-packages.steamos.cloud/archlinux-mirror}

case "$PACKAGE" in
    */*|'') echo "Invalid package filename: $PACKAGE" >&2; exit 2 ;;
    *.pkg.tar.zst) ;;
    *) echo "Unsupported package filename: $PACKAGE" >&2; exit 2 ;;
esac

valid_archive() {
    [[ -s $1 ]] && tar --zstd -tf "$1" >/dev/null 2>&1 || return 1
    [[ -z ${EXPECTED_MEMBER:-} ]] \
        || tar --zstd -tf "$1" "$EXPECTED_MEMBER" >/dev/null 2>&1
}

if valid_archive "$DEST"; then
    echo "Already downloaded: $PACKAGE" >&2
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
TMP=$(mktemp "${DEST}.part.XXXXXX")
trap 'rm -f "$TMP"' EXIT

if [[ -n ${HDR_REPOS:-} ]]; then
    REPOS=$HDR_REPOS
else
    INDEX=$(curl --retry 2 --connect-timeout 10 -fsSL "$MIRROR/") \
        || { echo "Could not read SteamOS package index: $MIRROR/" >&2; exit 1; }
    DISCOVERED=$(printf '%s' "$INDEX" \
        | grep -oE 'href="jupiter-[^"/]+/"' \
        | sed 's|^href="||; s|/"$||' \
        | grep -vxE 'jupiter-(main|ci-test|staging.*)' \
        | sort -rV | tr '\n' ' ') || DISCOVERED=
    REPOS="jupiter-main $DISCOVERED"
fi

PROBED=
UNCERTAIN=
for repo in $REPOS; do
    case "$repo" in jupiter-[A-Za-z0-9._-]*) ;; *) continue ;; esac
    case " $PROBED " in *" $repo "*) continue ;; esac
    PROBED="$PROBED $repo"
    URL=$MIRROR/$repo/os/x86_64/$PACKAGE
    if ! HTTP=$(curl --retry 2 --connect-timeout 10 --max-time 20 \
        -sSIL -o /dev/null -w '%{http_code}' "$URL"); then
        UNCERTAIN="$UNCERTAIN $repo(network)"
        continue
    fi
    case "$HTTP" in
        2*) ;;
        404|410) continue ;;
        *) UNCERTAIN="$UNCERTAIN $repo(HTTP-$HTTP)"; continue ;;
    esac
    echo "Fetching $PACKAGE from $repo ..." >&2
    if curl --retry 3 --retry-all-errors -fL -o "$TMP" "$URL" \
        && valid_archive "$TMP"; then
        mv -f "$TMP" "$DEST"
        trap - EXIT
        exit 0
    fi
    UNCERTAIN="$UNCERTAIN $repo(download-or-content)"
    : > "$TMP"
done

if [[ -n $UNCERTAIN ]]; then
    echo "Could not reliably retrieve $PACKAGE. Uncertain:$UNCERTAIN" >&2
    exit 1
fi
echo "Could not find $PACKAGE. Probed:${PROBED:- none}" >&2
exit 3
