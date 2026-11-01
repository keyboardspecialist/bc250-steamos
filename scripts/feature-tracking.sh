#!/usr/bin/env bash
# Sourced by public component entrypoints. Run a mutation in a child so its
# existing EXIT traps, execs and rollback cleanup remain completely unchanged.

bc250_feature_read_only() {
    local argument
    for argument in "$@"; do
        case "$argument" in --help|-h|--dry-run|-n) return 0 ;; esac
    done
    case "${1:-menu}" in
        status|status-json|installed|probe|help|--help|-h|show|read|info|list|verify|ttm-verify|render|menu|payload-status|records-json|count|inventory-json|frontend-capabilities-json|foundation-ready|configured|present|policy-present|runlist-configured|runlist-active|can-uninstall|scan|monitor) return 0 ;;
    esac
    case "${1:-}:${2:-}" in
        cpu-unlock:status|cpu-oc:status|gpu-freq:show|gpu-voltage:show|cpu-mitigations:status|cpu-smt:status) return 0 ;;
    esac
    case "${1:-}" in
        freq|gpu-volt|load-target|temperature|ramp|cpu-unlock|cpu-oc|gpu-freq|gpu-voltage|cpu-mitigations|cpu-smt)
            (($# != 1)) || return 0
            case "${2:-}" in status|show|list|info|read|verify|topology) return 0 ;; esac ;;
    esac
    if [[ "${BC250_FEATURE_COMPONENT:-}" == amdgpu-options && "${1:-}" == active ]]; then return 0; fi
    [[ " $* " == *" --dry-run "* ]]
}

bc250_feature_note() {
    [[ "${BC250_FEATURE_RECORDING:-1}" != 0 ]] || return 0
    local component="$1" action="$2" result="$3" helper="$4" recorder="$BC250_FEATURE_RECORDER"
    local account home
    [[ "$action" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,63}$ ]] || action=configure
    if [[ $EUID -eq 0 ]]; then
        # Do not guess an actor for unattended root services. Graphical backends
        # record separately as their authenticated requesting user.
        account="${SUDO_USER:-}"
        [[ -n "$account" && "$account" != root ]] || return 0
        home=$(getent passwd "$account" | cut -d: -f6)
        [[ "$home" == /* ]] || return 0
        /usr/bin/runuser -u "$account" -- /usr/bin/env HOME="$home" USER="$account" LOGNAME="$account" \
            /usr/bin/python3 -I "$recorder" "$component" "$action" "$result" "$helper" \
            || echo "[bc250-tracking] Could not save the completed operation; run track-features." >&2
    else
        python3 -I "$recorder" "$component" "$action" "$result" "$helper" \
            || echo "[bc250-tracking] Could not save the completed operation; run track-features." >&2
    fi
    return 0  # A tracking failure must never hide the actual operation result.
}

bc250_feature_entry() {
    local component="$1" helper="$2" default_action="$3"; shift 3
    [[ "${BC250_FEATURE_RECORDING:-1}" != 0 ]] || return 0
    bc250_feature_read_only "${@:-$default_action}" && return 0
    [[ "${BC250_FEATURE_CHILD:-}" != "$helper" ]] || return 0
    local result=0 action="${1:-$default_action}"
    if [[ "$component" == mesh && " $* " == *" --native-mesh "* ]]; then component=native-mesh; fi
    if BC250_FEATURE_CHILD="$helper" bash "$helper" "$@"; then result=0; else result=$?; fi
    bc250_feature_note "$component" "$action" "$result" "$helper"
    exit "$result"
}

bc250_feature_note_command() {
    local result="$1" action="${2:-configure}"
    case "$action" in
        cmd_check|cmd_installed|cmd_remote|*status*|*show*|*help*|*verify*|*read*|*scan*|*monitor*) return 0 ;;
    esac
    action="${action#cmd_}"
    bc250_feature_read_only "$action" && return 0
    bc250_feature_note "$BC250_FEATURE_COMPONENT" "$action" "$result" "$BC250_FEATURE_HELPER"
}

BC250_FEATURE_RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-event.py"
BC250_FEATURE_COMPONENT="$1"
BC250_FEATURE_HELPER="${BASH_SOURCE[1]}"
bc250_feature_entry "$1" "${BASH_SOURCE[1]}" "$2" "${@:3}"
