#!/bin/bash
# Single entry point: fetch sources, build, install — the full cycle after a
# SteamOS update. Run as the normal user; sudo is invoked for missing build
# prerequisites and installation.
#
#   ./patch-driver.sh [kernel-tree]  (default: ./valve-kernel)
#   ./patch-driver.sh status
#   ./patch-driver.sh status-json
#   ./patch-driver.sh uninstall
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TREE_DRIFT_EXIT=75
GFX1013_COMMIT=d3e6dc062c34d2523db0abe5741d1f5b0dea00d9

usage() {
    cat <<EOF
Usage: $0 [kernel-tree]
       $0 status
       $0 status-json
       $0 uninstall

Run as the logged-in user. The build requests sudo if a SteamOS update removed
its host toolchain. Install and uninstall also request sudo for privileged
steps. Uninstall preserves source, downloads, and build output.
EOF
}

show_status_json() {
    local rel updates default_module default_audio_marker default_metrics_marker
    local default_gfx1013_marker default_active module audio_marker metrics_marker
    local gfx1013_marker active resolved selected_path module_path actual expected
    local owner mode state artifact_present=0 override_installed=1
    local override_selected=0 active_ready=0 boot_present=0 marker path

    rel=$(uname -r)
    updates="/usr/lib/modules/$rel/updates"
    default_module="$updates/amdgpu.ko.zst"
    default_audio_marker="$updates/.bc250-audio-fix"
    default_metrics_marker="$updates/.bc250-metrics-fix"
    default_gfx1013_marker="$updates/.bc250-gfx1013-fix"
    default_active=/sys/module/amdgpu/parameters/bc250_gfx1013_fix
    module=${BC250_GFX1013_MODULE:-$default_module}
    audio_marker=${BC250_AUDIO_MARKER:-$default_audio_marker}
    metrics_marker=${BC250_METRICS_MARKER:-$default_metrics_marker}
    gfx1013_marker=${BC250_GFX1013_MARKER:-$default_gfx1013_marker}
    active=${BC250_GFX1013_ACTIVE:-$default_active}

    for path in "$module" "$audio_marker" "$metrics_marker" "$gfx1013_marker"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            artifact_present=1
        fi
    done

    if [ ! -f "$module" ] || [ -L "$module" ]; then
        override_installed=0
    else
        actual=$(sha256sum "$module" 2>/dev/null | awk '{print $1}') || actual=
        [[ "$actual" =~ ^[0-9a-f]{64}$ ]] || override_installed=0
        for marker in "$audio_marker" "$metrics_marker" "$gfx1013_marker"; do
            if [ ! -f "$marker" ] || [ -L "$marker" ]; then
                override_installed=0
                continue
            fi
            read -r expected < "$marker" || expected=
            [[ "$expected" =~ ^[0-9a-f]{64}$ && "$expected" == "$actual" ]] \
                || override_installed=0
        done

        for path in "$module" "$audio_marker" "$metrics_marker" "$gfx1013_marker"; do
            case "$path" in
                "$default_module"|"$default_audio_marker"|"$default_metrics_marker"|"$default_gfx1013_marker")
                    read -r owner mode < <(stat -Lc '%u %a' "$path" 2>/dev/null) \
                        || { override_installed=0; continue; }
                    [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] \
                        && (( (8#$mode & 8#022) == 0 )) \
                        || override_installed=0
                    ;;
            esac
        done
    fi

    if resolved=$(modinfo -k "$rel" -F filename amdgpu 2>/dev/null); then
        selected_path=$(readlink -f "$resolved" 2>/dev/null) || selected_path=
        module_path=$(readlink -f "$module" 2>/dev/null) || module_path=
        if [ -n "$selected_path" ] && [ "$selected_path" = "$module_path" ] \
           && { [ -e "$module" ] || [ -L "$module" ]; }; then
            override_selected=1
        fi
    fi

    if [ -r "$active" ] && [ ! -L "$active" ]; then
        read -r expected < "$active" || expected=
        [ "$expected" = "$GFX1013_COMMIT" ] && active_ready=1
    fi

    if [ -f "${BC250_AMDGPU_BOOT_CONFIG:-$HERE/boot-config.sh}" ] \
       && [ ! -L "${BC250_AMDGPU_BOOT_CONFIG:-$HERE/boot-config.sh}" ] \
       && bash "${BC250_AMDGPU_BOOT_CONFIG:-$HERE/boot-config.sh}" present >/dev/null 2>&1; then
        boot_present=1
    fi

    if [ "$artifact_present" = 0 ]; then
        if [ "$boot_present" = 1 ] || [ -e "$active" ] || [ -L "$active" ]; then
            state=invalid
        else
            state=not-installed
        fi
    elif [ "$override_installed" = 1 ] && [ "$override_selected" = 1 ]; then
        if [ "$active_ready" = 1 ]; then
            state=ready
        else
            state=reboot-required
        fi
    else
        state=invalid
    fi

    printf '{"scriptAvailable":true,"runningKernel":"%s","state":"%s","overrideInstalled":%s,"overrideSelected":%s,"activeReady":%s,"rebootRequired":%s}\n' \
        "$rel" "$state" \
        "$([ "$override_installed" = 1 ] && printf true || printf false)" \
        "$([ "$override_selected" = 1 ] && printf true || printf false)" \
        "$([ "$active_ready" = 1 ] && printf true || printf false)" \
        "$([ "$state" = reboot-required ] && printf true || printf false)"
}

show_status() {
    local module rel resolved marker metrics_marker gfx1013_marker expected gfx1013_expected actual found=0 failed=0 module_found=0

    for module in /usr/lib/modules/*/updates/amdgpu.ko.zst; do
        [ -e "$module" ] || [ -L "$module" ] || continue
        found=1
        module_found=1
        rel=${module#/usr/lib/modules/}
        rel=${rel%%/*}
        marker="/usr/lib/modules/$rel/updates/.bc250-audio-fix"
        metrics_marker="/usr/lib/modules/$rel/updates/.bc250-metrics-fix"
        gfx1013_marker="/usr/lib/modules/$rel/updates/.bc250-gfx1013-fix"
        if [ ! -f "$module" ] || [ -L "$module" ]; then
            echo "[bc250-amdgpu] $rel: unsafe or incomplete override ($module)"
            failed=1
            continue
        fi
        if [ ! -f "$marker" ] || [ -L "$marker" ]; then
            echo "[bc250-amdgpu] $rel: unmarked override requires ownership review"
            failed=1
            continue
        fi
        if resolved=$(modinfo -k "$rel" -F filename amdgpu 2>/dev/null) \
           && [[ "$resolved" == */updates/amdgpu.ko* ]]; then
            if [ -f "$metrics_marker" ] && [ ! -L "$metrics_marker" ] \
               && [ -f "$gfx1013_marker" ] && [ ! -L "$gfx1013_marker" ]; then
                read -r expected < "$metrics_marker" || expected=
                actual=$(sha256sum "$module" | awk '{print $1}')
                read -r gfx1013_expected < "$gfx1013_marker" || gfx1013_expected=
                if [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] \
                   && [ "$gfx1013_expected" = "$actual" ]; then
                    echo "[bc250-amdgpu] $rel: installed, metrics and compute aware ($resolved)"
                else
                    echo "[bc250-amdgpu] $rel: invalid metrics or compute marker"
                    failed=1
                fi
            else
                echo "[bc250-amdgpu] $rel: installed, legacy audio-only build"
                failed=1
            fi
        else
            echo "[bc250-amdgpu] $rel: override present but not selected"
            failed=1
        fi
    done
    if [ "$module_found" = 1 ]; then
        found=1
        if "$HERE/boot-config.sh" present; then
            "$HERE/boot-config.sh" status || failed=1
        else
            echo "[bc250-amdgpu] scheduler policy: deferred until Mesa / RADV setup"
        fi
    elif "$HERE/boot-config.sh" present; then
        found=1
        "$HERE/boot-config.sh" status || true
        echo "[bc250-amdgpu] AMDGPU boot options are present without a module override"
        failed=1
    fi
    for marker in /usr/lib/modules/*/updates/.bc250-audio-fix \
                  /usr/lib/modules/*/updates/.bc250-metrics-fix \
                  /usr/lib/modules/*/updates/.bc250-gfx1013-fix; do
        [ -e "$marker" ] || [ -L "$marker" ] || continue
        module=${marker%/*}/amdgpu.ko.zst
        [ -e "$module" ] || { found=1; failed=1; echo "[bc250-amdgpu] pending rollback marker: $marker"; }
    done
    if [ "$found" = 0 ]; then
        echo "[bc250-amdgpu] state: not-installed"
        return 1
    fi
    [ "$failed" = 0 ] \
        && echo "[bc250-amdgpu] state: installed" \
        || echo "[bc250-amdgpu] state: incomplete"
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
    sudo env BC250_PRESERVE_AMDGPU_BOOT_CONFIG=1 \
        "$HERE/rollback.sh" --all || rc=$?
    if [ "$rc" = 3 ]; then
        confirm_legacy_adoption || return "$rc"
        adopted=1
        sudo env BC250_PRESERVE_AMDGPU_BOOT_CONFIG=1 \
            "$HERE/rollback.sh" --all --adopt-legacy
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
    sudo env BC250_FORCE_GRUB_REGEN=1 "$HERE/boot-config.sh" remove
}

case "${1:-}" in
    status)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        show_status
        exit
        ;;
    status-json)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        show_status_json
        exit
        ;;
    uninstall)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        [ "$(id -u)" != 0 ] || { echo "run as the logged-in user; this command requests sudo for rollback" >&2; exit 1; }
        command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
        exec 9>"$HERE/.prepare-kernel.lock"
        flock 9
        run_audio_rollback
        echo "[bc250-amdgpu] source, downloads, and build output were preserved"
        exit
        ;;
    help|-h|--help)
        usage
        exit
        ;;
esac

[ "$(id -u)" != 0 ] || { echo "run as the normal user - sudo is used only for privileged steps"; exit 1; }
"$HERE/ensure-build-prereqs.sh"
command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
exec 9>"$HERE/.prepare-kernel.lock"
flock 9

"$HERE/fetch-sources.sh" "$@"
build_rc=0
"$HERE/build.sh" "$@" || build_rc=$?
if [ "$build_rc" = "$TREE_DRIFT_EXIT" ]; then
    echo "[bc250-amdgpu] The kernel source tree diverged from the expected patched state." >&2
    if [ -t 0 ] && [ -t 1 ]; then
        printf '%s' "Clean the build tree and retry? Cached downloads and dependencies will be kept. [y/N] "
        IFS= read -r answer
        case "$answer" in
            y|Y|yes|YES)
                "$HERE/clean.sh" "$@"
                "$HERE/fetch-sources.sh" "$@"
                "$HERE/build.sh" "$@"
                ;;
            *) exit "$build_rc" ;;
        esac
    else
        echo "[bc250-amdgpu] Run '$HERE/clean.sh' and retry." >&2
        exit "$build_rc"
    fi
elif [ "$build_rc" != 0 ]; then
    exit "$build_rc"
fi
sudo "$HERE/install.sh"
