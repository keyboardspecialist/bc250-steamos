#!/usr/bin/env bash
# install.sh — manage the BC-250 Control Decky plugin.
#
# Everything lands in update-proof locations: pnpm + node go to
# ~/.local/share/bc250-control/toolchain (SteamOS updates wipe /usr, not /home).
# The built plugin is copied to Decky's ~/homebrew/plugins directory.
#
# Run as the deck user, NOT root. Install/uninstall use sudo for Decky's
# root-owned plugin directory and the plugin_loader restart.
#
# Steps:
#   1. Install Decky Loader if missing
#   2. Prepare the pinned, private pnpm/Node build toolchain
#      (without replacing the user's pnpm or editing shell startup files)
#   3. pnpm install + typecheck + build + backend unit tests + runtime staging
#   4. Copy the runtime files into ~/homebrew/plugins/"BC-250 Control"
#      and restart plugin_loader

set -euo pipefail

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    _bc250_hook="$(dirname -- "${BASH_SOURCE[0]}")/../scripts/feature-tracking.sh"
    if [[ -f "$_bc250_hook" && ! -L "$_bc250_hook" ]]; then source "$_bc250_hook" decky install "$@"; fi
    unset _bc250_hook
fi

PLUGIN_NAME="BC-250 Control"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/homebrew/plugins"
DEST_DIR="$PLUGINS_DIR/$PLUGIN_NAME"
ROOT_HELPER_DIR="/var/lib/bc250-control/helper"
ROOT_STATE_DIR="/var/lib/bc250-control/smu-oc"
ROOT_UMR_DIR="/var/lib/bc250-control/umr"
CU_CONFIG="/etc/bc250-cu-live-manager.conf"
TOOLKIT_DIR="$HOME/.local/share/bc250-fixes/bc250-steamos"
CU_MANAGER_SOURCE=""
UMR_SOURCE=""
UMR_DATABASE_SOURCE=""
UMR_STAGE=""
PNPM_DOWNLOAD=""
PNPM_STAGE=""
PNPM_VERSION="12.21.0"
NODE_MAJOR="26"
NODE_MIN_MINOR="13"
NODE_MIN_PATCH="1"
# npm's stable dist-tag; 12.22.0 is still on its next channel.
# SHA-256 of the upstream v12.21.0 pnpm-linux-x64.tar.gz release asset.
PNPM_SHA256="84c4773bcf4a217f4083cd7b2a91e4cee6103cf42426c1282ef37d308f55a410"
DECKY_INSTALLER_VERSION="v1.10.0"
DECKY_INSTALLER_SHA256="ed2de421b9713dd355ea5ede58f70c67e02127747cd59d00f49a145053d33ba7"
DECKY_MIN_VERSION="3.3.1"
SMU_PATCH_SOURCES=(
    "$SRC_DIR/../smu-oc-patches/0001-transaction-level-flock.patch"
    "$SRC_DIR/../smu-oc-patches/0002-steamos-stress-fallback.patch"
    "$SRC_DIR/../smu-oc-patches/0003-atomic-config-write.patch"
    "$SRC_DIR/../smu-oc-patches/0004-time-based-mailbox-timeout.patch"
    "$SRC_DIR/../smu-oc-patches/README.md"
    "$SRC_DIR/../smu-oc-patches/bc250_detect.py"
    "$SRC_DIR/../smu-oc-patches/stress_helper.py"
    "$SRC_DIR/../smu-oc-patches/transport.py"
    "$SRC_DIR/../smu-oc-patches/mailbox.py"
    "$SRC_DIR/../smu-oc-patches/api.py"
)
# Keep build tooling isolated from user-global installations.
export PNPM_HOME="$HOME/.local/share/bc250-control/toolchain"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cleanup() {
    [[ -z "$PNPM_DOWNLOAD" ]] || rm -f -- "$PNPM_DOWNLOAD"
    [[ -z "$PNPM_STAGE" ]] || rm -rf -- "$PNPM_STAGE"
    [[ -z "$UMR_STAGE" ]] || sudo rm -rf "$UMR_STAGE"
}
umr_database_complete() {
    local database="$1"
    [[ -s "$database/cyan_skillfish.asic" \
        && -s "$database/cyan_skillfish.soc15" \
        && -s "$database/ip/gc_10_1_0.reg" ]]
}
trap cleanup EXIT

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "run as the deck user, not root (sudo is used where needed)"
}

ensure_build_toolchain() {
    local pnpm_bin="$PNPM_HOME/pnpm"
    if [[ ! -x "$pnpm_bin" ]] \
        || [[ "$("$pnpm_bin" --version 2>/dev/null)" != "$PNPM_VERSION" ]]; then
        [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
            || die "the BC-250 build toolchain requires Linux x86_64"
        log "Installing private pnpm $PNPM_VERSION to $PNPM_HOME"
        mkdir -p "$PNPM_HOME"
        PNPM_DOWNLOAD=$(mktemp "$PNPM_HOME/.pnpm-download.XXXXXX")
        curl -fL --retry 3 --output "$PNPM_DOWNLOAD" \
            "https://github.com/pnpm/pnpm/releases/download/v$PNPM_VERSION/pnpm-linux-x64.tar.gz"
        printf '%s  %s\n' "$PNPM_SHA256" "$PNPM_DOWNLOAD" | sha256sum -c - \
            || die "pnpm download checksum mismatch"
        PNPM_STAGE=$(mktemp -d "$PNPM_HOME/.pnpm-stage.XXXXXX")
        # Extract only after verifying the complete upstream archive.
        tar -xzf "$PNPM_DOWNLOAD" --no-same-owner -C "$PNPM_STAGE"
        [[ "$("$PNPM_STAGE/pnpm" --version)" == "$PNPM_VERSION" ]] \
            || die "pnpm archive contains the wrong version"
        [[ ! -e "$PNPM_HOME/pnpm-$PNPM_VERSION" && ! -L "$PNPM_HOME/pnpm-$PNPM_VERSION" ]] \
            || die "private pnpm version directory already exists; preserve it before retrying"
        mv -- "$PNPM_STAGE" "$PNPM_HOME/pnpm-$PNPM_VERSION"
        PNPM_STAGE=""
        ln -sfn -- "pnpm-$PNPM_VERSION/pnpm" "$pnpm_bin"
        rm -f -- "$PNPM_DOWNLOAD"
        PNPM_DOWNLOAD=""
    fi
    [[ "$("$pnpm_bin" --version)" == "$PNPM_VERSION" ]] \
        || die "could not prepare pnpm $PNPM_VERSION"
    if ! node_compatible; then
        log "Installing Node.js $NODE_MAJOR via private pnpm"
        "$pnpm_bin" --ignore-workspace runtime set node "$NODE_MAJOR" -g
        hash -r
    fi
    node_compatible \
        || die "Node.js $NODE_MAJOR.$NODE_MIN_MINOR.$NODE_MIN_PATCH or newer within $NODE_MAJOR.x is required"
}

node_compatible() {
    command -v node >/dev/null 2>&1 && node -e '
        const [major, minor, patch] = process.versions.node.split(".").map(Number);
        const [wantMajor, wantMinor, wantPatch] = process.argv.slice(1).map(Number);
        process.exit(major === wantMajor &&
            (minor > wantMinor || (minor === wantMinor && patch >= wantPatch)) ? 0 : 1);
    ' "$NODE_MAJOR" "$NODE_MIN_MINOR" "$NODE_MIN_PATCH"
}

pnpm_build() {
    # This is one package, not a workspace. In particular, leave any user's
    # untracked pnpm-workspace.yaml intact. No obsolete package.json pnpm rules.
    BC250_PNPM_BIN="$PNPM_HOME/pnpm" bash "$SRC_DIR/pnpm-build.sh" "$@"
}

decky_loader_installed() {
    [[ -d "$PLUGINS_DIR" ]] \
        && systemctl cat plugin_loader.service >/dev/null 2>&1
}

ensure_decky_loader() {
    if decky_loader_installed; then
        local version_file="$HOME/homebrew/services/.loader.version" version=""
        if [[ -f "$version_file" && ! -L "$version_file" ]]; then
            version=$(< "$version_file")
        fi
        # Do not downgrade newer or prerelease/custom installations. Only a
        # recognizable, older stable release is upgraded automatically.
        if ! python3 - "$version" "$DECKY_MIN_VERSION" <<'PY'
import re
import sys
match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", sys.argv[1])
raise SystemExit(0 if match and tuple(map(int, match.groups())) <
                 tuple(map(int, sys.argv[2].split("."))) else 1)
PY
        then
            log "Existing Decky Loader: ${version:-unknown}. Keeping it; stable v$DECKY_MIN_VERSION or newer is recommended."
            return 0
        fi
        log "Upgrading Decky Loader $version to the latest stable release (minimum v$DECKY_MIN_VERSION)"
    fi
    log "Installing Decky Loader"
    PNPM_DOWNLOAD=$(mktemp)
    curl -fL --retry 3 --output "$PNPM_DOWNLOAD" \
        "https://github.com/SteamDeckHomebrew/decky-installer/releases/download/$DECKY_INSTALLER_VERSION/install_release.sh"
    printf '%s  %s\n' "$DECKY_INSTALLER_SHA256" "$PNPM_DOWNLOAD" | sha256sum -c - \
        || die "Decky installer checksum mismatch"
    # The upstream script uses Bash syntax despite its /bin/sh shebang.
    sudo bash "$PNPM_DOWNLOAD"
    rm -f -- "$PNPM_DOWNLOAD"
    PNPM_DOWNLOAD=""
    decky_loader_installed \
        || die "Decky Loader installation did not complete"
}

plugin_owned() {
    [[ -d "$DEST_DIR" && ! -L "$DEST_DIR" ]] || return 1
    [[ -f "$DEST_DIR/.bc250-control-plugin" ]] && return 0
    [[ -f "$DEST_DIR/plugin.json" ]] || return 1
    python3 - "$DEST_DIR/plugin.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        plugin = json.load(stream)
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

raise SystemExit(
    0
    if plugin.get("name") == "BC-250 Control"
    and plugin.get("author") == "keyboardspecialist"
    else 1
)
PY
}

restart_decky() {
    log "Restarting plugin_loader"
    sudo systemctl restart plugin_loader
}

show_status() {
    require_normal_user
    local state rc=0
    if [[ -L "$DEST_DIR" || ( -e "$DEST_DIR" && ! -d "$DEST_DIR" ) ]]; then
        state="unsafe path"
        rc=1
    elif plugin_owned; then
        state="installed"
    elif [[ -e "$DEST_DIR" ]]; then
        state="unrecognized or incomplete"
        rc=1
    else
        state="not installed"
        rc=1
    fi
    printf 'plugin: %s (%s)\n' "$state" "$DEST_DIR"
    if systemctl is-active -q plugin_loader 2>/dev/null; then
        echo "Decky loader: active"
    else
        echo "Decky loader: inactive or unavailable"
    fi
    return "$rc"
}

uninstall_plugin() {
    require_normal_user
    if [[ ! -e "$DEST_DIR" && ! -L "$DEST_DIR" ]]; then
        log "'$PLUGIN_NAME' is not installed."
        return 0
    fi
    [[ ! -L "$DEST_DIR" && -d "$DEST_DIR" ]] \
        || die "refusing to remove unsafe plugin path: $DEST_DIR"
    plugin_owned \
        || die "refusing to remove an unrecognized plugin directory: $DEST_DIR"
    log "Removing $DEST_DIR (sudo)"
    sudo rm -rf -- "$DEST_DIR"
    restart_decky
    log "Uninstalled '$PLUGIN_NAME'. Shared BC-250 hardware helpers and state were preserved."
}

install_plugin() {
require_normal_user
[[ -f "$SRC_DIR/plugin.json" ]] || die "plugin.json not found next to this script"
ensure_decky_loader

# --- 2. dependencies --------------------------------------------------------

ensure_build_toolchain

# --- 3. build ---------------------------------------------------------------

cd "$SRC_DIR"
log "Installing plugin dependencies"
pnpm_build install --frozen-lockfile
log "Typechecking"
pnpm_build run typecheck
log "Building bundle"
pnpm_build run build
log "Running backend tests"
PYTHONPATH="$SRC_DIR/../backend:$SRC_DIR/../backend/vendor" \
    python3 -m unittest discover -s "$SRC_DIR/../backend/tests"
log "Staging self-contained Decky runtime"
python3 "$SRC_DIR/../scripts/stage-decky-runtime.py"

[[ -f out/dist/index.js ]] || die "staging produced no out/dist/index.js"

# --- 4. install root helper and Decky plugin -------------------------------
# Only the runtime files ship; node_modules/src/tests stay in the checkout.

log "Installing root-owned CPU tuning helper (sudo)"
for required in "$SRC_DIR/../bc250-power.sh" \
    "$SRC_DIR/../bc250-storage.sh" \
    "$SRC_DIR/../bc250-update-persistence.sh" \
    "$SRC_DIR/../acpi-tables/SSDT-CST.dsl" \
    "$SRC_DIR/../acpi-tables/SSDT-PST.dsl" \
    "${SMU_PATCH_SOURCES[@]}"; do
    [[ -f "$required" && ! -L "$required" ]] \
        || die "required root-helper source is missing or unsafe: $required"
done
sudo bash "$SRC_DIR/../bc250-storage.sh" install
sudo install -d -m 0755 "$ROOT_HELPER_DIR/acpi-tables" \
    "$ROOT_HELPER_DIR/smu-oc-patches" "$ROOT_STATE_DIR" \
    /var/lib/bc250-control/governor
sudo install -m 0755 "$SRC_DIR/../bc250-power.sh" "$ROOT_HELPER_DIR/bc250-power.sh"
sudo install -m 0755 "$SRC_DIR/../bc250-storage.sh" "$ROOT_HELPER_DIR/bc250-storage.sh"
sudo install -m 0755 "$SRC_DIR/../bc250-update-persistence.sh" "$ROOT_HELPER_DIR/bc250-update-persistence.sh"
sudo install -m 0644 "$SRC_DIR/../acpi-tables/SSDT-CST.dsl" \
    "$ROOT_HELPER_DIR/acpi-tables/SSDT-CST.dsl"
sudo install -m 0644 "$SRC_DIR/../acpi-tables/SSDT-PST.dsl" \
    "$ROOT_HELPER_DIR/acpi-tables/SSDT-PST.dsl"
sudo install -m 0644 "${SMU_PATCH_SOURCES[@]}" "$ROOT_HELPER_DIR/smu-oc-patches/"
if sudo systemctl is-enabled bc250-acpi-heal.service >/dev/null 2>&1; then
    log "Refreshing universal ACPI tables (sudo; reboot required)"
    sudo bash "$ROOT_HELPER_DIR/bc250-power.sh" acpi
fi
if sudo systemctl is-enabled cyan-skillfish-governor-smu.service >/dev/null 2>&1; then
    log "Refreshing GPU governor boot integration (sudo)"
    sudo bash "$ROOT_HELPER_DIR/bc250-power.sh" enable
fi

for prefix in "$ROOT_UMR_DIR" /etc/bc250-control/umr "$TOOLKIT_DIR" /var/lib/bc250-40cu /usr /usr/local; do
    if [[ -x "$prefix/bin/umr" ]] \
        && umr_database_complete "$prefix/share/umr/database"; then
        UMR_SOURCE="$prefix/bin/umr"
        UMR_DATABASE_SOURCE="$prefix/share/umr/database"
        break
    fi
done
if [[ -n "$UMR_SOURCE" ]]; then
    log "Installing root-owned UMR and ASIC database (sudo)"
    if [[ "$UMR_SOURCE" != "$ROOT_UMR_DIR/bin/umr" ]]; then
        UMR_STAGE=$(sudo mktemp -d /var/lib/bc250-control/.umr-install.XXXXXX)
        sudo install -d -m 0755 "$UMR_STAGE/bin" "$UMR_STAGE/share/umr/database"
        sudo install -m 0755 "$UMR_SOURCE" "$UMR_STAGE/bin/umr"
        sudo cp -RL "$UMR_DATABASE_SOURCE"/. "$UMR_STAGE/share/umr/database/"
        sudo test -s "$UMR_STAGE/share/umr/database/cyan_skillfish.asic"
        sudo test -s "$UMR_STAGE/share/umr/database/cyan_skillfish.soc15"
        sudo test -s "$UMR_STAGE/share/umr/database/ip/gc_10_1_0.reg"
        sudo chown -R root:root "$UMR_STAGE"
        sudo chmod -R go-w "$UMR_STAGE"
        sudo sync "$UMR_STAGE"
        sudo rm -rf "$ROOT_UMR_DIR"
        sudo mv "$UMR_STAGE" "$ROOT_UMR_DIR"
        sudo sync "$ROOT_UMR_DIR"
        UMR_STAGE=""
    fi
    sudo chown -R root:root "$ROOT_UMR_DIR"
    sudo chmod -R go-w "$ROOT_UMR_DIR"
    sudo rm -rf /etc/bc250-control/umr
    if sudo test -f "$CU_CONFIG" && ! sudo test -L "$CU_CONFIG"; then
        if sudo grep -q '^UMR=' "$CU_CONFIG"; then
            sudo sed -i "s|^UMR=.*|UMR=$ROOT_UMR_DIR/bin/umr|" "$CU_CONFIG"
        else
            printf 'UMR=%s\n' "$ROOT_UMR_DIR/bin/umr" | sudo tee -a "$CU_CONFIG" >/dev/null
        fi
        if sudo grep -q '^UMR_DATABASE_PATH=' "$CU_CONFIG"; then
            sudo sed -i "s|^UMR_DATABASE_PATH=.*|UMR_DATABASE_PATH=$ROOT_UMR_DIR/share/umr/database|" "$CU_CONFIG"
        else
            printf 'UMR_DATABASE_PATH=%s\n' "$ROOT_UMR_DIR/share/umr/database" | sudo tee -a "$CU_CONFIG" >/dev/null
        fi
    fi
    sudo bash "$ROOT_HELPER_DIR/bc250-update-persistence.sh" install compute
else
    log "UMR binary/database not found; live CU status and editing will remain disabled"
fi

for candidate in \
    "$TOOLKIT_DIR/bc250-cu-live-manager" \
    "$TOOLKIT_DIR/bc250-cu-live-manager.sh" \
    /var/lib/bc250-40cu/bc250-cu-live-manager \
    /var/lib/bc250-40cu/bc250-cu-live-manager.sh \
    /usr/local/bin/bc250-cu-live-manager \
    "$SRC_DIR/../bc250-cu-live-manager"; do
    if [[ -f "$candidate" && ! -L "$candidate" ]]; then
        CU_MANAGER_SOURCE="$candidate"
        break
    fi
done
if [[ -n "$CU_MANAGER_SOURCE" ]]; then
    log "Installing root-owned CU manager helper (sudo)"
    sudo install -m 0755 "$CU_MANAGER_SOURCE" "$ROOT_HELPER_DIR/bc250-cu-live-manager"
else
    log "CU manager not found; live WGP editing will remain disabled"
fi

log "Installing to $DEST_DIR (sudo)"
if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
    [[ ! -L "$DEST_DIR" && -d "$DEST_DIR" ]] \
        || die "refusing to replace unsafe plugin path: $DEST_DIR"
    plugin_owned \
        || die "refusing to replace an unrecognized plugin directory: $DEST_DIR"
fi
sudo rm -rf "$DEST_DIR"
sudo install -d "$DEST_DIR"
sudo cp -r "$SRC_DIR/out/." "$DEST_DIR/"
sudo touch "$DEST_DIR/.bc250-control-plugin"
# Flush to disk immediately — a BC-250 hard crash before writeback would
# otherwise leave the installed files as zero-byte husks.
sync

restart_decky

log "Done — '$PLUGIN_NAME' is available in the Quick Access menu (...)"
}

case "${1:-install}" in
    install)   (($# <= 1)) || die "usage: $0 [install|status|uninstall]"; install_plugin ;;
    status)    (($# == 1)) || die "usage: $0 status"; show_status ;;
    uninstall) (($# == 1)) || die "usage: $0 uninstall"; uninstall_plugin ;;
    *) die "usage: $0 [install|status|uninstall]" ;;
esac
