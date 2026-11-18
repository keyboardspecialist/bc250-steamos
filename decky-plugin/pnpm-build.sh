#!/usr/bin/env bash
# Build one package without reading or rewriting a user's pnpm workspace.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# Latest stable Rollup can be younger than pnpm 12's default age gate.
# Exempt only the exact reviewed Rollup/native version in package.json, never
# arbitrary dependencies or a whole package family at future versions.
reviewed=$(python3 -I - <<'PY'
import json
from pathlib import Path
import re

package = json.loads(Path("package.json").read_text())
version = package["devDependencies"]["rollup"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Rollup must be pinned to an exact stable version")
lock = Path("pnpm-lock.yaml").read_text()
names = {"rollup"}
for name, locked in re.findall(r"^  '(@rollup/rollup-[a-z0-9-]+)@([^']+)':", lock, re.M):
    if locked == version:
        names.add(name)
for name in sorted(names):
    print("--config.minimumReleaseAgeExclude[]=" + name + "@" + version)
PY
)
mapfile -t age_exceptions <<< "$reviewed"
exec "${BC250_PNPM_BIN:-pnpm}" --ignore-workspace "${age_exceptions[@]}" "$@"
