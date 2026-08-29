#!/bin/bash
# Run mkinitcpio while tolerating SteamOS's stale pre-7.2 BLAKE2 module name.
set -euo pipefail

REL=${1:?usage: mkinitcpio-compat.sh <kernel-release> <mkinitcpio arguments...>}
shift

INSTALL_PATH=${MKINITCPIO_INSTALL:-/etc/initcpio/install:/usr/lib/initcpio/install}
STEAM_DECK_HOOK=
IFS=: read -r -a INSTALL_DIRS <<< "$INSTALL_PATH"
for directory in "${INSTALL_DIRS[@]}"; do
    if [ -f "$directory/steam-deck" ]; then
        STEAM_DECK_HOOK=$directory/steam-deck
        break
    fi
done

if [ -z "$STEAM_DECK_HOOK" ] \
   || ! grep -qE '^[[:space:]]*blake2b_generic[[:space:]]*$' "$STEAM_DECK_HOOK" \
   || modinfo -k "$REL" blake2b_generic >/dev/null 2>&1 \
   || [ "$(modinfo -k "$REL" -F filename blake2b 2>/dev/null || true)" != "(builtin)" ]; then
    exec mkinitcpio "$@"
fi

# Linux 7.2 renamed the built-in implementation to blake2b, but SteamOS's hook
# still requests the old loadable-module name. Override the hook for this run
# only, leaving the packaged file untouched.
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cp "$STEAM_DECK_HOOK" "$TMPD/steam-deck"
sed -i -E 's/^([[:space:]]*)blake2b_generic([[:space:]]*)$/\1blake2b_generic?\2/' \
    "$TMPD/steam-deck"
echo "note: ignoring stale SteamOS blake2b_generic request; blake2b is built into $REL"
MKINITCPIO_INSTALL="$TMPD:$INSTALL_PATH" mkinitcpio "$@"
