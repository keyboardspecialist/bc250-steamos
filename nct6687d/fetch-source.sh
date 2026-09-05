#!/usr/bin/env bash
# Fetch the exact audited nct6687d source without trusting a moving branch.
set -euo pipefail

COMMIT=a49a8abdfb6221772ecc836b3109e0cc338203cf
BASE_URL="https://raw.githubusercontent.com/Fred78290/nct6687d/$COMMIT"
DEST=${1:-}

die() { echo "[nct6687] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Fetch source as the logged-in user, not root."
[[ "$DEST" == /* ]] || die "Usage: $0 /absolute/destination"
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

manifest() {
    cat << 'EOF'
ab83ace080e46646a9c807e31177a460902b11661bbbde31ed883261eccf3b45  Kbuild
9bd825e95b6804328efbd6a4b587babdcc7acd289407dac3f353109d16f42def  Makefile
895b5df0011ffa11bdf8bcfef2f002992aa4949d2703cd4281cecdb44917820a  nct6687.c
8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643  LICENSE
eb37bf64b71c1e91ec53e655f4cfdecf6f6fd1c77f4708834bd8bd3d09faa416  README.md
EOF
}

source_valid() {
    [[ -d "$DEST" && ! -L "$DEST" \
        && -f "$DEST/.bc250-source" && ! -L "$DEST/.bc250-source" ]] \
        || return 1
    [[ "$(<"$DEST/.bc250-source")" == "$COMMIT" ]] || return 1
    manifest | (cd "$DEST" && sha256sum -c --quiet -)
}

if source_valid; then
    echo "[nct6687] Pinned source already verified at $DEST"
    exit 0
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -d "$DEST" && ! -L "$DEST" \
        && -f "$DEST/.bc250-source" && ! -L "$DEST/.bc250-source" ]] \
        || die "Refusing to replace unrecognized source cache: $DEST"
fi

parent=$(dirname "$DEST")
mkdir -p "$parent"
stage=$(mktemp -d "$parent/.nct6687d-source.XXXXXX")
trap 'rm -rf "$stage"' EXIT

for file in Kbuild Makefile nct6687.c LICENSE README.md; do
    curl --retry 3 --retry-all-errors --connect-timeout 10 -fsSL \
        "$BASE_URL/$file" -o "$stage/$file"
done
manifest > "$stage/source.sha256"
(cd "$stage" && sha256sum -c --quiet source.sha256) \
    || die "Pinned source integrity verification failed."
printf '%s\n' "$COMMIT" > "$stage/.bc250-source"

rm -rf "$DEST"
mv "$stage" "$DEST"
trap - EXIT
echo "[nct6687] Verified source $COMMIT at $DEST"
