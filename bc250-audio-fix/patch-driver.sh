#!/bin/bash
# Single entry point: fetch sources, build, install — the full cycle after a
# SteamOS update. Run as the normal user; sudo is invoked for install only.
#
#   ./patch-driver.sh [--cg|--cg-unvalidated] [kernel-tree]  (default: ./valve-kernel)
#   ./patch-driver.sh status
#   ./patch-driver.sh uninstall
#
# --cg / --cg-unvalidated are forwarded to build.sh (EXPERIMENTAL clock-gating
# patches, see build.sh); fetch-sources.sh doesn't know them, so they're
# filtered out there.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
    cat <<EOF
Usage: $0 [--cg|--cg-unvalidated] [kernel-tree]
       $0 status
       $0 uninstall

Run as the logged-in user. Install and uninstall request sudo only for their
privileged steps. Uninstall preserves source, downloads, and build output.
EOF
}

show_status() {
    local module rel resolved marker found=0 failed=0

    for module in /usr/lib/modules/*/updates/amdgpu.ko.zst; do
        [ -e "$module" ] || [ -L "$module" ] || continue
        found=1
        rel=${module#/usr/lib/modules/}
        rel=${rel%%/*}
        marker="/usr/lib/modules/$rel/updates/.bc250-audio-fix"
        if [ ! -f "$module" ] || [ -L "$module" ]; then
            echo "[bc250-audio] $rel: unsafe or incomplete override ($module)"
            failed=1
            continue
        fi
        if [ ! -f "$marker" ] || [ -L "$marker" ]; then
            echo "[bc250-audio] $rel: unmarked override requires ownership review"
            failed=1
            continue
        fi
        if resolved=$(modinfo -k "$rel" -F filename amdgpu 2>/dev/null) \
           && [[ "$resolved" == */updates/amdgpu.ko* ]]; then
            echo "[bc250-audio] $rel: installed ($resolved)"
        else
            echo "[bc250-audio] $rel: override present but not selected"
            failed=1
        fi
    done
    for marker in /usr/lib/modules/*/updates/.bc250-audio-fix; do
        [ -e "$marker" ] || [ -L "$marker" ] || continue
        module="${marker%/.bc250-audio-fix}/amdgpu.ko.zst"
        [ -e "$module" ] || { found=1; failed=1; echo "[bc250-audio] pending rollback marker: $marker"; }
    done
    if [ "$found" = 0 ]; then
        echo "[bc250-audio] state: not-installed"
        return 1
    fi
    [ "$failed" = 0 ] \
        && echo "[bc250-audio] state: installed" \
        || echo "[bc250-audio] state: incomplete"
    return "$failed"
}

confirm_legacy_adoption() {
    local answer
    [ -t 0 ] && [ -t 1 ] || return 1
    printf '%s' 'Type ADOPT LEGACY AUDIO to remove an unmarked older override: '
    IFS= read -r answer
    [ "$answer" = "ADOPT LEGACY AUDIO" ]
}

run_audio_rollback() {
    local rc=0 adopted=0
    sudo "$HERE/rollback.sh" --all || rc=$?
    if [ "$rc" = 3 ]; then
        confirm_legacy_adoption || return "$rc"
        adopted=1
        sudo "$HERE/rollback.sh" --all --adopt-legacy
    elif [ "$rc" != 0 ]; then
        return "$rc"
    fi

    rc=0
    if [ "$adopted" = 1 ]; then
        sudo "$HERE/cleanup-other-slot.sh" --skip-current --adopt-legacy || rc=$?
    else
        sudo "$HERE/cleanup-other-slot.sh" --skip-current || rc=$?
    fi
    if [ "$rc" = 3 ] && [ "$adopted" = 0 ]; then
        confirm_legacy_adoption || return "$rc"
        sudo "$HERE/cleanup-other-slot.sh" --skip-current --adopt-legacy
    elif [ "$rc" != 0 ]; then
        return "$rc"
    fi
}

case "${1:-}" in
    status)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        show_status
        exit
        ;;
    uninstall)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        [ "$(id -u)" != 0 ] || { echo "run as the logged-in user; this command requests sudo for rollback" >&2; exit 1; }
        command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
        exec 9>"$HERE/.prepare-kernel.lock"
        flock 9
        run_audio_rollback
        echo "[bc250-audio] source, downloads, and build output were preserved"
        exit
        ;;
    help|-h|--help)
        usage
        exit
        ;;
esac

[ "$(id -u)" != 0 ] || { echo "run as the normal user - sudo is used for the install step only"; exit 1; }
command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
exec 9>"$HERE/.prepare-kernel.lock"
flock 9

WITH_CG=()
ARGS=()
for a in "$@"; do
    case "$a" in
        --cg)             WITH_CG=(--cg) ;;
        --cg-unvalidated) WITH_CG=(--cg-unvalidated) ;;
        *)                ARGS+=("$a") ;;
    esac
done

"$HERE/fetch-sources.sh" "${ARGS[@]}"
"$HERE/build.sh" "${WITH_CG[@]}" "${ARGS[@]}"
sudo "$HERE/install.sh"
