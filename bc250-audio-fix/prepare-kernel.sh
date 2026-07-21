#!/bin/bash
# Prepare an exact Kbuild tree for the running SteamOS kernel. The fast path
# uses Valve's headers package; if that package was never published, build the
# exact source completely to generate Module.symvers.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TREE=${1:-$HERE/valve-kernel}

[ "$(id -u)" != 0 ] || { echo "FATAL: prepare the kernel as the normal user, not root" >&2; exit 1; }
command -v flock >/dev/null || { echo "FATAL: flock is required" >&2; exit 1; }

exec 9>"$HERE/.prepare-kernel.lock"
flock 9

"$HERE/fetch-sources.sh" "$TREE"
"$HERE/build.sh" --prepare-only "$TREE"
