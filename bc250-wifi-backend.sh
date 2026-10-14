#!/usr/bin/env bash
# Select and optionally lock NetworkManager's SteamOS Wi-Fi backend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/scripts/wifi-backend.py"

[[ -f "$HELPER" && ! -L "$HELPER" ]] \
    || { echo "[bc250-wifi] Wi-Fi backend helper is missing or unsafe." >&2; exit 1; }
command -v python3 >/dev/null \
    || { echo "[bc250-wifi] Python 3 is required." >&2; exit 1; }

if [[ $# -eq 0 ]]; then set -- status; fi
case "$1" in
    status) exec python3 -I "$HELPER" "$@" ;;
    help|-h|--help) exec python3 -I "$HELPER" --help ;;
    set|lock)
        [[ $# -eq 2 && ( "$2" == iwd || "$2" == wpa_supplicant ) ]] \
            || { echo "Usage: $0 $1 iwd|wpa_supplicant" >&2; exit 2; }
        ;;
    unlock)
        [[ $# -eq 1 ]] || { echo "Usage: $0 unlock" >&2; exit 2; }
        ;;
    *) echo "Usage: $0 [status [--json]|set BACKEND|lock BACKEND|unlock|help]" >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi
exec python3 -I "$HELPER" "$@"
