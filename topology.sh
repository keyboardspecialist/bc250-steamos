#!/usr/bin/env bash
set -euo pipefail

command -v lscpu >/dev/null 2>&1 \
    || { echo "topology: lscpu is required." >&2; exit 1; }

if ! COMMAND=$(lscpu --all --extended=CPU,CORE,CACHE \
    | grep -E '^[[:space:]]*[0-9]'); then
    COMMAND=""
fi
[[ -n "$COMMAND" ]] \
    || { echo "topology: no CPU topology data found." >&2; exit 1; }

printf 'BC250 CCX Core Map\n'
CCX_IDS=$(awk '{print $3}' <<< "$COMMAND" | awk -F':' '{print $NF}' | sort -nu)
for ccx in $CCX_IDS; do
    printf "CCX %-2s: " "$ccx"
    ACTIVE_CORES=$(awk -v ccx="$ccx" '$3 ~ ":"ccx"$" {print $2}' \
        <<< "$COMMAND" | sort -nu)
    BASE_CORE=$(head -n1 <<< "$ACTIVE_CORES")
    for step in {0..3}; do
        TARGET_CORE=$((BASE_CORE + step))
        if grep -q -x "$TARGET_CORE" <<< "$ACTIVE_CORES"; then
            printf "■ "
        else
            printf "□ "
        fi
    done
    printf '\n'
done
