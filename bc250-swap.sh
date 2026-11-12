#!/usr/bin/env bash
# Manage mutually exclusive compressed-swap profiles for SteamOS.
set -euo pipefail

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    _bc250_hook="$(dirname -- "${BASH_SOURCE[0]}")/scripts/feature-tracking.sh"
    if [[ -f "$_bc250_hook" && ! -L "$_bc250_hook" ]]; then source "$_bc250_hook" swap menu "$@"; fi
    unset _bc250_hook
fi

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
ZSWAP_TMPFILES="${BC250_ZSWAP_TMPFILES:-/etc/tmpfiles.d/00-bc250-zswap.conf}"
SWAPPINESS_CONFIG="${BC250_SWAPPINESS_CONFIG:-/etc/sysctl.d/99-bc250-swap.conf}"
SWAPPINESS_SYS="${BC250_SWAPPINESS_SYS:-/proc/sys/vm/swappiness}"
SERVICE_NAME=bc250-zswap-setup.service
SERVICE="${BC250_ZSWAP_SERVICE:-/etc/systemd/system/$SERVICE_NAME}"
SWAP_UNIT_NAME='var-lib-bc250\x2dcontrol-swap-swapfile.swap'
SWAP_UNIT="${BC250_ZSWAP_UNIT:-/etc/systemd/system/$SWAP_UNIT_NAME}"
SWAP_WANTS="${BC250_ZSWAP_WANTS:-/etc/systemd/system/swap.target.wants/$SWAP_UNIT_NAME}"
PROC_SWAPS="${BC250_PROC_SWAPS:-/proc/swaps}"
MEMINFO="${BC250_MEMINFO:-/proc/meminfo}"
ZRAM_SYS="${BC250_ZRAM_SYS:-/sys/block/zram0}"
ZSWAP_PARAMS="${BC250_ZSWAP_PARAMS:-/sys/module/zswap/parameters}"
ZSWAP_DEBUG="${BC250_ZSWAP_DEBUG:-/sys/kernel/debug/zswap}"
VMSTAT="${BC250_VMSTAT:-/proc/vmstat}"
MEMORY_PRESSURE="${BC250_MEMORY_PRESSURE:-/proc/pressure/memory}"
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
    local compressor="${1:-zstd}"
    cat <<EOF
# BC-250 compressed swap profile. Managed by bc250-swap.sh.
[zram0]
zram-size = ram/2
compression-algorithm = $compressor
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

render_zswap_tmpfiles() {
    local compressor="${1:-lz4}"
    cat <<EOF
# BC-250 zswap profile. Managed by bc250-swap.sh.
w! /sys/module/zswap/parameters/compressor - - - - $compressor
w! /sys/module/zswap/parameters/max_pool_percent - - - - 10
w! /sys/module/zswap/parameters/shrinker_enabled - - - - Y
w! /sys/module/zswap/parameters/enabled - - - - Y
EOF
}

render_zram_tmpfiles() {
    cat <<'EOF'
# BC-250 zram profile. Managed by bc250-swap.sh.
w-! /sys/module/zswap/parameters/enabled - - - - N
EOF
}

render_swappiness() {
    printf '# BC-250 swappiness. Managed by bc250-swap.sh.\nvm.swappiness = %s\n' "$1"
}

configured_swappiness() {
    local value
    file_secure "$SWAPPINESS_CONFIG" && file_mode_is "$SWAPPINESS_CONFIG" 644 || return 1
    value=$(sed -n 's/^vm.swappiness = //p' "$SWAPPINESS_CONFIG")
    [[ "$value" =~ ^(0|[1-9][0-9]{0,2})$ && "$value" -le 200 ]] || return 1
    file_matches "$SWAPPINESS_CONFIG" render_swappiness "$value" || return 1
    printf '%s\n' "$value"
}

cmd_swappiness() {
    local value="${1:-}"
    [[ "$value" =~ ^(0|[1-9][0-9]{0,2})$ && "$value" -le 200 ]] \
        || die "Swappiness must be an integer from 0 to 200."
    begin_locked_lifecycle
    preflight_ownership
    read_state && [[ "$PENDING" != uninstall ]] || die "Install a zram or zswap profile first."
    [[ -w "$SWAPPINESS_SYS" && ! -L "$SWAPPINESS_SYS" ]] || die "Swappiness control is not writable."
    render_swappiness "$value" | atomic_write "$SWAPPINESS_CONFIG" 0644
    printf '%s\n' "$value" > "$SWAPPINESS_SYS"
    install_persistence
    log "Set vm.swappiness=$value for the $MODE profile (active now and persistent across reboots)."
}

render_legacy_zswap_tmpfiles() {
    cat <<'EOF'
# BC-250 zswap profile. Managed by bc250-swap.sh.
w /sys/module/zswap/parameters/compressor - - - - lz4
w /sys/module/zswap/parameters/max_pool_percent - - - - 25
w /sys/module/zswap/parameters/enabled - - - - Y
EOF
}

render_legacy_helper() {
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
    # Swap must start before tmp.mount/local-fs.target. Waiting for the global
    # tmpfiles service (or private /tmp mounts) here creates a boot-order cycle.
    cat <<EOF
[Unit]
Description=Configure zswap for BC-250 disk swap
DefaultDependencies=no
Before=systemd-tmpfiles-setup.service
Before=$SWAP_UNIT_NAME
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/compressor
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/max_pool_percent
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/shrinker_enabled
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/enabled
ExecStart=/usr/bin/systemd-tmpfiles --create --boot $ZSWAP_TMPFILES
RemainAfterExit=yes
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$ZSWAP_PARAMS
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes
TimeoutStartSec=30
EOF
}

render_zram_service() {
    # Disable the global zswap cache before either swap device is used. The
    # optional path also supports kernels built without CONFIG_ZSWAP.
    render_service | sed \
        -e 's/Configure zswap for BC-250 disk swap/Disable zswap for BC-250 zram and disk fallback/' \
        -e '/^Before=systemd-tmpfiles-setup.service/a Before=systemd-zram-setup@zram0.service' \
        -e '/^ExecStartPre=/d' \
        -e "s|^ReadWritePaths=.*|ReadWritePaths=-$ZSWAP_PARAMS|"
}

render_cyclic_service() {
    cat <<EOF
[Unit]
Description=Configure zswap for BC-250 disk swap
DefaultDependencies=no
Requires=systemd-tmpfiles-setup.service
After=systemd-tmpfiles-setup.service
Before=$SWAP_UNIT_NAME
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/compressor
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/max_pool_percent
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/shrinker_enabled
ExecStartPre=/usr/bin/test -w $ZSWAP_PARAMS/enabled
ExecStart=/usr/bin/systemd-tmpfiles --create --boot $ZSWAP_TMPFILES
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

render_previous_service() {
    cat <<EOF
[Unit]
Description=Configure zswap for BC-250 disk swap
DefaultDependencies=no
Requires=systemd-tmpfiles-setup.service
After=systemd-tmpfiles-setup.service
Before=$SWAP_UNIT_NAME
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-tmpfiles --create $ZSWAP_TMPFILES
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

render_legacy_service() {
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

render_legacy_swap_unit() {
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

render_zram_swap_unit() {
    render_swap_unit | sed 's/BC-250 zswap-backed disk swap/BC-250 zram disk fallback/'
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
    shift 2
    file_secure "$path" && cmp -s "$path" <("$renderer" "$@")
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

zram_config_owned() {
    file_mode_is "$ZRAM_CONFIG" 644 \
        && { file_matches "$ZRAM_CONFIG" render_zram_config zstd \
            || file_matches "$ZRAM_CONFIG" render_zram_config lz4; }
}
configured_zram_compressor() {
    if file_matches "$ZRAM_CONFIG" render_zram_config lz4; then
        printf '%s\n' lz4
    else
        printf '%s\n' zstd
    fi
}
config_owned() {
    zram_config_owned \
        || { file_mode_is "$ZRAM_CONFIG" 644 && file_matches "$ZRAM_CONFIG" render_zswap_config; }
}
tmpfiles_owned() {
    file_mode_is "$ZSWAP_TMPFILES" 644 \
        && { file_matches "$ZSWAP_TMPFILES" render_zswap_tmpfiles lz4 \
            || file_matches "$ZSWAP_TMPFILES" render_zswap_tmpfiles zstd; }
}
# The managed boot configuration records the selection, including existing
# zstd installs whose schema-1 state file has no compressor field.
configured_zswap_compressor() {
    if file_matches "$ZSWAP_TMPFILES" render_zswap_tmpfiles zstd; then
        printf '%s\n' zstd
    else
        printf '%s\n' lz4
    fi
}
legacy_tmpfiles_owned() { file_mode_is "$ZSWAP_TMPFILES" 644 && file_matches "$ZSWAP_TMPFILES" render_legacy_zswap_tmpfiles; }
tmpfiles_recognized() { tmpfiles_owned || legacy_tmpfiles_owned || { file_mode_is "$ZSWAP_TMPFILES" 644 && file_matches "$ZSWAP_TMPFILES" render_zram_tmpfiles; }; }
service_owned() { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_service; }
cyclic_service_owned() { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_cyclic_service; }
previous_service_owned() { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_previous_service; }
legacy_service_owned() { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_legacy_service; }
service_recognized() { service_owned || cyclic_service_owned || previous_service_owned || legacy_service_owned || { file_mode_is "$SERVICE" 644 && file_matches "$SERVICE" render_zram_service; }; }
swap_unit_owned() { file_mode_is "$SWAP_UNIT" 644 && file_matches "$SWAP_UNIT" render_swap_unit; }
swap_unit_recognized() { swap_unit_owned || { file_mode_is "$SWAP_UNIT" 644 && { file_matches "$SWAP_UNIT" render_legacy_swap_unit || file_matches "$SWAP_UNIT" render_zram_swap_unit; }; }; }
legacy_helper_owned() { file_mode_is "$HELPER" 755 && file_matches "$HELPER" render_legacy_helper; }

enablement_owned() {
    [[ -L "$SWAP_WANTS" && "$(readlink "$SWAP_WANTS")" == "../$SWAP_UNIT_NAME" ]]
}

preflight_configuration_ownership() {
    if [[ -e "$ZRAM_CONFIG" || -L "$ZRAM_CONFIG" ]]; then
        config_owned || die "Refusing unrecognized zram configuration: $ZRAM_CONFIG"
    fi
    if [[ -e "$ZSWAP_TMPFILES" || -L "$ZSWAP_TMPFILES" ]]; then
        tmpfiles_recognized || die "Refusing unrecognized zswap tmpfiles configuration: $ZSWAP_TMPFILES"
    fi
    if [[ -e "$SERVICE" || -L "$SERVICE" ]]; then
        service_recognized || die "Refusing unrecognized zswap service: $SERVICE"
    fi
    if [[ -e "$SWAP_UNIT" || -L "$SWAP_UNIT" ]]; then
        swap_unit_recognized || die "Refusing unrecognized swap unit: $SWAP_UNIT"
    fi
    if [[ -e "$HELPER" || -L "$HELPER" ]]; then
        legacy_helper_owned || die "Refusing unrecognized zswap helper: $HELPER"
    fi
    if [[ -e "$SWAP_WANTS" || -L "$SWAP_WANTS" ]]; then
        enablement_owned || die "Refusing unrecognized swap enablement: $SWAP_WANTS"
    fi
}

preflight_state_ownership() {
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
        read_state || die "Refusing malformed swap profile state: $STATE_FILE"
    fi
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
        read_state && [[ "$SIZE_GIB" -gt 0 || "$PENDING" == zswap-removal || "$PENDING" == uninstall ]] \
            || die "Refusing unrecorded swapfile: $SWAPFILE"
        file_secure "$SWAPFILE" || die "Refusing unsafe swapfile: $SWAPFILE"
    fi
}

preflight_ownership() {
    if [[ -e "$SWAPPINESS_CONFIG" || -L "$SWAPPINESS_CONFIG" ]]; then
        configured_swappiness >/dev/null || die "Refusing unrecognized swappiness configuration: $SWAPPINESS_CONFIG"
    fi
    preflight_configuration_ownership
    preflight_state_ownership
}

configured_complete() {
    if [[ -e "$SWAPPINESS_CONFIG" || -L "$SWAPPINESS_CONFIG" ]]; then configured_swappiness >/dev/null || return 1; fi
    read_state || return 1
    case "$MODE" in
        zram)
            if [[ "$SIZE_GIB" -gt 0 && "$PENDING" != zswap-removal ]]; then
                [[ "$PENDING" == none || "$PENDING" == reboot ]] \
                    && zram_config_owned && zram_disk_configured_complete
                return
            fi
            [[ "$PENDING" == none || "$PENDING" == reboot ]] \
                && zram_config_owned \
                && [[ ! -e "$ZSWAP_TMPFILES" && ! -L "$ZSWAP_TMPFILES" \
                    && ! -e "$SERVICE" && ! -L "$SERVICE" \
                    && ! -e "$SWAP_UNIT" && ! -L "$SWAP_UNIT" \
                    && ! -e "$HELPER" && ! -L "$HELPER" \
                    && ! -e "$SWAPFILE" && ! -L "$SWAPFILE" \
                    && ! -e "$SWAP_WANTS" && ! -L "$SWAP_WANTS" ]]
            ;;
        zswap)
            [[ "$PENDING" == none || "$PENDING" == reboot ]] \
                && file_matches "$ZRAM_CONFIG" render_zswap_config \
                && tmpfiles_owned && service_owned && swap_unit_owned \
                && [[ ! -e "$HELPER" && ! -L "$HELPER" ]] \
                && validate_swapfile_metadata "$((SIZE_GIB * 1024 * 1024 * 1024))" \
                && enablement_owned
            ;;
    esac
}

zram_disk_configured_complete() {
    file_matches "$ZSWAP_TMPFILES" render_zram_tmpfiles \
        && file_matches "$SERVICE" render_zram_service \
        && file_matches "$SWAP_UNIT" render_zram_swap_unit \
        && file_mode_is "$ZSWAP_TMPFILES" 644 && file_mode_is "$SERVICE" 644 \
        && file_mode_is "$SWAP_UNIT" 644 && enablement_owned \
        && [[ ! -e "$HELPER" && ! -L "$HELPER" ]] \
        && validate_swapfile_metadata "$((SIZE_GIB * 1024 * 1024 * 1024))"
}

zram_profile_runtime_matches() {
    zram_runtime_matches || return 1
    if [[ "${SIZE_GIB:-0}" -gt 0 && "${PENDING:-}" != zswap-removal ]]; then
        swap_active "$SWAPFILE" && [[ "$(swap_priority "$SWAPFILE")" == 10 ]] || return 1
        if [[ -r "$ZSWAP_PARAMS/enabled" ]]; then
            [[ "$(< "$ZSWAP_PARAMS/enabled")" == N ]] || return 1
        fi
    fi
}

legacy_zswap_configured_complete() {
    read_state && [[ "$MODE" == zswap && ( "$PENDING" == none || "$PENDING" == reboot ) ]] \
        && file_matches "$ZRAM_CONFIG" render_zswap_config \
        && validate_swapfile_metadata "$((SIZE_GIB * 1024 * 1024 * 1024))" \
        && enablement_owned \
        && { { legacy_tmpfiles_owned && previous_service_owned && swap_unit_owned \
                && [[ ! -e "$HELPER" && ! -L "$HELPER" ]]; } \
            || { tmpfiles_owned && cyclic_service_owned && swap_unit_owned \
                && [[ ! -e "$HELPER" && ! -L "$HELPER" ]]; } \
            || { [[ ! -e "$ZSWAP_TMPFILES" && ! -L "$ZSWAP_TMPFILES" ]] \
                && legacy_service_owned && swap_unit_recognized && legacy_helper_owned; }; }
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

swap_priority() {
    local target="$1" active priority target_id active_id
    [[ -r "$PROC_SWAPS" ]] || return 1
    target_id=$(stat -Lc '%d:%i' "$target" 2>/dev/null || true)
    while read -r active _ _ _ priority; do
        [[ "$active" == Filename || -z "$active" ]] && continue
        if [[ "$active" == "$target" ]]; then
            printf '%s\n' "$priority"
            return 0
        fi
        if [[ -n "$target_id" ]]; then
            active_id=$(stat -Lc '%d:%i' "$active" 2>/dev/null || true)
            if [[ -n "$active_id" && "$active_id" == "$target_id" ]]; then
                printf '%s\n' "$priority"
                return 0
            fi
        fi
    done < "$PROC_SWAPS"
    return 1
}

zram_runtime_matches() {
    local mem_kib expected actual difference priority algorithms
    local expected_compressor="${1:-$(configured_zram_compressor)}"
    swap_active /dev/zram0 || return 1
    [[ -r "$MEMINFO" && -r "$ZRAM_SYS/disksize" && -r "$ZRAM_SYS/comp_algorithm" ]] \
        || return 1
    mem_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO")
    actual=$(< "$ZRAM_SYS/disksize")
    algorithms=$(< "$ZRAM_SYS/comp_algorithm")
    priority=$(swap_priority /dev/zram0 || true)
    [[ "$mem_kib" =~ ^[0-9]+$ && "$actual" =~ ^[0-9]+$ ]] || return 1
    expected=$((mem_kib * 1024 / 2))
    difference=$((actual > expected ? actual - expected : expected - actual))
    [[ $difference -le $((expected / 100)) \
        && "$algorithms" == *"[$expected_compressor]"* && "$priority" == 100 ]]
}

zswap_runtime_matches() {
    local enabled compressor pool shrinker priority
    local expected_compressor="${1:-$(configured_zswap_compressor)}"
    swap_active "$SWAPFILE" && ! swap_active /dev/zram0 || return 1
    [[ -r "$ZSWAP_PARAMS/enabled" && -r "$ZSWAP_PARAMS/compressor" \
        && -r "$ZSWAP_PARAMS/max_pool_percent" && -r "$ZSWAP_PARAMS/shrinker_enabled" ]] \
        || return 1
    enabled=$(< "$ZSWAP_PARAMS/enabled")
    compressor=$(< "$ZSWAP_PARAMS/compressor")
    pool=$(< "$ZSWAP_PARAMS/max_pool_percent")
    shrinker=$(< "$ZSWAP_PARAMS/shrinker_enabled")
    priority=$(swap_priority "$SWAPFILE" || true)
    [[ "$enabled" == Y && "$compressor" == "$expected_compressor" && "$pool" == 10 \
        && "$shrinker" == Y && "$priority" == 10 ]]
}

install_storage() {
    require_file "$STORAGE_SH"
    BC250_STORAGE_SKIP_LEGACY_AIC=1 bash "$STORAGE_SH" install
}

install_persistence() {
    require_file "$PERSISTENCE_SH"
    BC250_STORAGE_SKIP_LEGACY_AIC=1 bash "$PERSISTENCE_SH" install swap
}

remove_persistence() {
    require_file "$PERSISTENCE_SH"
    BC250_STORAGE_SKIP_LEGACY_AIC=1 bash "$PERSISTENCE_SH" remove swap
}

write_profile_state() {
    install -d -o root -g root -m 0755 "$STATE_DIR"
    chmod 0755 "$STATE_DIR"
    render_state "$1" "$2" "$3" | atomic_write "$STATE_FILE" 0644
}

validate_size() {
    [[ "$1" =~ ^[1-9][0-9]?$ && $1 -ge $MIN_SWAP_GIB && $1 -le $MAX_SWAP_GIB ]] \
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
    rm -f "$SWAP_WANTS" "$SWAP_UNIT" "$ZSWAP_TMPFILES" "$SERVICE" "$HELPER" "$SWAPFILE"
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
    preflight_ownership
    install_storage
    preflight_state_ownership
    recover_staged_swapfile
}

swap_has_artifacts() {
    [[ -e "$ZRAM_CONFIG" || -L "$ZRAM_CONFIG" \
        || -e "$SWAPPINESS_CONFIG" || -L "$SWAPPINESS_CONFIG" \
        || -e "$ZSWAP_TMPFILES" || -L "$ZSWAP_TMPFILES" \
        || -e "$SERVICE" || -L "$SERVICE" \
        || -e "$SWAP_UNIT" || -L "$SWAP_UNIT" \
        || -e "$SWAP_WANTS" || -L "$SWAP_WANTS" \
        || -e "$STATE_DIR" || -L "$STATE_DIR" \
        || -e "$BACKING_STATE_DIR" || -L "$BACKING_STATE_DIR" ]]
}

begin_cleanup_lifecycle() {
    begin_locked_lifecycle
    swap_has_artifacts || return 1
    preflight_ownership
    install_storage
    preflight_state_ownership
    recover_staged_swapfile
}

cmd_install_zram() {
    local compressor="${1:-zstd}"
    local size_gib="${2:-$DEFAULT_SWAP_GIB}"
    [[ "$size_gib" == 0 ]] || validate_size "$size_gib"
    case "$compressor" in lz4|zstd) ;; *) die "Zram compressor must be lz4 or zstd." ;; esac
    require_root
    begin_install_lifecycle
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required."
    local previous_size=0
    if read_state; then previous_size="$SIZE_GIB"; fi
    if [[ "$size_gib" -gt 0 ]]; then
        for command in systemctl mkswap findmnt df awk stat blkid; do
            command -v "$command" >/dev/null 2>&1 || die "$command is required."
        done
        if [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" ]]; then
            write_profile_state zram "$size_gib" creating
        fi
        create_swapfile "$size_gib"
        render_zram_config "$compressor" | atomic_write "$ZRAM_CONFIG" 0644
        render_zram_tmpfiles | atomic_write "$ZSWAP_TMPFILES" 0644
        render_zram_service | atomic_write "$SERVICE" 0644
        render_zram_swap_unit | atomic_write "$SWAP_UNIT" 0644
        rm -f "$HELPER"
        install_enablement
        systemctl daemon-reload
        write_profile_state zram "$size_gib" reboot
        if zram_profile_runtime_matches; then write_profile_state zram "$size_gib" none; fi
        install_persistence
        log "Installed half-RAM $compressor zram at priority 100 with a ${size_gib} GiB disk fallback at priority 10."
        log "Reboot to apply the complete profile; zswap is disabled to avoid double compression."
        return 0
    fi
    render_zram_config "$compressor" | atomic_write "$ZRAM_CONFIG" 0644
    rm -f "$SWAP_WANTS" "$ZSWAP_TMPFILES" "$SERVICE" "$HELPER"
    systemctl daemon-reload
    if swap_active "$SWAPFILE"; then
        write_profile_state zram "$previous_size" zswap-removal
        install_persistence
        log "Zram is configured for the next boot. Reboot, then rerun 'install zram $compressor 0' to remove the inactive disk swapfile."
        return 0
    fi
    remove_zswap_files
    install_persistence
    if zram_runtime_matches; then
        write_profile_state zram 0 none
        log "Installed the zram profile: half of RAM, $compressor compression, priority 100."
    else
        write_profile_state zram 0 reboot
        log "Installed the zram profile. Reboot to apply its exact size, compressor, and priority."
    fi
}

cmd_install_zswap() {
    local size_gib="${1:-$DEFAULT_SWAP_GIB}"
    local compressor="${2:-lz4}"
    validate_size "$size_gib"
    case "$compressor" in lz4|zstd) ;; *) die "Zswap compressor must be lz4 or zstd." ;; esac
    begin_install_lifecycle
    for command in systemctl mkswap findmnt df awk stat blkid; do
        command -v "$command" >/dev/null 2>&1 || die "$command is required."
    done
    [[ -d "$ZSWAP_PARAMS" && ! -L "$ZSWAP_PARAMS" ]] \
        || die "This kernel does not expose zswap controls."
    local parameter
    for parameter in enabled compressor max_pool_percent shrinker_enabled; do
        [[ -w "$ZSWAP_PARAMS/$parameter" && ! -L "$ZSWAP_PARAMS/$parameter" ]] \
            || die "This kernel does not expose a writable zswap $parameter control."
    done
    if [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" ]]; then
        write_profile_state zswap "$size_gib" creating
    fi
    create_swapfile "$size_gib"
    render_zswap_tmpfiles "$compressor" | atomic_write "$ZSWAP_TMPFILES" 0644
    render_service | atomic_write "$SERVICE" 0644
    render_swap_unit | atomic_write "$SWAP_UNIT" 0644
    render_zswap_config | atomic_write "$ZRAM_CONFIG" 0644
    rm -f "$HELPER"
    install_enablement
    systemctl daemon-reload
    install_persistence
    if zswap_runtime_matches; then
        write_profile_state zswap "$size_gib" none
        log "Zswap disk swap is active."
    else
        log "Installed zswap with $compressor, a 10% RAM pool, the memory shrinker, and a ${size_gib} GiB disk swapfile at priority 10."
        log "Reboot to apply and verify the complete zswap profile."
        write_profile_state zswap "$size_gib" reboot
    fi
}

cmd_status() {
    local configured="none" runtime="inactive" swappiness="unknown"
    local zswap_enabled="unknown" compressor="unknown" pool="unknown"
    local active type size used priority size_mib used_mib
    local total_swap_kib=0
    local swap_in="unknown" swap_out="unknown" psi_some="unknown" psi_full="unknown"
    local original compressed resident _
    local pool_bytes stored_pages written_back_pages runtime_mismatch=0 legacy_profile=0
    if read_state; then
        if legacy_zswap_configured_complete; then
            configured="legacy-zswap"
            legacy_profile=1
        else
            configured="$MODE"
        fi
    elif [[ -e "$ZRAM_CONFIG" || -e "$ZSWAP_TMPFILES" || -e "$SERVICE" || -e "$SWAP_UNIT" \
        || -e "$HELPER" || -e "$SWAPFILE" || -e "$STATE_FILE" || -L "$STATE_FILE" \
        || -e "$SWAPPINESS_CONFIG" || -L "$SWAPPINESS_CONFIG" ]]; then
        configured="partial"
    fi
    if swap_active /dev/zram0; then runtime="zram"; fi
    if swap_active "$SWAPFILE"; then runtime="zswap-disk"; fi
    if swap_active /dev/zram0 && swap_active "$SWAPFILE"; then
        runtime="mixed"
        if [[ "$configured" == zram ]] && zram_disk_configured_complete; then runtime="zram+disk"; fi
    fi
    [[ -r "$SWAPPINESS_SYS" ]] && swappiness=$(< "$SWAPPINESS_SYS")
    [[ -r "$ZSWAP_PARAMS/enabled" ]] && zswap_enabled=$(< "$ZSWAP_PARAMS/enabled")
    [[ -r "$ZSWAP_PARAMS/compressor" ]] && compressor=$(< "$ZSWAP_PARAMS/compressor")
    [[ -r "$ZSWAP_PARAMS/max_pool_percent" ]] && pool=$(< "$ZSWAP_PARAMS/max_pool_percent")
    echo "BC-250 compressed swap"
    echo "  configured: $configured"
    echo "  runtime:    $runtime"
    echo "  swappiness: $swappiness"
    echo "  disk size:  ${SIZE_GIB:-0} GiB configured (toolkit-managed)"
    if [[ -e "$SWAPPINESS_CONFIG" || -L "$SWAPPINESS_CONFIG" ]]; then
        local selected_swappiness
        selected_swappiness=$(configured_swappiness) || { echo "  warning: invalid swappiness configuration"; return 2; }
        echo "  swappiness configured: $selected_swappiness"
        [[ "$swappiness" == "$selected_swappiness" ]] || runtime_mismatch=1
    fi
    echo "  zswap:      $zswap_enabled (compressor $compressor, pool ${pool}%)"
    if [[ "$configured" == zswap || "$configured" == legacy-zswap ]]; then
        echo "  compressor: $(configured_zswap_compressor) configured (applied on reboot)"
    elif [[ "$configured" == zram ]]; then
        echo "  compressor: $(configured_zram_compressor) configured (applied on reboot)"
    fi
    if [[ -r "$ZRAM_SYS/comp_algorithm" ]]; then
        local algorithms active_compressor=unknown
        algorithms=$(< "$ZRAM_SYS/comp_algorithm")
        if [[ "$algorithms" =~ \[([^]]+)\] ]]; then active_compressor="${BASH_REMATCH[1]}"; fi
        echo "  zram:       compressor $active_compressor"
    fi
    if [[ -r "$PROC_SWAPS" ]]; then
        while read -r active type size used priority; do
            [[ "$active" == Filename || -z "$active" ]] && continue
            if [[ "$size" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]]; then
                size_mib=$((size / 1024))
                used_mib=$((used / 1024))
                total_swap_kib=$((total_swap_kib + size))
                echo "  active swap: $active ($type, ${used_mib}/${size_mib} MiB used, priority $priority)"
            else
                echo "  active swap: $active ($type, usage unavailable, priority $priority)"
            fi
        done < "$PROC_SWAPS"
        echo "  capacity:   $((total_swap_kib / 1024)) MiB active (all swap devices)"
    fi
    if [[ -r "$ZRAM_SYS/mm_stat" ]]; then
        read -r original compressed resident _ < "$ZRAM_SYS/mm_stat" || true
        if [[ "$original" =~ ^[0-9]+$ && "$compressed" =~ ^[0-9]+$ \
            && "$resident" =~ ^[0-9]+$ ]]; then
            echo "  zram memory: $((original / 1024 / 1024)) MiB uncompressed used, $((compressed / 1024 / 1024)) MiB compressed, $((resident / 1024 / 1024)) MiB resident"
        fi
    fi
    if [[ -r "$VMSTAT" ]]; then
        swap_in=$(awk '$1 == "pswpin" { print $2 }' "$VMSTAT")
        swap_out=$(awk '$1 == "pswpout" { print $2 }' "$VMSTAT")
        echo "  swap I/O:   ${swap_in:-unknown} pages in, ${swap_out:-unknown} pages out since boot"
    fi
    if [[ -r "$MEMORY_PRESSURE" ]]; then
        psi_some=$(awk '$1 == "some" { sub(/^avg10=/, "", $2); print $2 }' "$MEMORY_PRESSURE")
        psi_full=$(awk '$1 == "full" { sub(/^avg10=/, "", $2); print $2 }' "$MEMORY_PRESSURE")
        echo "  memory PSI: some avg10 ${psi_some:-unknown}%, full avg10 ${psi_full:-unknown}%"
    fi
    if [[ -r "$ZSWAP_DEBUG/pool_total_size" && -r "$ZSWAP_DEBUG/stored_pages" ]]; then
        pool_bytes=$(< "$ZSWAP_DEBUG/pool_total_size")
        stored_pages=$(< "$ZSWAP_DEBUG/stored_pages")
        if [[ "$pool_bytes" =~ ^[0-9]+$ && "$stored_pages" =~ ^[0-9]+$ ]]; then
            echo "  zswap memory: $((pool_bytes / 1024 / 1024)) MiB resident, $stored_pages pages stored"
        fi
    fi
    if [[ -r "$ZSWAP_DEBUG/written_back_pages" ]]; then
        written_back_pages=$(< "$ZSWAP_DEBUG/written_back_pages")
        [[ "$written_back_pages" =~ ^[0-9]+$ ]] \
            && echo "  zswap writeback: $written_back_pages pages since boot"
    fi
    if [[ "$configured" == zswap || "$configured" == legacy-zswap || ( "$configured" == zram && "$SIZE_GIB" -gt 0 ) \
        || ( "$configured" == zram && "${PENDING:-}" == zswap-removal ) ]]; then
        echo "  swapfile:   $SWAPFILE (${SIZE_GIB} GiB configured)"
    fi
    local effective_pending="${PENDING:-}"
    if [[ "$MODE" == zswap && "$effective_pending" == reboot ]] && zswap_runtime_matches; then
        effective_pending=none
    fi
    if [[ "$configured" == zram && "$effective_pending" == reboot ]] && zram_profile_runtime_matches; then
        effective_pending=none
    fi
    if [[ -n "$effective_pending" && "$effective_pending" != none ]]; then
        echo "  pending:    $effective_pending"
    fi
    [[ "$configured" != partial && "$runtime" != mixed ]] || return 2
    if [[ $legacy_profile -eq 1 ]]; then
        echo "  upgrade:    rerun 'install zswap' to update the profile and boot ordering"
        return 3
    fi
    if [[ "$configured" == zswap && "$effective_pending" == none ]] && ! zswap_runtime_matches; then
        echo "  warning:    active zswap runtime does not match the safe profile"
        runtime_mismatch=1
    fi
    if [[ "$configured" == zram && "$SIZE_GIB" -gt 0 && "$effective_pending" == none ]] && ! zram_profile_runtime_matches; then
        echo "  warning:    active zram runtime does not match the configured profile"
        runtime_mismatch=1
    fi
    [[ $runtime_mismatch -eq 0 ]] || return 2
    [[ "$configured" != none ]] || return 1
    configured_complete || return 2
}

cmd_installed() {
    if configured_complete || legacy_zswap_configured_complete; then
        echo installed
        return 0
    fi
    echo not-installed
    return 1
}

cmd_status_json() {
    local detail rc=0 mode=none size=0 compressor="" selected="" current=""
    detail=$(cmd_status) || rc=$?
    if read_state; then
        mode="$MODE"; size="$SIZE_GIB"
        if [[ "$mode" == zram ]]; then compressor=$(configured_zram_compressor); else compressor=$(configured_zswap_compressor); fi
    fi
    selected=$(configured_swappiness || true)
    [[ ! -r "$SWAPPINESS_SYS" ]] || current=$(< "$SWAPPINESS_SYS")
    python3 - "$rc" "$mode" "$size" "$compressor" "$selected" "$current" "$detail" <<'PY'
import json
import re
import sys
rc, mode, size, compressor, selected, current, detail = sys.argv[1:]
lines = dict(line.strip().split(':', 1) for line in detail.splitlines() if ':' in line)
capacity = re.match(r'\s*([0-9]+) MiB', lines.get('capacity', ''))
print(json.dumps({
    'schemaVersion': 1,
    'configuredProfile': lines.get('configured', mode).strip(),
    'runtime': lines.get('runtime', 'unknown').strip(),
    'diskSizeGiB': int(size),
    'activeSizeMiB': int(capacity.group(1)) if capacity else None,
    'compressor': compressor or None,
    'pending': lines.get('pending', 'none').strip(),
    'swappiness': int(current) if current.isdecimal() else None,
    'configuredSwappiness': int(selected) if selected.isdecimal() else None,
    'healthy': rc == '0' and lines.get('pending', 'none').strip() == 'none',
    'details': detail,
}))
PY
}

cmd_verify() {
    require_root
    local rc=0
    cmd_status || rc=$?
    [[ $rc -eq 0 || $rc -eq 3 ]] || return "$rc"
    if read_state && [[ "$SIZE_GIB" -gt 0 ]]; then
        if ! validate_swapfile "$((SIZE_GIB * 1024 * 1024 * 1024))"; then
            log "The toolkit swapfile size or swap signature is invalid." >&2
            return 2
        fi
        echo "  verification: swap signature valid"
    else
        echo "  verification: zram configuration valid"
    fi
    [[ $rc -eq 0 ]] || return "$rc"
}

cmd_uninstall() {
    if ! begin_cleanup_lifecycle; then
        log "No toolkit swap profile is installed."
        return 0
    fi
    local current_mode=""
    if read_state; then current_mode="$MODE"; fi
    if swap_active "$SWAPFILE"; then
        rm -f "$SWAP_WANTS" "$ZRAM_CONFIG" "$ZSWAP_TMPFILES" "$SERVICE" "$HELPER" "$SWAPPINESS_CONFIG"
        write_profile_state "${current_mode:-zswap}" "${SIZE_GIB:-$DEFAULT_SWAP_GIB}" uninstall
        systemctl daemon-reload
        log "The disk swap remains active for this boot. Reboot, then rerun uninstall to remove it safely."
        return 75
    fi
    remove_zswap_files
    rm -f "$ZRAM_CONFIG" "$STATE_FILE" "$SWAPPINESS_CONFIG"
    rmdir "$STATE_DIR" 2>/dev/null || true
    systemctl daemon-reload
    remove_persistence
    log "Removed the toolkit swap profile; Valve's zram and swappiness defaults apply after reboot."
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

swap_menu_set_size() {
    local value
    printf 'Disk swap size in GiB (%s-%s, or 0 for zram-only; selected: %s; blank cancels): ' \
        "$MIN_SWAP_GIB" "$MAX_SWAP_GIB" "${SWAP_MENU_SIZE_GIB:-$DEFAULT_SWAP_GIB}"
    if ! IFS= read -r value || [[ -z "$value" ]]; then
        log "Cancelled."
        return 0
    fi
    if [[ "$value" != 0 ]]; then
        (validate_size "$value") || return 0
    fi
    SWAP_MENU_SIZE_GIB="$value"
    log "Selected ${value} GiB disk swap for this menu session. Choose a zram or zswap profile to apply it (0 requires zram)."
    log "Existing swapfiles cannot be resized in place: remove the profile, reboot if requested, finish removal, then install the new size."
}

swap_menu_install() {
    local mode="$1" compressor="$2" size="${SWAP_MENU_SIZE_GIB:-$DEFAULT_SWAP_GIB}"
    if [[ "$mode" == zswap && "$size" == 0 ]]; then
        log "Zswap requires ${MIN_SWAP_GIB}-${MAX_SWAP_GIB} GiB of disk swap. Set a nonzero disk swap size first, or choose zram."
        return 0
    fi
    if [[ "$size" != 0 && ( -e "$SWAPFILE" || -L "$SWAPFILE" ) ]] \
        && read_state && [[ "$SIZE_GIB" != "$size" ]]; then
        log "The existing toolkit swapfile is ${SIZE_GIB} GiB; it cannot be resized in place."
        log "Choose 'Remove toolkit profile', reboot if requested, finish removal, then select the new size and profile."
        return 0
    fi
    case "$mode" in
        zram) confirm_action "Configure $compressor zram with ${size} GiB disk fallback (0 means none)?" cmd_install_zram "$compressor" "$size" ;;
        zswap) confirm_action "Configure $compressor zswap with a ${size} GiB disk swapfile?" cmd_install_zswap "$size" "$compressor" ;;
    esac
}

swap_menu_graph_badge() {
    local badge="${CD}[not configured]${C0}"
    case "$1" in
        action__status|action__zram|action__zram_lz4|action__zswap|action__zswap_zstd|action__remove)
            if configured_complete && read_state; then
                badge="${CG}[${MODE}]${C0}"
            elif legacy_zswap_configured_complete; then
                badge="${CY}[upgrade]${C0}"
            elif ! swap_has_artifacts && zram_runtime_matches; then
                badge="${CG}[SteamOS default]${C0}"
            fi
            printf '%s' "$badge"
            ;;
        action__size) printf '%s' "${CC}[${SWAP_MENU_SIZE_GIB:-$DEFAULT_SWAP_GIB} GiB selected]${C0}" ;;
        action__swappiness|action__help) ;;
        *) return 2 ;;
    esac
}

swap_menu_graph_activate() {
    echo
    case "$1" in
        action__status) cmd_status || true ;;
        action__size) swap_menu_set_size ;;
        action__zram) swap_menu_install zram zstd ;;
        action__zram_lz4) swap_menu_install zram lz4 ;;
        action__zswap) swap_menu_install zswap lz4 ;;
        action__zswap_zstd) swap_menu_install zswap zstd ;;
        action__swappiness)
            local value
            printf 'Swappiness (0-200; current: %s): ' "$(cat "$SWAPPINESS_SYS" 2>/dev/null || echo unknown)"
            IFS= read -r value
            if [[ -n "$value" ]]; then cmd_swappiness "$value"; else log "Cancelled."; fi
            ;;
        action__remove) confirm_action "Remove the toolkit swap profile?" cmd_uninstall ;;
        action__help) cmd_help ;;
        *) die "Unknown generated swap menu target: $1" ;;
    esac
    echo
    printf '%s' "${CD}-- press any key to continue --${C0}"
    IFS= read -rsn1 || true
}

# BEGIN GENERATED SWAP MENUS
# Generated from menus/swap.mmd by scripts/generate-menus.py.
# Do not edit this region directly.
swap_menu_graph_render() {
    local menu_id="$1" title target badge
    if declare -F swap_menu_graph_prepare >/dev/null; then swap_menu_graph_prepare "$menu_id"; fi
    while true; do
        local items=() targets=() badges=()
        case "$menu_id" in
            menu__root)
                title="BC-250 compressed swap"
                if ! badge=$(swap_menu_graph_badge action__status read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__status"
                fi
                items+=("Status overview|${badge}|Show the configured profile, active swap, zswap state, and swappiness.")
                targets+=("action__status")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__size install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__size"
                fi
                items+=("Set disk swap size|${badge}|Choose 4-64 GiB (default 16), or 0 for zram-only; then select a profile below to apply. Existing files require removal before resizing.")
                targets+=("action__size")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__zram install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__zram"
                fi
                items+=("Use zram (zstd)|${badge}|Half-RAM compressed swap at priority 100 with the selected disk fallback at priority 10 (0 disables fallback). Disables zswap; reboot to apply.")
                targets+=("action__zram")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__zram_lz4 install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__zram_lz4"
                fi
                items+=("Use zram (lz4)|${badge}|Fast lz4 compressed swap at priority 100 with the selected disk fallback at priority 10 (0 disables fallback). Disables zswap; reboot to apply.")
                targets+=("action__zram_lz4")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__zswap install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__zswap"
                fi
                items+=("Use zswap + disk (lz4)|${badge}|Use fast lz4 zswap with a 10% RAM pool, memory shrinker, and the selected disk swapfile at priority 10. Reboot to apply.")
                targets+=("action__zswap")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__zswap_zstd install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__zswap_zstd"
                fi
                items+=("Use zswap + disk (zstd)|${badge}|Use higher-ratio zstd zswap with the same 10% RAM pool, memory shrinker, and selected disk swapfile. Reboot to apply.")
                targets+=("action__zswap_zstd")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__swappiness install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__swappiness"
                fi
                items+=("Set swappiness (zram / zswap)|${badge}|Set vm.swappiness from 0 to 200 now and at boot. Applies to the selected profile; retained when switching profiles.")
                targets+=("action__swappiness")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__remove cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__remove"
                fi
                items+=("Remove toolkit profile|${badge}|Remove toolkit-owned swap settings and return to Valve's zram defaults.")
                targets+=("action__remove")
                badges+=("$badge")
                if ! badge=$(swap_menu_graph_badge action__help read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__help"
                fi
                items+=("Full help|${badge}|Show profile details, CLI commands, paths, and reboot behavior.")
                targets+=("action__help")
                badges+=("$badge")
                ;;
            *) die "Unknown generated swap menu ID: $menu_id" ;;
        esac
        if [[ "$title" == *"|"* || "$title" == *[[:cntrl:]]* ]]; then
            die "Invalid generated swap menu title"
        fi
        menu_select "$title" "${items[@]}" || { echo; return 0; }
        target=${targets[$MENU_CHOICE]}
        if [[ "$target" == menu__* ]]; then
            swap_menu_graph_render "$target"
        else
            swap_menu_graph_activate "$target" "${badges[$MENU_CHOICE]}"
        fi
    done
}

swap_menu_graph_open() {
    case "${1:-root}" in
        root) swap_menu_graph_render menu__root ;;
        *) return 2 ;;
    esac
}

# END GENERATED SWAP MENUS

cmd_menu() {
    require_root
    local SWAP_MENU_SIZE_GIB="$DEFAULT_SWAP_GIB"
    if read_state; then SWAP_MENU_SIZE_GIB="$SIZE_GIB"; fi
    swap_menu_graph_open root
}

cmd_help() {
    cat <<EOF
Usage: $0 [menu|install MODE [OPTIONS]|swappiness VALUE|status|verify|installed|uninstall|help]

  install zram [zstd|lz4] [SIZE_GIB]
                            Use compressed RAM swap: ram/2 logical capacity,
                            allocated on demand, priority 100, with a 16 GiB
                            disk fallback at priority 10; zswap is disabled.
                            SIZE_GIB=0 opts out of the disk fallback.
                            Compression defaults to zstd; lz4 is optional.
  install zswap [SIZE_GIB] [lz4|zstd]
                            Use zswap with lz4 compression by default (zstd optional),
                            a 10% RAM pool, memory shrinker,
                            and disk swapfile at priority 10 (default: 16 GiB).
  status                    Show configured, active, and pending swap state.
  status --json             Read-only structured status for the frontends.
  swappiness VALUE          Set vm.swappiness (0-200) now and at boot for either
                            profile. Retained on profile changes; removal restores
                            the OS default after reboot. No default override.
  verify                    Privileged status plus disk swap-signature validation.
  installed                 Machine-readable installation probe.
  uninstall                 Remove toolkit settings and restore Valve defaults.

The profiles are mutually exclusive and transitions are reboot-gated. Use
the menu's 'Set disk swap size' before choosing a profile to apply that size.
The selection starts at the configured size, or 16 GiB for a new installation.
Change the compressor by rerunning install with the desired compressor (and the same
swapfile size for either profile); reboot to apply it. Existing swapfiles are
reused, never resized in place; uninstall and reboot before changing their size.
Lz4 favors compression speed;
zstd favors compression ratio.

The script never performs a live swapoff or removes an active swapfile. Zswap is a
global kernel cache and therefore also compresses pages sent to other active
disk swap devices; unrelated swap devices are otherwise left unchanged. Zram
is the recommended default. Sustained zswap pressure can still write pages to
disk and cause storage latency even with the bounded cache and memory shrinker.
EOF
}

case "${1:-menu}" in
    menu) (($# == 0 || $# == 1)) || die "Usage: $0 menu"; cmd_menu ;;
    install)
        case "${2:-}" in
            zram) (($# >= 2 && $# <= 4)) || die "Usage: $0 install zram [zstd|lz4] [SIZE_GIB]"; cmd_install_zram "${3:-zstd}" "${4:-$DEFAULT_SWAP_GIB}" ;;
            zswap) (($# >= 2 && $# <= 4)) || die "Usage: $0 install zswap [SIZE_GIB] [lz4|zstd]"; cmd_install_zswap "${3:-$DEFAULT_SWAP_GIB}" "${4:-lz4}" ;;
            *) die "Usage: $0 install {zram [zstd|lz4]|zswap [SIZE_GIB] [lz4|zstd]}" ;;
        esac
        ;;
    status)
        if [[ $# == 2 && "$2" == --json ]]; then cmd_status_json
        elif [[ $# == 1 ]]; then cmd_status
        else die "Usage: $0 status [--json]"; fi ;;
    swappiness) (($# == 2)) || die "Usage: $0 swappiness VALUE"; cmd_swappiness "$2" ;;
    verify) (($# == 1)) || die "Usage: $0 verify"; cmd_verify ;;
    installed) (($# == 1)) || die "Usage: $0 installed"; cmd_installed ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) die "Usage: $0 {menu|install|status|verify|installed|uninstall|help}" ;;
esac
