#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/core-unlock/bc250-unlock-cores-efi.c"
PIN="761b114e3b186adb82516d5fa8e7a4c559f56ba5"
REPOSITORY="https://github.com/yoppeh/efi.git"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git -C "$WORK" init -q
git -C "$WORK" remote add origin "$REPOSITORY"
git -C "$WORK" fetch -q --no-tags --depth=1 origin "$PIN"
git -C "$WORK" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$WORK" rev-parse HEAD)" == "$PIN" ]]

clang -I "$WORK" -DEFI_PLATFORM=1 -target x86_64-unknown-windows \
    -ffreestanding -mno-red-zone -nostdlib -fuse-ld=lld \
    -Wl,-entry:efi_main -Wl,-subsystem:efi_application \
    -o "$WORK/bc250-core-unlock.efi" "$SOURCE"

description=$(LC_ALL=C file -b "$WORK/bc250-core-unlock.efi")
[[ "$description" == *PE32+* \
    && ( "${description,,}" == *"efi application"* \
        || "${description,,}" == *"efi (application)"* ) \
    && "${description,,}" == *"x86-64"* ]] \
    || { printf 'Unexpected EFI image: %s\n' "$description" >&2; exit 1; }
