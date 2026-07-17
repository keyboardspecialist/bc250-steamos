#!/usr/bin/env bash
# install.sh — build and install the BC-250 Control Decky plugin.
#
# Everything lands in update-proof locations: pnpm + node go to
# ~/.local/share/pnpm (SteamOS updates wipe /usr, not /home), and the
# built plugin is copied to Decky's ~/homebrew/plugins directory.
#
# Run as the deck user, NOT root — pnpm/node must install into the deck
# home. The copy into the root-owned plugins dir and the plugin_loader
# restart use sudo (set a password with `passwd` first if you never have).
#
# Steps:
#   1. Install standalone pnpm if missing (and node LTS via pnpm)
#   2. Ensure PNPM_HOME is on PATH in ~/.bashrc and ~/.zshrc
#   3. pnpm install + typecheck + build + backend unit tests
#   4. Copy the runtime files into ~/homebrew/plugins/"BC-250 Control"
#      and restart plugin_loader

set -euo pipefail

PLUGIN_NAME="BC-250 Control"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/homebrew/plugins"
DEST_DIR="$PLUGINS_DIR/$PLUGIN_NAME"
ROOT_HELPER_DIR="/var/lib/bc250-control/helper"
ROOT_STATE_DIR="/var/lib/bc250-control/smu-oc"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
export PATH="$PNPM_HOME/bin:$PATH"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as the deck user, not root (sudo is used where needed)"
[[ -f "$SRC_DIR/plugin.json" ]] || die "plugin.json not found next to this script"
[[ -d "$PLUGINS_DIR" ]] || die "$PLUGINS_DIR missing — install Decky Loader first"

# --- 1. dependencies --------------------------------------------------------

if ! command -v pnpm >/dev/null 2>&1; then
    log "Installing standalone pnpm to $PNPM_HOME"
    curl -fsSL https://get.pnpm.io/install.sh | sh -
fi

if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js LTS via pnpm"
    pnpm env use --global lts
fi

# --- 2. shell PATH setup ----------------------------------------------------
# The pnpm installer only edits the shell rc it detects; cover bash and zsh.

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -q 'PNPM_HOME' "$rc" && continue
    log "Adding pnpm to PATH in $rc"
    cat >>"$rc" <<'EOF'

# pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac
# pnpm end
EOF
done

# --- 3. build ---------------------------------------------------------------

cd "$SRC_DIR"
log "Installing plugin dependencies"
pnpm install
log "Typechecking"
pnpm run typecheck
log "Building bundle"
pnpm run build
log "Running backend tests"
PYTHONPATH=py_modules python3 -m unittest discover -s tests

[[ -f dist/index.js ]] || die "build produced no dist/index.js"

# --- 4. install root helper and Decky plugin -------------------------------
# Only the runtime files ship; node_modules/src/tests stay in the checkout.

log "Installing root-owned CPU tuning helper (sudo)"
sudo rm -rf "$ROOT_HELPER_DIR"
sudo install -d -m 0755 "$ROOT_HELPER_DIR/smu-oc-patches" "$ROOT_STATE_DIR"
sudo install -m 0755 "$SRC_DIR/../bc250-power.sh" "$ROOT_HELPER_DIR/bc250-power.sh"
sudo install -m 0755 "$SRC_DIR/../bc250-update-persistence.sh" "$ROOT_HELPER_DIR/bc250-update-persistence.sh"
sudo install -m 0644 "$SRC_DIR"/../smu-oc-patches/* "$ROOT_HELPER_DIR/smu-oc-patches/"

log "Installing to $DEST_DIR (sudo)"
sudo rm -rf "$DEST_DIR"
sudo install -d "$DEST_DIR"
sudo cp -r plugin.json package.json main.py dist py_modules "$DEST_DIR/"
# Flush to disk immediately — a BC-250 hard crash before writeback would
# otherwise leave the installed files as zero-byte husks.
sync

log "Restarting plugin_loader"
sudo systemctl restart plugin_loader

log "Done — '$PLUGIN_NAME' is available in the Quick Access menu (...)"
