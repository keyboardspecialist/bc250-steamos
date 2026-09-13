#!/usr/bin/env bash
# Stage and run pan-Rijovich's experimental BC-250 GDDR6 temperature payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SOURCE="$SCRIPT_DIR/memory-temperature/bc250-memory-temperature.py"
UPSTREAM_REPO="https://github.com/pan-Rijovich/bc250-memory-temperature"
UPSTREAM_COMMIT="b7e6bffcb5d592fc03edde375b7598ddc79aa846"
RAW_BASE="https://raw.githubusercontent.com/pan-Rijovich/bc250-memory-temperature/$UPSTREAM_COMMIT"
STATE_DIR="${BC250_MEMORY_TEMP_STATE_DIR:-/var/lib/bc250-memory-temperature}"
SOURCE_DIR="$STATE_DIR/upstream-$UPSTREAM_COMMIT"
HELPER="$STATE_DIR/bc250-memory-temperature.py"
MANIFEST="$STATE_DIR/install.conf"
LOCK_FILE="${BC250_MEMORY_TEMP_LOCK_FILE:-/run/lock/bc250-memory-temperature.lock}"
GOVERNOR_SERVICE="${BC250_MEMORY_TEMP_GOVERNOR_SERVICE:-cyan-skillfish-governor-smu.service}"

log() { echo "[bc250-memory-temperature] $*"; }
die() { echo "[bc250-memory-temperature] $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 || ${BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST:-0} == 1 ]] \
        || die "Run with sudo; direct SMU access requires root."
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

files() {
    cat <<'EOF'
README.md 88b0c2ead95c7e2d4e73eb4de086e0a16f8644783f9d60bf6d5322a8b47f350e
LICENSE 2c077d99237afe7b5a57ad02c515d2eee309e1149f5f0af7d346b793d43bd753
SMUPayload.bin b31908460e932a615d9eafb6b3112e6448994f9f6fa656d1d80a8616ac1df4df
main.c 15584afc9e41c02b114155e89af0e5a251cc192c1116ddd9857d57b06c7f2880
Makefile bbce1244796f0e4fd1b4e3c56a10c1530d5b031752500af28cd3c02ba304df62
smu3.ld 35910b8fa1cdfb231dd70abaea3105345438d5cddfa91bf4897f15e7ea78d3fd
unlock.py 86bc1aaa3265c7a62d28570953e6a47047a6aaa95661c6c649a5822a4165e3b4
bc250_smu/__init__.py ad87f03cc35aaa0da4e75d6e45bd56bc5baa7c1e680a25b528c3c6fce480884a
bc250_smu/api.py 7fe9beed4fa12bb8625096859ff32e8ee64ee8b9cb1265f1546b5cc7127422fc
bc250_smu/api_q0.py b1e0afa14b2a75a73d30308019ee7199733a59ad946210fae91ee2d675256ad1
bc250_smu/api_q1.py 811de63b7e3c3eb23808971ae7c6b0cc661cc52fc0d9c9b7a055aa25cfb9b31a
bc250_smu/api_q2.py cc3db581a1c8136664d4520d6d96c35449c768df621eea3c3a1c5101fa612e78
bc250_smu/api_q3.py e5f5021643d866c78a9117e15f7f085edcd19173d1e26c5282ff7b8cc660e7c3
bc250_smu/api_q4.py 011baa51294b043b7e636b3e7e441184061fe9a37534125330e28afc6fc5d2ff
bc250_smu/codec.py bb747622598b92ff43f10583ef93803bda4d6ae59b2480e74fc2abf6751db116
bc250_smu/errors.py eec00a893b809d64f176cfd375179be84643221628b571ea5b5a3bc0e753d7c4
bc250_smu/mailbox.py 2efaaa10f2d7285c2587c892f9633000ea400c93d8492d4fbf7ed1e54de3622c
bc250_smu/primitives.py 8ea7262d4b548933530889858d40fac5eeb3aaaa42dbb167e4bdeaec36b6f50b
bc250_smu/transport.py 8030084a9aae7c20e8ea787fca72f2a2bc75d9c2305d62047d6f0a5b2fe2d39d
EOF
}

ensure_state() {
    [[ ! -L "$STATE_DIR" ]] || die "Refusing symlinked state directory: $STATE_DIR"
    mkdir -p "$STATE_DIR" "${LOCK_FILE%/*}"
    chmod 0700 "$STATE_DIR"
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked lock file: $LOCK_FILE"
    if [[ ${BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST:-0} != 1 ]]; then
        [[ "$(stat -c %u "$STATE_DIR")" == 0 ]] \
            || die "State directory must be owned by root: $STATE_DIR"
        local mode
        mode=$(stat -c %a "$STATE_DIR")
        (( (8#$mode & 8#077) == 0 )) \
            || die "State directory must not be accessible by group or other users: $STATE_DIR"
    fi
}

verify_stage() {
    local relative expected
    [[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" \
        && -f "$HELPER" && ! -L "$HELPER" && -f "$MANIFEST" && ! -L "$MANIFEST" ]] \
        || return 1
    while read -r relative expected; do
        [[ -f "$SOURCE_DIR/$relative" && ! -L "$SOURCE_DIR/$relative" \
            && "$(sha256_file "$SOURCE_DIR/$relative")" == "$expected" ]] || return 1
    done < <(files)
    local commit helper_sha extra
    read -r commit helper_sha extra < "$MANIFEST" || return 1
    [[ -z "$extra" && "$commit" == "$UPSTREAM_COMMIT" \
        && "$helper_sha" =~ ^[0-9a-f]{64}$ \
        && "$(sha256_file "$HELPER")" == "$helper_sha" ]]
}

fetch_verified() {
    local relative="$1" expected="$2" target="$3/$relative" tmp actual
    mkdir -p "${target%/*}"
    tmp=$(mktemp "${target%/*}/.${relative##*/}.XXXXXX")
    curl --retry 3 --retry-all-errors -fsSL "$RAW_BASE/$relative" -o "$tmp" \
        || { rm -f "$tmp"; die "Could not fetch upstream $relative"; }
    actual=$(sha256_file "$tmp")
    [[ "$actual" == "$expected" ]] \
        || { rm -f "$tmp"; die "Checksum mismatch for upstream $relative"; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

cmd_prepare() (
    require_root
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    command -v flock >/dev/null 2>&1 || die "flock is required."
    [[ -f "$HELPER_SOURCE" && ! -L "$HELPER_SOURCE" ]] \
        || die "Toolkit helper is missing or unsafe: $HELPER_SOURCE"
    ensure_state
    exec 9> "$LOCK_FILE"
    flock 9
    if verify_stage; then
        log "Pinned upstream source is already staged and verified."
        return 0
    fi
    local stage="" relative expected helper_sha
    cleanup_prepare() {
        if [[ -n "$stage" ]]; then rm -rf "$stage"; fi
    }
    trap cleanup_prepare EXIT INT TERM HUP
    stage=$(mktemp -d "$STATE_DIR/.upstream.XXXXXX")
    while read -r relative expected; do
        fetch_verified "$relative" "$expected" "$stage"
    done < <(files)
    rm -rf "$SOURCE_DIR"
    mv "$stage" "$SOURCE_DIR"
    stage=""
    install -m 0755 "$HELPER_SOURCE" "$HELPER"
    helper_sha=$(sha256_file "$HELPER")
    printf '%s %s\n' "$UPSTREAM_COMMIT" "$helper_sha" > "$MANIFEST"
    chmod 0600 "$MANIFEST"
    verify_stage || die "Staged memory-temperature source failed verification."
    log "Staged and verified $UPSTREAM_REPO at ${UPSTREAM_COMMIT:0:7}."
)

run_smu_action() (
    local action="$1"
    shift
    require_root
    command -v flock >/dev/null 2>&1 || die "flock is required."
    ensure_state
    exec 9> "$LOCK_FILE"
    flock 9
    verify_stage || die "Verified source is not staged; run '$0 prepare' first."
    local governor_stopped=0
    resume_governor() {
        local rc=$?
        trap - EXIT INT TERM HUP
        if [[ $governor_stopped -eq 1 ]]; then
            systemctl start "$GOVERNOR_SERVICE" \
                || { log "WARNING: could not restart $GOVERNOR_SERVICE" >&2; rc=1; }
        fi
        exit "$rc"
    }
    trap resume_governor EXIT INT TERM HUP
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet "$GOVERNOR_SERVICE"; then
        log "Pausing $GOVERNOR_SERVICE for exclusive SMU access."
        governor_stopped=1
        systemctl stop "$GOVERNOR_SERVICE" \
            || die "Could not stop the GPU governor; refusing concurrent SMU access."
    fi
    python3 "$HELPER" "$action" --source-dir "$SOURCE_DIR" --state-dir "$STATE_DIR" "$@"
)

cmd_status() {
    echo "BC-250 GDDR6 memory-temperature tool"
    echo "  upstream: $UPSTREAM_REPO @ ${UPSTREAM_COMMIT:0:7}"
    if verify_stage; then
        echo "  source:   prepared and verified"
    elif [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        echo "  source:   incomplete or modified"
        return 2
    else
        echo "  source:   not prepared"
        return 1
    fi
    if [[ -f "$STATE_DIR/original-smu.json" && ! -L "$STATE_DIR/original-smu.json" ]]; then
        echo "  backup:   original runtime bytes recorded"
        echo "  warning:  use 'read' to attest whether the live payload is still active"
    else
        echo "  backup:   none"
    fi
}

cmd_purge() {
    require_root
    ensure_state
    exec 9> "$LOCK_FILE"
    flock 9
    [[ ! -e "$STATE_DIR/original-smu.json" && ! -L "$STATE_DIR/original-smu.json" ]] \
        || die "An original-SMU backup remains; restore the live patch or cold-power-cycle before deleting it."
    rm -rf "$STATE_DIR"
    log "Removed staged source and toolkit state."
}

cmd_help() {
    cat <<EOF
Usage: $0 {prepare|patch --acknowledge-smu-risk|read [--json]|
           restore --acknowledge-smu-risk|status|purge|help}

  prepare  Download and checksum-verify the pinned upstream source and payload.
  patch    Unlock live SMU access, back up overwritten bytes, install the
           runtime payload, and redirect Queue 3 / Message 5.
  read     Attest the live payload and read all eight GDDR6 MR3 temperatures.
  restore  Restore the recorded handler and overwritten runtime bytes.
  status   Report staged-source and backup state without touching the SMU.
  purge    Remove staged files only after no runtime backup remains.

The patch is only for the ASRock BC-250 P3.0 firmware layout. It is not a boot
service and does not survive a cold power cycle. The upstream payload contains
unbounded firmware polling loops. A wrong or wedged payload can cause memory or
filesystem corruption, crashes, an unbootable system, or require a cold power
cycle. The explicit acknowledgement flag is required for live writes.

Upstream (pinned to $UPSTREAM_COMMIT):
  $UPSTREAM_REPO
EOF
}

case "${1:-help}" in
    prepare) (($# == 1)) || die "Usage: $0 prepare"; cmd_prepare ;;
    patch)
        (($# == 2)) && [[ "$2" == --acknowledge-smu-risk ]] \
            || die "Usage: $0 patch --acknowledge-smu-risk"
        run_smu_action patch --acknowledge-smu-risk ;;
    read)
        if (($# == 1)); then run_smu_action read
        elif (($# == 2)) && [[ "$2" == --json ]]; then run_smu_action read --json
        else die "Usage: $0 read [--json]"; fi ;;
    restore)
        (($# == 2)) && [[ "$2" == --acknowledge-smu-risk ]] \
            || die "Usage: $0 restore --acknowledge-smu-risk"
        run_smu_action restore --acknowledge-smu-risk ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    purge) (($# == 1)) || die "Usage: $0 purge"; cmd_purge ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 2 ;;
esac
