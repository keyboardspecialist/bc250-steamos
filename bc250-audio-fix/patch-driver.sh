#!/bin/bash
# Single entry point: fetch sources, build, install — the full cycle after a
# SteamOS update. Run as the normal user; sudo is invoked for install only.
#
#   ./patch-driver.sh [kernel-tree]      (default: ./valve-kernel)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" != 0 ] || { echo "run as the normal user — sudo is used for the install step only"; exit 1; }

"$HERE/fetch-sources.sh" "$@"
"$HERE/build.sh" "$@"
sudo "$HERE/install.sh"
