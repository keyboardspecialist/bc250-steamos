#!/usr/bin/env bash
# Manage mutually exclusive compressed-swap profiles for SteamOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORAGE_SH="${STORAGE_SH:-$SCRIPT_DIR/bc250-storage.sh}"
PERSISTENCE_SH="${PERSISTENCE_SH:-$SCRIPT_DIR/bc250-update-persistence.sh}"
ROOT_DATA_DIR="${ROOT_DATA_DIR:-/var/lib/bc250-control}"
BACKING_STATE_DIR="${BC250_SWAP_BACKING_STATE_DIR:-/home/.steamos/offload/var/lib/bc250-control/swap}"
STATE_DIR="${BC250_SWAP_STATE_DIR:-$ROOT_DATA_DIR/swap}"
STATE_FILE="$STATE_DIR/install.conf"
SWAPFILE="${BC250_SWAPFILE:-$STATE_DIR/swapfile}"
HELPER="${BC250_SWAP_HELPER:-$STATE_DIR/bc250-zswap-setup}"
ZRAM_CONFIG="${BC250_ZRAM_CONFIG:-/etc/systemd/zram-generator.conf.d/90-bc250-swap.conf}"
SERVICE_NAME=bc250-zswap-setup.service
SERVICE="${BC250_ZSWAP_SERVICE:-/etc/systemd/system/$SERVICE_NAME}"
SWAP_UNIT_NAME='var-lib-bc250\x2dcontrol-swap-swapfile.swap'
SWAP_UNIT="${BC250_ZSWAP_UNIT:-/etc/systemd/system/$SWAP_UNIT_NAME}"
SWAP_WANTS="${BC250_ZSWAP_WANTS:-/etc/systemd/system/swap.target.wants/$SWAP_UNIT_NAME}"
PROC_SWAPS="${BC250_PROC_SWAPS:-/proc/swaps}"
MEMINFO="${BC250_MEMINFO:-/proc/meminfo}"
ZRAM_SYS="${BC250_ZRAM_SYS:-/sys/block/zram0}"
ZSWAP_PARAMS="${BC250_ZSWAP_PARAMS:-/sys/module/zswap/parameters}"
LOCK_FILE="${BC250_SWAP_LOCK_FILE:-/run/lock/bc250-swap.lock}"
DEFAULT_SWAP_GIB=16
MIN_SWAP_GIB=4
MAX_SWAP_GIB=64

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0

log() { echo "[bc250-swap] $*"; }
die() { echo "[bc250-swap] $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo."; }
require_file() { [[ -f "$1" && ! -L "$1" ]] || die "Required file is missing or unsafe: $1"; }

render_zram_config() {
    cat <<'EOF'
# BC-250 compressed swap profile. Managed by bc250-swap.sh.
[zram0]
zram-size = ram/2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
}

render_zswap_config() {
    cat <<'EOF'
# BC-250 compressed swap profile. Managed by bc250-swap.sh.
[zram0]
zram-size = 0
EOF
}

render_helper() {
    cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
ZSWAP_PARAMS=$(printf '%q' "$ZSWAP_PARAMS")
for parameter in enabled compressor max_pool_percent; do
    [[ -w "\$ZSWAP_PARAMS/\$parameter" && ! -L "\$ZSWAP_PARAMS/\$parameter" ]] || exit 1
done
printf '%s\n' lz4 > "\$ZSWAP_PARAMS/compressor"
printf '%s\n' 25 > "\$ZSWAP_PARAMS/max_pool_percent"
printf '%s\n' Y > "\$ZSWAP_PARAMS/enabled"
EOF
}

render_service() {
    cat <<EOF
[Unit]
Description=Configure zswap for BC-250 disk swap
DefaultDependencies=no
RequiresMountsFor=$STATE_DIR
After=var-lib-bc250\\x2dcontrol.mount
Before=$SWAP_UNIT_NAME
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=$HELPER
RemainAfterExit=yes
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$ZSWAP_PARAMS
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes
TimeoutStartSec=30
EOF
}

render_swap_unit() {
    cat <<EOF
[Unit]
Description=BC-250 zswap-backed disk swap
Requires=$SERVICE_NAME
After=$SERVICE_NAME
RequiresMountsFor=$STATE_DIR
Before=swap.target

[Swap]
What=$SWAPFILE
Priority=10
TimeoutSec=120

[Install]
WantedBy=swap.target
EOF
}

render_state() {
    printf 'schema=1\nmode=%s\nsize_gib=%s\npending=%s\n' "$1" "$2" "$3"
}

atomic_write() {
    local target="$1" mode="$2" directory temporary
    directory=$(dirname "$target")
    [[ ! -L "$target" ]] || die "Refusing to replace symlink: $target"
    [[ ! -e "$target" || -f "$target" ]] || die "Refusing to replace non-file: $target"
    install -d -o root -g root -m 0755 "$directory"
    temporary=$(mktemp "$directory/.bc250-swap.XXXXXX")
    cat > "$temporary" || { rm -f "$temporary"; return 1; }
    chmod "$mode" "$temporary"
    chown root:root "$temporary"
    mv -f "$temporary" "$target"
}

file_secure() {
    local path="$1" owner mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    read -r owner mode < <(stat -Lc '%u %a' "$path") || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 8#022)) -eq 0 ]]
}

file_matches() {
    local path="$1" renderer="$2"
    file_secure "$path" && cmp -s "$path" <("$renderer")
}

file_mode_is() {
    [[ -f "$1" && ! -L "$1" && "$(stat -Lc %a "$1")" == "$2" ]]
}

read_state() {
    MODE="" SIZE_GIB="" PENDING=""
    file_secure "$STATE_FILE" && file_mode_is "$STATE_FILE" 644 || return 1
    local schema="" key value
    while IFS='=' read -r key value; do
        case "$key" in
            schema) schema="$value" ;;
            mode) MODE="$value" ;;
            size_gib) SIZE_GIB="$value" ;;
            pending) PENDING="$value" ;;
            *) return 1 ;;
        esac
    done < "$STATE_FILE"
    [[ "$schema" == 1 && ( "$MODE" == zram || "$MODE" == zswap ) \
        && "$SIZE_GIB" =~ ^[0-9]+$ \
        && ( "$PENDING" == none || "$PENDING" == creating || "$PENDING" == reboot \
            || "$PENDING" == zswap-removal || "$PENDING" == uninstall ) ]]
}

config_owned() {
    file_mode_is "$ZRAM_CONFIG" 644 \
        && { file_matches "$ZRAM_CONFIG" render_zram_config \
            || file_matches "$ZRAM_CONFIG" render_zswap_config; }
}
service_owned() { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_service; }
swap_unit_owned() { file_mode_is "$SWAP_UNIT" 644 && file_matches "$SWAP_UNIT" render_swap_unit; }
helper_owned() { file_mode_is "$HELPER" 755 && file_matches "$HELPER" render_helper; }

enablement_owned() {
    [[ -L "$SWAP_WANTS" && "$(readlink "$SWAP_WANTS")" == "../$SWAP_UNIT_NAME" ]]
}

preflight_ownership() {
    if [[ -e "$ZRAM_CONFIG" || -L "$ZRAM_CONFIG" ]]; then
        config_owned || die "Refusing unrecognized zram configuration: $ZRAM_CONFIG"
    fi
    if [[ -e "$SERVICE" || -L "$SERVICE" ]]; then
        service_owned || die "Refusing unrecognized zswap service: $SERVICE"
    fi
    if [[ -e "$SWAP_UNIT" || -L "$SWAP_UNIT" ]]; then
        swap_unit_owned || die "Refusing unrecognized swap unit: $SWAP_UNIT"
    fi
    if [[ -e "$HELPER" || -L "$HELPER" ]]; then
        helper_owned || die "Refusing unrecognized zswap helper: $HELPER"
    fi
    if [[ -e "$SWAP_WANTS" || -L "$SWAP_WANTS" ]]; then
        enablement_owned || die "Refusing unrecognized swap enablement: $SWAP_WANTS"
    fi
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
        read_state || die "Refusing malformed swap profile state: $STATE_FILE"
    fi
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
        read_state && [[ "$MODE" == zswap || "$PENDING" == zswap-removal || "$PENDING" == uninstall ]] \
            || die "Refusing unrecorded swapfile: $SWAPFILE"
        file_secure "$SWAPFILE" || die "Refusing unsafe swapfile: $SWAPFILE"
    fi
}

configured_complete() {
    read_state || return 1
    case "$MODE" in
        zram)
            [[ "$PENDING" == none || ( "$PENDING" == reboot && zram_runtime_matches ) ]] \
                && file_matches "$ZRAM_CONFIG" render_zram_config \
                && [[ ! -e "$SERVICE" && ! -L "$SERVICE" \
                    && ! -e "$SWAP_UNIT" && ! -L "$SWAP_UNIT" \
                    && ! -e "$HELPER" && ! -L "$HELPER" \
                    && ! -e "$SWAPFILE" && ! -L "$SWAPFILE" \
                    && ! -e "$SWAP_WANTS" && ! -L "$SWAP_WANTS" ]]
            ;;
        zswap)
            [[ "$PENDING" == none || "$PENDING" == reboot ]] \
                && file_matches "$ZRAM_CONFIG" render_zswap_config \
                && service_owned && swap_unit_owned && helper_owned \
                && validate_swapfile_metadata "$((SIZE_GIB * 1024 * 1024 * 1024))" \
                && enablement_owned
            ;;
    esac
}

swap_active() {
    local target="$1" active target_id active_id
    [[ -r "$PROC_SWAPS" ]] || return 1
    target_id=$(stat -Lc '%d:%i' "$target" 2>/dev/null || true)
    while read -r active _; do
        [[ "$active" == Filename || -z "$active" ]] && continue
        [[ "$active" == "$target" ]] && return 0
        if [[ -n "$target_id" ]]; then
            active_id=$(stat -Lc '%d:%i' "$active" 2>/dev/null || true)
            [[ -n "$active_id" && "$active_id" == "$target_id" ]] && return 0
        fi
    done < "$PROC_SWAPS"
    return 1
}

zram_runtime_matches() {
    local mem_kib expected actual difference priority algorithms
    swap_active /dev/zram0 || return 1
    [[ -r "$MEMINFO" && -r "$ZRAM_SYS/disksize" && -r "$ZRAM_SYS/comp_algorithm" ]] \
        || return 1
    mem_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO")
    actual=$(< "$ZRAM_SYS/disksize")
    algorithms=$(< "$ZRAM_SYS/comp_algorithm")
    priority=$(awk '$1 == "/dev/zram0" { print $5 }' "$PROC_SWAPS")
    [[ "$mem_kib" =~ ^[0-9]+$ && "$actual" =~ ^[0-9]+$ ]] || return 1
    expected=$((mem_kib * 1024 / 2))
    difference=$((actual > expected ? actual - expected : expected - actual))
    [[ $difference -le $((expected / 100)) \
        && "$algorithms" == *"[zstd]"* && "$priority" == 100 ]]
}

install_storage() {
    require_file "$STORAGE_SH"
    bash "$STORAGE_SH" install
}

install_persistence() {
    require_file "$PERSISTENCE_SH"
    bash "$PERSISTENCE_SH" install swap
}

remove_persistence() {
    require_file "$PERSISTENCE_SH"
    bash "$PERSISTENCE_SH" remove swap
}

write_profile_state() {
    install -d -o root -g root -m 0755 "$STATE_DIR"
    chmod 0755 "$STATE_DIR"
    render_state "$1" "$2" "$3" | atomic_write "$STATE_FILE" 0644
}

validate_size() {
    [[ "$1" =~ ^[0-9]+$ && $1 -ge $MIN_SWAP_GIB && $1 -le $MAX_SWAP_GIB ]] \
        || die "Swapfile size must be an integer from $MIN_SWAP_GIB to $MAX_SWAP_GIB GiB."
}

validate_swapfile_metadata() {
    local expected_bytes="$1" owner mode actual_bytes
    file_secure "$SWAPFILE" || return 1
    read -r owner mode < <(stat -Lc '%u %a' "$SWAPFILE") || return 1
    [[ "$mode" == 600 ]] || return 1
    actual_bytes=$(stat -Lc %s "$SWAPFILE") || return 1
    [[ "$actual_bytes" -eq "$expected_bytes" ]]
}

validate_swapfile() {
    local expected_bytes="$1" swap_type
    validate_swapfile_metadata "$expected_bytes" || return 1
    swap_type=$(blkid -p -s TYPE -o value "$SWAPFILE" 2>/dev/null || true)
    [[ "$swap_type" == swap ]]
}

create_swapfile() {
    local size_gib="$1" filesystem available required temporary
    required=$((size_gib * 1024 * 1024 * 1024))
    install -d -o root -g root -m 0755 "$STATE_DIR"
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
        validate_swapfile "$required" \
            || die "Existing toolkit swapfile does not match the recorded secure profile."
        return 0
    fi
    available=$(df -PB1 "$STATE_DIR" | awk 'NR == 2 { print $4 }')
    [[ "$available" =~ ^[0-9]+$ && $available -ge $((required + 1024 * 1024 * 1024)) ]] \
        || die "At least $((size_gib + 1)) GiB of free persistent storage is required."
    filesystem=$(findmnt -no FSTYPE --target "$STATE_DIR")
    temporary="$STATE_DIR/.swapfile.new"
    [[ ! -e "$temporary" && ! -L "$temporary" ]] \
        || die "Refusing unexpected staged swapfile: $temporary"
    if [[ "$filesystem" == btrfs ]]; then
        command -v btrfs >/dev/null 2>&1 || die "btrfs-progs is required."
        if ! btrfs filesystem mkswapfile --size "${size_gib}G" "$temporary"; then
            rm -f "$temporary"
            return 1
        fi
    else
        command -v fallocate >/dev/null 2>&1 || die "fallocate is required."
        if ! fallocate -l "${size_gib}G" "$temporary"; then
            rm -f "$temporary"
            return 1
        fi
        chmod 0600 "$temporary"
        if ! mkswap "$temporary" >/dev/null; then
            rm -f "$temporary"
            return 1
        fi
    fi
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$SWAPFILE"
}

recover_staged_swapfile() {
    local temporary="$STATE_DIR/.swapfile.new"
    [[ -e "$temporary" || -L "$temporary" ]] || return 0
    [[ -f "$temporary" && ! -L "$temporary" ]] \
        || die "Refusing unsafe staged swapfile: $temporary"
    file_secure "$temporary" || die "Refusing insecure staged swapfile: $temporary"
    swap_active "$temporary" && die "A staged swapfile is unexpectedly active: $temporary"
    rm -f "$temporary"
}

install_enablement() {
    install -d -o root -g root -m 0755 "$(dirname "$SWAP_WANTS")"
    if [[ -L "$SWAP_WANTS" ]]; then
        enablement_owned || die "Refusing unrecognized swap enablement: $SWAP_WANTS"
        return 0
    fi
    [[ ! -e "$SWAP_WANTS" ]] || die "Refusing non-symlink swap enablement: $SWAP_WANTS"
    ln -s "../$SWAP_UNIT_NAME" "$SWAP_WANTS"
}

remove_zswap_files() {
    swap_active "$SWAPFILE" && die "The toolkit swapfile is active. Reboot, then retry cleanup."
    rm -f "$SWAP_WANTS" "$SWAP_UNIT" "$SERVICE" "$HELPER" "$SWAPFILE"
    systemctl daemon-reload
}

begin_locked_lifecycle() {
    require_root
    command -v flock >/dev/null 2>&1 || die "flock is required."
    install -d -o root -g root -m 0755 "$(dirname "$LOCK_FILE")"
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked lock file: $LOCK_FILE"
    exec 9> "$LOCK_FILE"
    flock 9
}

begin_install_lifecycle() {
    begin_locked_lifecycle
    install_storage
    preflight_ownership
    recover_staged_swapfile
}

swap_has_artifacts() {
    [[ -e "$ZRAM_CONFIG" || -L "$ZRAM_CONFIG" \
        || -e "$SERVICE" || -L "$SERVICE" \
        || -e "$SWAP_UNIT" || -L "$SWAP_UNIT" \
        || -e "$SWAP_WANTS" || -L "$SWAP_WANTS" \
        || -e "$STATE_DIR" || -L "$STATE_DIR" \
        || -e "$BACKING_STATE_DIR" || -L "$BACKING_STATE_DIR" ]]
}

begin_cleanup_lifecycle() {
    begin_locked_lifecycle
    swap_has_artifacts || return 1
    install_storage
    preflight_ownership
    recover_staged_swapfile
}

cmd_install_zram() {
    begin_install_lifecycle
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required."
    local previous_size=0
    if read_state; then previous_size="$SIZE_GIB"; fi
    render_zram_config | atomic_write "$ZRAM_CONFIG" 0644
    rm -f "$SWAP_WANTS"
    systemctl daemon-reload
    if swap_active "$SWAPFILE"; then
        write_profile_state zram "$previous_size" zswap-removal
        install_persistence
        log "Zram is configured for the next boot. Reboot, then rerun 'install zram' to remove the inactive disk swapfile."
        return 0
    fi
    remove_zswap_files
    install_persistence
    if zram_runtime_matches; then
        write_profile_state zram 0 none
        log "Installed the zram profile: half of RAM, zstd compression, priority 100."
    else
        write_profile_state zram 0 reboot
        log "Installed the zram profile. Reboot to apply its exact size, compressor, and priority."
    fi
}

cmd_install_zswap() {
    begin_install_lifecycle
    local size_gib="${1:-$DEFAULT_SWAP_GIB}"
    validate_size "$size_gib"
    for command in systemctl mkswap findmnt df awk stat blkid; do
        command -v "$command" >/dev/null 2>&1 || die "$command is required."
    done
    [[ -d "$ZSWAP_PARAMS" && ! -L "$ZSWAP_PARAMS" ]] \
        || die "This kernel does not expose zswap controls."
    if [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" ]]; then
        write_profile_state zswap "$size_gib" creating
    fi
    create_swapfile "$size_gib"
    render_helper | atomic_write "$HELPER" 0755
    render_service | atomic_write "$SERVICE" 0644
    render_swap_unit | atomic_write "$SWAP_UNIT" 0644
    render_zswap_config | atomic_write "$ZRAM_CONFIG" 0644
    install_enablement
    systemctl daemon-reload
    install_persistence
    if swap_active "$SWAPFILE" && ! swap_active /dev/zram0; then
        write_profile_state zswap "$size_gib" none
        log "Zswap disk swap is active."
    else
        log "Installed zswap with lz4, a 25% RAM pool, and a ${size_gib} GiB disk swapfile at priority 10."
        log "Reboot to switch from zram to the zswap-backed disk swap."
        write_profile_state zswap "$size_gib" reboot
    fi
}

cmd_status() {
    local configured="none" runtime="inactive" swappiness="unknown"
    local zswap_enabled="unknown" compressor="unknown" pool="unknown"
    if read_state; then
        configured="$MODE"
    elif [[ -e "$ZRAM_CONFIG" || -e "$SERVICE" || -e "$SWAP_UNIT" \
        || -e "$HELPER" || -e "$SWAPFILE" ]]; then
        configured="partial"
    fi
    if swap_active /dev/zram0; then runtime="zram"; fi
    if swap_active "$SWAPFILE"; then runtime="zswap-disk"; fi
    if swap_active /dev/zram0 && swap_active "$SWAPFILE"; then runtime="mixed"; fi
    [[ -r /proc/sys/vm/swappiness ]] && swappiness=$(< /proc/sys/vm/swappiness)
    [[ -r "$ZSWAP_PARAMS/enabled" ]] && zswap_enabled=$(< "$ZSWAP_PARAMS/enabled")
    [[ -r "$ZSWAP_PARAMS/compressor" ]] && compressor=$(< "$ZSWAP_PARAMS/compressor")
    [[ -r "$ZSWAP_PARAMS/max_pool_percent" ]] && pool=$(< "$ZSWAP_PARAMS/max_pool_percent")
    echo "BC-250 compressed swap"
    echo "  configured: $configured"
    echo "  runtime:    $runtime"
    echo "  swappiness: $swappiness"
    echo "  zswap:      $zswap_enabled (compressor $compressor, pool ${pool}%)"
    if [[ "$configured" == zswap || ( "$configured" == zram && "${PENDING:-}" == zswap-removal ) ]]; then
        echo "  swapfile:   $SWAPFILE (${SIZE_GIB} GiB configured)"
    fi
    local effective_pending="${PENDING:-}"
    if [[ "$configured" == zswap && "$runtime" == zswap-disk && "$effective_pending" == reboot ]]; then
        effective_pending=none
    fi
    if [[ "$configured" == zram && "$effective_pending" == reboot ]] && zram_runtime_matches; then
        effective_pending=none
    fi
    if [[ -n "$effective_pending" && "$effective_pending" != none ]]; then
        echo "  pending:    $effective_pending"
    fi
    [[ "$configured" != partial && "$runtime" != mixed ]] || return 2
    [[ "$configured" != none ]] || return 1
    configured_complete || return 2
}

cmd_installed() {
    if configured_complete; then
        echo installed
        return 0
    fi
    echo not-installed
    return 1
}

cmd_verify() {
    require_root
    local rc=0
    cmd_status || rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    if read_state && [[ "$MODE" == zswap ]]; then
        if ! validate_swapfile "$((SIZE_GIB * 1024 * 1024 * 1024))"; then
            log "The toolkit swapfile size or swap signature is invalid." >&2
            return 2
        fi
        echo "  verification: swap signature valid"
    else
        echo "  verification: zram configuration valid"
    fi
}

cmd_uninstall() {
    if ! begin_cleanup_lifecycle; then
        log "No toolkit swap profile is installed."
        return 0
    fi
    local current_mode=""
    if read_state; then current_mode="$MODE"; fi
    if swap_active "$SWAPFILE"; then
        rm -f "$SWAP_WANTS" "$ZRAM_CONFIG"
        write_profile_state zswap "${SIZE_GIB:-$DEFAULT_SWAP_GIB}" uninstall
        systemctl daemon-reload
        log "The disk swap remains active for this boot. Reboot, then rerun uninstall to remove it safely."
        return 75
    fi
    remove_zswap_files
    rm -f "$ZRAM_CONFIG" "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    systemctl daemon-reload
    remove_persistence
    log "Removed the toolkit swap profile; Valve's zram defaults apply after reboot."
}

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}
trap tui_show_cursor EXIT

menu_select() {
    local title="$1"
    shift
    local items=("$@") n=$# cur=0 key rest i label badge hint label_width=0
    for i in "${!items[@]}"; do
        IFS='|' read -r label badge hint <<< "${items[$i]}"
        if ((${#label} > label_width)); then label_width=${#label}; fi
    done
    printf '\033[?25l'
    TUI_CURSOR_HIDDEN=1
    while true; do
        printf '\033[H\033[2J'
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CB}${CC}  CONTROLS  [Up/Down or J/K] Move  [Enter] Select  [Q/Esc] Back${C0}"
        printf '\033[K\n'
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K  %s > %-*s %s %s\n' "${CI}${CB}" "$label_width" "$label" "${C0}" "$badge"
            else
                printf '\033[K     %-*s  %s\n' "$label_width" "$label" "$badge"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
        IFS= read -rsn1 key || { tui_show_cursor; return 1; }
        if [[ $key == $'\033' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.05 rest || true
            key+="$rest"
        fi
        case "$key" in
            $'\033[A'|k) if ((cur > 0)); then cur=$((cur - 1)); else cur=$((n - 1)); fi ;;
            $'\033[B'|j) if ((cur < n - 1)); then cur=$((cur + 1)); else cur=0; fi ;;
            "") MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

confirm_action() {
    local prompt="$1" answer
    shift
    printf '%s' "${CB}${prompt} [y/N] ${C0}"
    IFS= read -r answer
    case "$answer" in y|Y|yes|YES) "$@" ;; *) log "Cancelled." ;; esac
}

cmd_menu() {
    require_root
    while true; do
        local badge="${CD}[not configured]${C0}"
        if configured_complete && read_state; then badge="${CG}[${MODE}]${C0}"; fi
        local items=(
            "Status overview|$badge|Show the configured profile, active swap, zswap state, and swappiness."
            "Use zram|$badge|Compressed RAM swap using Valve's half-RAM zstd profile at priority 100."
            "Use zswap + disk|$badge|Use lz4 zswap with a 25% RAM pool plus a 16 GiB disk swapfile at priority 10."
            "Remove toolkit profile|$badge|Remove toolkit-owned swap settings and return to Valve's zram defaults."
            "Full help||Show profile details, CLI commands, paths, and reboot behavior."
        )
        menu_select "BC-250 compressed swap" "${items[@]}" || { echo; break; }
        echo
        case $MENU_CHOICE in
            0) cmd_status || true ;;
            1) confirm_action "Configure the zram profile?" cmd_install_zram ;;
            2) confirm_action "Configure zswap with a 16 GiB disk swapfile?" cmd_install_zswap "$DEFAULT_SWAP_GIB" ;;
            3) confirm_action "Remove the toolkit swap profile?" cmd_uninstall ;;
            4) cmd_help ;;
        esac
        echo
        printf '%s' "${CD}-- press any key to continue --${C0}"
        IFS= read -rsn1 || true
    done
}

cmd_help() {
    cat <<EOF
Usage: $0 [menu|install MODE [SIZE_GIB]|status|verify|installed|uninstall|help]

  install zram              Use compressed RAM swap: ram/2, zstd, priority 100.
  install zswap [SIZE_GIB]  Use lz4 zswap with a 25% RAM pool and a toolkit-owned
                            disk swapfile at priority 10 (default: 16 GiB).
  status                    Show configured, active, and pending swap state.
  verify                    Privileged status plus disk swap-signature validation.
  installed                 Machine-readable installation probe.
  uninstall                 Remove toolkit settings and restore Valve defaults.

The profiles are mutually exclusive and transitions are reboot-gated. The
script never performs a live swapoff or removes an active swapfile. Zswap is a
global kernel cache and therefore also compresses pages sent to other active
disk swap devices; unrelated swap devices are otherwise left unchanged.
EOF
}

case "${1:-menu}" in
    menu) (($# == 0 || $# == 1)) || die "Usage: $0 menu"; cmd_menu ;;
    install)
        case "${2:-}" in
            zram) (($# == 2)) || die "Usage: $0 install zram"; cmd_install_zram ;;
            zswap) (($# == 2 || $# == 3)) || die "Usage: $0 install zswap [SIZE_GIB]"; cmd_install_zswap "${3:-$DEFAULT_SWAP_GIB}" ;;
            *) die "Usage: $0 install {zram|zswap [SIZE_GIB]}" ;;
        esac
        ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    verify) (($# == 1)) || die "Usage: $0 verify"; cmd_verify ;;
    installed) (($# == 1)) || die "Usage: $0 installed"; cmd_installed ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) die "Usage: $0 {menu|install|status|verify|installed|uninstall|help}" ;;
esac
