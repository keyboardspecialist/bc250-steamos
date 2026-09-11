#!/usr/bin/env bash
# Install the pinned BC-250 FSR4 DLL into one compatible game or OptiScaler tree.
set -euo pipefail

RELEASE="${BC250_FSR4_RELEASE:-v4.0.0-rc8}"
[[ "$RELEASE" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] \
    || { printf '[bc250-fsr4] Invalid release identifier.\n' >&2; exit 1; }
ARCHIVE_NAME="bc250-fsr4-dll-${RELEASE#v}.tar.xz"
ARCHIVE_URL="https://github.com/daniel-h-0/bc250-fsr4-fork/releases/download/$RELEASE/$ARCHIVE_NAME"
ARCHIVE_SHA256="${BC250_FSR4_ARCHIVE_SHA256:-805a3df9cef931decd42d02eaffb375f95844afce2e13d78bad757a27c806da2}"
DLL_SHA256="${BC250_FSR4_DLL_SHA256:-f8816fed46bce60179228a58905e16788f021fad0b68c08d1e3555564093b2b4}"
DLL_NAME=amd_fidelityfx_upscaler_dx12.dll
MESH_STATE="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
STATE_DIR="${BC250_FSR4_STATE_DIR:-$MESH_STATE/fsr4-dll}"
CACHE_DIR="$STATE_DIR/cache"
INSTALLS_DIR="$STATE_DIR/installs"
RELEASE_DIR="$CACHE_DIR/$RELEASE"
ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
LOCK_FILE="${BC250_FSR4_LOCK_FILE:-$HOME/.cache/bc250-fsr4.lock}"

log() { printf '[bc250-fsr4] %s\n' "$*"; }
die() { log "$*" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

fsync_paths() {
    python3 - "$@" <<'PY'
import os
import sys

for value in sys.argv[1:]:
    descriptor = os.open(value, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "Run as the logged-in user, not with sudo."
}

ensure_state() {
    command -v flock >/dev/null 2>&1 || die "flock is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    [[ ! -L "$STATE_DIR" && ! -L "$CACHE_DIR" && ! -L "$INSTALLS_DIR" ]] \
        || die "Refusing symlinked FSR4 state."
    mkdir -p "$CACHE_DIR" "$INSTALLS_DIR" "${LOCK_FILE%/*}"
    chmod 0700 "$STATE_DIR" "$CACHE_DIR" "$INSTALLS_DIR"
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked FSR4 lock file."
}

normalize_target() {
    local input=$1
    [[ -n "$input" && "$input" != *$'\n'* && "$input" != *$'\r'* \
        && "${input,,}" == *.dll ]] \
        || die "Target must be a DLL path without line breaks."
    [[ ! -L "$input" ]] || die "Target DLL must not be a symlink: $input"
    REAL_TARGET=$(realpath -m -- "$input")
    [[ "$REAL_TARGET" == /* ]] || die "Could not resolve target path: $input"
}

target_id() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

copy_atomic() {
    local source=$1 target=$2 mode=$3 temporary
    [[ -d "${target%/*}" && ! -L "$target" ]] \
        || die "Target directory is missing or target is a symlink: $target"
    temporary=$(mktemp "${target}.bc250-fsr4.XXXXXX")
    if ! install -m "$mode" "$source" "$temporary"; then
        rm -f "$temporary"
        die "Could not stage replacement for $target"
    fi
    fsync_paths "$temporary"
    if ! mv -f -- "$temporary" "$target"; then
        rm -f "$temporary"
        die "Could not replace $target"
    fi
    fsync_paths "$target" "${target%/*}"
}

verify_release_payload() {
    [[ -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" \
        && -f "$RELEASE_DIR/$DLL_NAME" && ! -L "$RELEASE_DIR/$DLL_NAME" \
        && "$(sha256_file "$RELEASE_DIR/$DLL_NAME")" == "$DLL_SHA256" \
        && -f "$RELEASE_DIR/README.md" && ! -L "$RELEASE_DIR/README.md" \
        && -f "$RELEASE_DIR/notices/PROVENANCE.md" \
        && ! -L "$RELEASE_DIR/notices/PROVENANCE.md" ]]
}

stage_release() {
    local source_archive=${BC250_FSR4_ARCHIVE:-} temporary stage
    if verify_release_payload; then return 0; fi
    rm -rf "$RELEASE_DIR"
    if [[ -n "$source_archive" ]]; then
        [[ -f "$source_archive" && ! -L "$source_archive" ]] \
            || die "Local FSR4 archive is missing or unsafe: $source_archive"
        [[ "$(sha256_file "$source_archive")" == "$ARCHIVE_SHA256" ]] \
            || die "Local FSR4 archive checksum mismatch."
        temporary=$(mktemp "$CACHE_DIR/.archive.XXXXXX")
        install -m 0600 "$source_archive" "$temporary"
        mv -f "$temporary" "$ARCHIVE"
    elif [[ ! -f "$ARCHIVE" || -L "$ARCHIVE" \
        || "$(sha256_file "$ARCHIVE")" != "$ARCHIVE_SHA256" ]]; then
        rm -f "$ARCHIVE"
        temporary=$(mktemp "$CACHE_DIR/.archive.XXXXXX")
        curl --retry 3 --retry-all-errors -fsSL "$ARCHIVE_URL" -o "$temporary" \
            || { rm -f "$temporary"; die "Could not download $ARCHIVE_URL"; }
        [[ "$(sha256_file "$temporary")" == "$ARCHIVE_SHA256" ]] \
            || { rm -f "$temporary"; die "Downloaded FSR4 archive checksum mismatch."; }
        chmod 0600 "$temporary"
        mv -f "$temporary" "$ARCHIVE"
    fi
    [[ "$(sha256_file "$ARCHIVE")" == "$ARCHIVE_SHA256" ]] \
        || die "Cached FSR4 archive checksum mismatch."
    stage=$(mktemp -d "$CACHE_DIR/.release.XXXXXX")
    if ! tar -xJf "$ARCHIVE" --no-same-owner --no-same-permissions -C "$stage"; then
        rm -rf "$stage"
        die "Could not extract the verified FSR4 archive."
    fi
    [[ -f "$stage/$DLL_NAME" && ! -L "$stage/$DLL_NAME" \
        && "$(sha256_file "$stage/$DLL_NAME")" == "$DLL_SHA256" \
        && -f "$stage/README.md" && -d "$stage/notices" ]] \
        || { rm -rf "$stage"; die "Extracted FSR4 payload failed validation."; }
    chmod -R go-w "$stage"
    mv "$stage" "$RELEASE_DIR"
    verify_release_payload || die "Installed FSR4 release cache failed validation."
}

read_record() {
    local record=$1 line extra expected_id
    [[ -d "$record" && ! -L "$record" \
        && -f "$record/target" && ! -L "$record/target" \
        && -f "$record/original.dll" && ! -L "$record/original.dll" \
        && -f "$record/install.conf" && ! -L "$record/install.conf" ]] || return 1
    IFS= read -r RECORD_TARGET < "$record/target" || return 1
    IFS= read -r line < "$record/install.conf" || return 1
    read -r RECORD_RELEASE RECORD_DLL_SHA RECORD_ORIGINAL_SHA RECORD_MODE extra <<< "$line"
    [[ -z "$extra" && "$RECORD_TARGET" == /* && "$RECORD_TARGET" != *$'\n'* \
        && "$RECORD_TARGET" != *$'\r'* \
        && "${RECORD_TARGET,,}" == *.dll \
        && "$RECORD_RELEASE" =~ ^v[0-9][0-9A-Za-z._-]*$ \
        && "$RECORD_DLL_SHA" =~ ^[0-9a-f]{64}$ \
        && "$RECORD_ORIGINAL_SHA" =~ ^[0-9a-f]{64}$ \
        && "$RECORD_MODE" =~ ^[0-7]{3,4}$ \
        && "$(wc -l < "$record/target")" -eq 1 \
        && "$(wc -l < "$record/install.conf")" -eq 1 \
        && "$(sha256_file "$record/original.dll")" == "$RECORD_ORIGINAL_SHA" ]] \
        || return 1
    expected_id=$(target_id "$RECORD_TARGET")
    [[ "${record##*/}" == "$expected_id" ]]
}

record_state() {
    local actual
    if [[ ! -e "$RECORD_TARGET" && ! -L "$RECORD_TARGET" ]]; then
        printf 'missing\n'
        return
    fi
    [[ -f "$RECORD_TARGET" && ! -L "$RECORD_TARGET" ]] \
        || { printf 'modified\n'; return; }
    actual=$(sha256_file "$RECORD_TARGET")
    if [[ "$actual" == "$RECORD_DLL_SHA" ]]; then
        printf 'ready\n'
    elif [[ "$actual" == "$RECORD_ORIGINAL_SHA" ]]; then
        printf 'restored\n'
    else
        printf 'modified\n'
    fi
}

install_target() {
    local input=$1 id record record_tmp original_sha mode state release_staged=0
    normalize_target "$input"
    [[ -f "$REAL_TARGET" && ! -L "$REAL_TARGET" ]] \
        || die "Target DLL is missing or is a symlink: $REAL_TARGET"
    id=$(target_id "$REAL_TARGET")
    record="$INSTALLS_DIR/$id"
    if [[ -e "$record" || -L "$record" ]]; then
        read_record "$record" || die "Existing FSR4 record is malformed: $record"
        state=$(record_state)
        if [[ "$state" == ready ]]; then
            if [[ "$RECORD_RELEASE" == "$RELEASE" \
                && "$RECORD_DLL_SHA" == "$DLL_SHA256" ]]; then
                log "$RELEASE is already installed at $REAL_TARGET"
                return 0
            fi
            stage_release
            release_staged=1
            log "Restoring $RECORD_RELEASE before upgrading $REAL_TARGET to $RELEASE"
            uninstall_record "$record"
        else
            [[ "$state" == restored ]] \
                || die "Target changed outside the toolkit; refusing replacement: $REAL_TARGET"
            rm -rf "$record"
            fsync_paths "$INSTALLS_DIR"
        fi
    elif [[ "$(sha256_file "$REAL_TARGET")" == "$DLL_SHA256" ]]; then
        die "Target already contains RC8 without a toolkit rollback record: $REAL_TARGET"
    fi

    if [[ $release_staged -eq 0 ]]; then stage_release; fi
    original_sha=$(sha256_file "$REAL_TARGET")
    mode=$(stat -c %a "$REAL_TARGET")
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "Could not preserve target mode."
    record_tmp=$(mktemp -d "$INSTALLS_DIR/.record.XXXXXX")
    install -m 0600 "$REAL_TARGET" "$record_tmp/original.dll"
    [[ "$(sha256_file "$record_tmp/original.dll")" == "$original_sha" ]] \
        || { rm -rf "$record_tmp"; die "Target changed while its rollback backup was being created."; }
    printf '%s\n' "$REAL_TARGET" > "$record_tmp/target"
    printf '%s %s %s %s\n' "$RELEASE" "$DLL_SHA256" "$original_sha" "$mode" \
        > "$record_tmp/install.conf"
    chmod 0600 "$record_tmp/target" "$record_tmp/install.conf"
    fsync_paths "$record_tmp/original.dll" "$record_tmp/target" \
        "$record_tmp/install.conf" "$record_tmp"
    mv "$record_tmp" "$record"
    fsync_paths "$INSTALLS_DIR"

    if [[ ! -f "$REAL_TARGET" || -L "$REAL_TARGET" \
        || "$(sha256_file "$REAL_TARGET")" != "$original_sha" ]]; then
        rm -rf "$record"
        fsync_paths "$INSTALLS_DIR"
        die "Target changed before replacement; no FSR4 DLL was installed."
    fi
    copy_atomic "$RELEASE_DIR/$DLL_NAME" "$REAL_TARGET" "$mode"
    if [[ "$(sha256_file "$REAL_TARGET")" != "$DLL_SHA256" ]]; then
        die "Installed DLL changed before verification; the rollback record was retained for manual recovery."
    fi
    log "Installed BC-250 FSR4 $RELEASE at $REAL_TARGET"
    log "Original preserved at $record/original.dll"
    log 'OptiScaler launch option: PROTON_FSR4_UPGRADE=0 PROTON_USE_OPTISCALER=0 WINEDLLOVERRIDES="winmm=n,b;amdxcffx64=" %command%'
}

uninstall_record() {
    local record=$1 state
    read_record "$record" || die "FSR4 record is malformed: $record"
    state=$(record_state)
    case "$state" in
        ready|missing)
            copy_atomic "$record/original.dll" "$RECORD_TARGET" "$RECORD_MODE"
            [[ "$(sha256_file "$RECORD_TARGET")" == "$RECORD_ORIGINAL_SHA" ]] \
                || die "Restored DLL failed verification: $RECORD_TARGET"
            ;;
        restored) ;;
        *) die "Target changed outside the toolkit; refusing to overwrite it: $RECORD_TARGET" ;;
    esac
    rm -rf "$record"
    fsync_paths "$INSTALLS_DIR"
    log "Restored original DLL at $RECORD_TARGET"
}

uninstall_target() {
    local input=$1 id record
    normalize_target "$input"
    id=$(target_id "$REAL_TARGET")
    record="$INSTALLS_DIR/$id"
    [[ -e "$record" && ! -L "$record" ]] \
        || die "No toolkit FSR4 installation is recorded for $REAL_TARGET"
    uninstall_record "$record"
}

probe_installs() {
    local record found=0 failed=0 state
    if [[ -L "$STATE_DIR" || -L "$CACHE_DIR" || -L "$INSTALLS_DIR" ]]; then return 2; fi
    [[ -d "$INSTALLS_DIR" ]] || return 1
    for record in "$INSTALLS_DIR"/*; do
        [[ -e "$record" || -L "$record" ]] || continue
        found=1
        if ! read_record "$record"; then failed=1; continue; fi
        state=$(record_state)
        [[ "$state" == ready && "$RECORD_RELEASE" == "$RELEASE" \
            && "$RECORD_DLL_SHA" == "$DLL_SHA256" ]] || failed=1
    done
    [[ $found -eq 1 ]] || return 1
    [[ $failed -eq 0 ]] || return 2
}

show_status() {
    local record found=0 failed=0 state
    if [[ -L "$STATE_DIR" || -L "$CACHE_DIR" || -L "$INSTALLS_DIR" ]]; then
        log "state: invalid rollback directory"
        return 2
    fi
    if [[ ! -d "$INSTALLS_DIR" ]]; then
        log "state: not-installed"
        return 1
    fi
    for record in "$INSTALLS_DIR"/*; do
        [[ -e "$record" || -L "$record" ]] || continue
        found=1
        if ! read_record "$record"; then
            log "invalid record: $record"
            failed=1
            continue
        fi
        state=$(record_state)
        if [[ "$state" == ready && ( "$RECORD_RELEASE" != "$RELEASE" \
            || "$RECORD_DLL_SHA" != "$DLL_SHA256" ) ]]; then
            state="upgrade-required"
        fi
        log "$RECORD_TARGET: $state ($RECORD_RELEASE)"
        [[ "$state" == ready ]] || failed=1
    done
    if [[ $found -eq 0 ]]; then log "state: not-installed"; return 1; fi
    if [[ $failed -eq 0 ]]; then log "state: installed"; else log "state: incomplete"; fi
    return "$((failed * 2))"
}

count_installs() {
    local record count=0
    if [[ -L "$STATE_DIR" || -L "$CACHE_DIR" || -L "$INSTALLS_DIR" ]]; then
        printf '1\n'
        return 2
    fi
    if [[ -d "$INSTALLS_DIR" ]]; then
        for record in "$INSTALLS_DIR"/*; do
            [[ -e "$record" || -L "$record" ]] && count=$((count + 1))
        done
    fi
    printf '%s\n' "$count"
}

records_json() {
    local record state current marker invalid_id count=0
    command -v flock >/dev/null 2>&1 || die "flock is required."
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked FSR4 lock file."
    mkdir -p "${LOCK_FILE%/*}"
    exec 9> "$LOCK_FILE"
    flock -s 9
    python3 - "$RELEASE" "$DLL_SHA256" 3< <(
        if [[ -L "$STATE_DIR" || -L "$CACHE_DIR" || -L "$INSTALLS_DIR" \
            || ( -e "$STATE_DIR" && ! -d "$STATE_DIR" ) \
            || ( -e "$CACHE_DIR" && ! -d "$CACHE_DIR" ) \
            || ( -e "$INSTALLS_DIR" && ! -d "$INSTALLS_DIR" ) ]]; then
            printf 'I\0unsafe-state\0'
        elif [[ -d "$INSTALLS_DIR" ]]; then
            for record in "$INSTALLS_DIR"/*; do
                [[ -e "$record" || -L "$record" ]] || continue
                count=$((count + 1))
                if [[ $count -gt 4096 ]]; then
                    printf 'I\0record-limit\0'
                    break
                fi
                if ! read_record "$record"; then
                    invalid_id=$(printf '%s' "${record##*/}" | sha256sum | awk '{print $1}')
                    printf 'I\0invalid-%s\0' "$invalid_id"
                    continue
                fi
                state=$(record_state)
                current=false
                if [[ "$RECORD_RELEASE" == "$RELEASE" \
                    && "$RECORD_DLL_SHA" == "$DLL_SHA256" ]]; then
                    current=true
                elif [[ "$state" == ready ]]; then
                    state=upgrade-required
                fi
                printf 'V\0%s\0%s\0%s\0%s\0%s\0' "${record##*/}" \
                    "$RECORD_TARGET" "$RECORD_RELEASE" "$state" "$current"
            done
        fi
    ) <<'PY'
import json
import os
import sys

release, dll_sha = sys.argv[1:]
fields = os.fdopen(3, "rb").read().split(b"\0")
records = []
invalid = 0
index = 0
while index < len(fields) and fields[index]:
    marker = fields[index].decode("ascii", "strict")
    index += 1
    if marker == "I":
        record_id = fields[index].decode("utf-8", "replace")
        index += 1
        records.append({
            "targetId": record_id,
            "targetPath": None,
            "release": None,
            "state": "invalid",
            "currentRelease": False,
        })
        invalid += 1
        continue
    if marker != "V" or index + 5 > len(fields):
        raise SystemExit("Malformed internal FSR4 record stream")
    record_id, target, recorded_release, state, current = fields[index:index + 5]
    index += 5
    records.append({
        "targetId": record_id.decode("ascii", "strict"),
        "targetPath": target.decode("utf-8", "surrogateescape"),
        "release": recorded_release.decode("ascii", "strict"),
        "state": state.decode("ascii", "strict"),
        "currentRelease": current == b"true",
    })

valid_ready = bool(records) and invalid == 0 and all(
    record["state"] == "ready" and record["currentRelease"] for record in records
)
print(json.dumps({
    "schemaVersion": 1,
    "currentRelease": release,
    "currentDllSha256": dll_sha,
    "state": "ready" if valid_ready else "not-installed" if not records else "invalid",
    "invalidRecordCount": invalid,
    "records": records,
}, ensure_ascii=True, separators=(",", ":")))
PY
}

usage() {
    cat <<EOF
Usage: $0 install TARGET_DLL
       $0 uninstall TARGET_DLL
       $0 uninstall --all
       $0 status
       $0 records-json

Installs checksum-pinned BC-250 FSR4 $RELEASE into one compatible game or
OptiScaler DLL path. The exact original is retained for verified rollback.
Close the game before install or uninstall. See the cached README and notices
under $RELEASE_DIR after installation.
EOF
}

case "${1:-help}" in
    install)
        (($# == 2)) || die "Usage: $0 install TARGET_DLL"
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock 9
        install_target "$2"
        ;;
    uninstall)
        (($# == 2)) || die "Usage: $0 uninstall TARGET_DLL|--all"
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock 9
        if [[ "$2" == --all ]]; then
            found=0
            for record in "$INSTALLS_DIR"/*; do
                [[ -e "$record" || -L "$record" ]] || continue
                found=1; uninstall_record "$record"
            done
            [[ $found -eq 1 ]] || log "No FSR4 DLL installations are recorded."
        else
            uninstall_target "$2"
        fi
        ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    records-json) (($# == 1)) || exit 2; records_json ;;
    probe) (($# == 1)) || exit 2; probe_installs ;;
    count) (($# == 1)) || exit 2; count_installs ;;
    help|-h|--help) (($# == 1)) || exit 2; usage ;;
    *) usage >&2; exit 2 ;;
esac
