#!/usr/bin/env bash
# bc250-power.sh
#
# Complete power-management setup for the BC-250 on SteamOS 3.8.x:
#
#   ACPI fix (bc250-collective + mendesrr, guarded universal tables):
#     SSDT-CST -> CPU C-states (C1/C2/C3 idle sleep)
#     SSDT-PST -> CPU P-states (800-3200 MHz cpufreq scaling)
#     Loaded as an early-initrd ACPI override via GRUB. The BC-250 BIOS
#     ships no CPU power tables at all -- without this, cores never idle.
#
#   GPU governor (filippor/cyan-skillfish-governor, SMU variant):
#     Dynamic freq/voltage via SMU firmware calls. NO kernel patch needed.
#     Without a governor the GPU is locked at 1500 MHz and idles hot.
#
# SteamOS persistence model used throughout:
#   ~/.local/share/bc250-fixes/bc250-steamos  source and build inputs
#   /var/lib/bc250-control                    trusted executables and state
#   /etc                                      configs and units, retained by an
#                                             atomic-update keep list
#   /boot                cpio must live here for GRUB           -- WIPED by updates
#   /efi                 active SteamOS GRUB config
#                        -> a boot-time self-heal service restores both
#
# Usage (root):
#   ./bc250-power.sh acpi          install ACPI override + self-heal
#   ./bc250-power.sh governor      install SMU GPU governor (test-start)
#   ./bc250-power.sh enable        enable governor + cpufreq at boot
#   ./bc250-power.sh cpu-unlock    manage the optional 8-core unlock
#   ./bc250-power.sh installed     machine-readable install detection
#   ./bc250-power.sh uninstall     restore stock behavior + remove integration
#   ./bc250-power.sh status        clocks, C-states, temps, services
#   ./bc250-power.sh all           acpi + governor
set -euo pipefail

REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
if [[ "$REAL_USER" == root ]] && getent passwd deck >/dev/null 2>&1; then
    REAL_USER=deck
fi
REAL_HOME="${REAL_HOME:-$(getent passwd "$REAL_USER" | cut -d: -f6)}"
[[ "$REAL_HOME" == /* ]] || { echo "Could not resolve the real user's home directory." >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXES_REPO_DIR="${FIXES_REPO_DIR:-$REAL_HOME/.local/share/bc250-fixes/bc250-steamos}"
[[ "$FIXES_REPO_DIR" == /* && "$FIXES_REPO_DIR" != *[$'\n\r\t ']* ]] \
    || { echo "FIXES_REPO_DIR must be an absolute path without whitespace." >&2; exit 1; }
PREFIX="$FIXES_REPO_DIR"
ROOT_DATA_DIR="/var/lib/bc250-control"
COMPUTE_MIGRATION_MARKER="$ROOT_DATA_DIR/.legacy-compute-migrated"
POWER_MIGRATION_MARKER="$ROOT_DATA_DIR/.legacy-power-migrated"
LEGACY_PREFIX="/var/lib/bc250-40cu"
BIN_DIR="$ROOT_DATA_DIR/bin"
ACPI_DIR="$ROOT_DATA_DIR/acpi"
CPIO_MASTER="$ACPI_DIR/acpi_override.cpio"
CPIO_BOOT="/boot/acpi_override.cpio"
ACPI_READY="$ACPI_DIR/boot-ready"
ACPI_PAYLOAD_MARKER="$ACPI_DIR/payload-version"
ACPI_PAYLOAD_VERSION="universal-6c8c-v1"
ACPI_TABLE_DIR="${BC250_ACPI_TABLE_DIR:-$SCRIPT_DIR/acpi-tables}"
ACPI_LIFECYCLE_LOCK="/run/lock/bc250-acpi.lock"
GRUB_CONFIG_LOCK="${GRUB_CONFIG_LOCK:-/run/lock/bc250-grub-config.lock}"
PCI_DEVICES_ROOT="${BC250_PCI_DEVICES_ROOT:-/sys/bus/pci/devices}"
GRUB_CFG="/efi/EFI/steamos/grub.cfg"
GRUB_ACPI_DEFAULT="/etc/default/grub.d/bc250-acpi.cfg"
GRUB_DEFAULT="${GRUB_DEFAULT:-/etc/default/grub}"
CPU_MITIGATIONS_CONFIG="${CPU_MITIGATIONS_CONFIG:-/etc/default/grub.d/bc250-cpu-mitigations.cfg}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"

GOV_BIN="$BIN_DIR/cyan-skillfish-governor-smu"
PERF_BIN="$BIN_DIR/cyan-skillfish-performance-mode"
GOV_CONF_DIR="/etc/cyan-skillfish-governor-smu"
GOV_CONF="$GOV_CONF_DIR/config.toml"
GOV_UNIT="/etc/systemd/system/cyan-skillfish-governor-smu.service"
GOV_SVC="cyan-skillfish-governor-smu.service"
GPU_CONTROL_LOCK="${GPU_CONTROL_LOCK:-/run/lock/bc250-control/backend.lock}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
GPU_CONTROL_LOCK_HELD=0
DBUS_POLICY="/etc/dbus-1/system.d/com.cyan.SkillFishGovernor.conf"
GOV_API="https://api.github.com/repos/filippor/cyan-skillfish-governor/releases/latest"
GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/smu"

HEAL_UNIT="/etc/systemd/system/bc250-acpi-heal.service"
HEAL_HELPER="$ROOT_DATA_DIR/helper/bc250-acpi-heal"
LEGACY_HEAL_HELPER="/etc/bc250-acpi-heal.sh"
CPUFREQ_UNIT="/etc/systemd/system/bc250-cpufreq.service"
POWER_KEEP_FILE="/etc/atomic-update.conf.d/bc250-power.conf"
SYSTEMD_WANTS_DIR="/etc/systemd/system/multi-user.target.wants"

FREQ_STATE="$ROOT_DATA_DIR/governor/freq-state"
RESTORE_BIN="$BIN_DIR/bc250-gpu-freq-restore"
RESTORE_UNIT="/etc/systemd/system/bc250-gpu-freq-restore.service"
RESTORE_SVC="bc250-gpu-freq-restore.service"
RECOVERY_SVC="bc250-persistence-recovery.service"

# CPU OC (bc250-collective/bc250_smu_oc) -- fetched from upstream at a pinned
# commit, then our SteamOS patches (shipped in smu-oc-patches/ next to this
# script) are overlaid. No local clone is kept.
OC_PIN="43d6b4c6e38c57bc9ec8908c44675ce7d5fd3d2f"
OC_TARBALL="https://github.com/bc250-collective/bc250_smu_oc/archive/$OC_PIN.tar.gz"
OC_PATCH_DIR="$SCRIPT_DIR/smu-oc-patches"
OC_DIR="${BC250_OC_DIR:-$ROOT_DATA_DIR/smu-oc}"
OC_STAGE_CONF="$OC_DIR/overclock.conf"
OC_CONF="/etc/bc250-smu-oc.conf"
OC_UNIT="/etc/systemd/system/bc250-smu-oc.service"
OC_SVC="bc250-smu-oc.service"
CORE_UNLOCK_SOURCE="$SCRIPT_DIR/core-unlock/bc250-unlock-cores.py"
CORE_UNLOCK_LICENSE_SOURCE="$SCRIPT_DIR/core-unlock/LICENSE"
CORE_UNLOCK_BIN="$ROOT_DATA_DIR/helper/bc250-unlock-cores"
CORE_UNLOCK_LICENSE="$ROOT_DATA_DIR/licenses/bc250-core-unlock-LICENSE"
CORE_UNLOCK_STATE_DIR="$ROOT_DATA_DIR/core-unlock"
CORE_UNLOCK_PENDING="$CORE_UNLOCK_STATE_DIR/reboot-pending"
CORE_UNLOCK_LOCK="/run/lock/bc250-core-unlock.lock"
CORE_UNLOCK_LIFECYCLE_LOCK="/run/lock/bc250-core-unlock-lifecycle.lock"
CORE_UNLOCK_UNIT="/etc/systemd/system/bc250-core-unlock.service"
CORE_UNLOCK_SVC="bc250-core-unlock.service"
CORE_UNLOCK_EFI_SOURCE="$SCRIPT_DIR/core-unlock/bc250-unlock-cores-efi.c"
CORE_UNLOCK_EFI_LICENSE_SOURCE="$SCRIPT_DIR/core-unlock/EFI-LICENSE"
CORE_UNLOCK_EFI_HEADER_LICENSE_SOURCE="$SCRIPT_DIR/core-unlock/EFI-HEADERS-LICENSE"
CORE_UNLOCK_EFI_LICENSE="$ROOT_DATA_DIR/licenses/bc250-core-unlock-efi-LICENSE"
CORE_UNLOCK_EFI_HEADER_LICENSE="$ROOT_DATA_DIR/licenses/yoppeh-efi-LICENSE"
CORE_UNLOCK_EFI_PIN="761b114e3b186adb82516d5fa8e7a4c559f56ba5"
CORE_UNLOCK_EFI_REPO="https://github.com/yoppeh/efi.git"
CORE_UNLOCK_EFI_MASTER="$CORE_UNLOCK_STATE_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_STATE="$CORE_UNLOCK_STATE_DIR/efi-state"
CORE_UNLOCK_EFI_BOOTNUM="$CORE_UNLOCK_STATE_DIR/efi-bootnum"
CORE_UNLOCK_EFI_IMAGE_HASH="$CORE_UNLOCK_STATE_DIR/efi-image.sha256"
CORE_UNLOCK_EFI_RECOVERY="$CORE_UNLOCK_STATE_DIR/efi-recovery"
CORE_UNLOCK_ESP_ROOT="${BC250_CORE_UNLOCK_ESP_ROOT:-/efi}"
CORE_UNLOCK_ESP_SOURCE="${BC250_CORE_UNLOCK_ESP_SOURCE:-}"
CORE_UNLOCK_ESP_DISK="${BC250_CORE_UNLOCK_ESP_DISK:-}"
CORE_UNLOCK_ESP_PART="${BC250_CORE_UNLOCK_ESP_PART:-}"
CORE_UNLOCK_ESP_PARTUUID="${BC250_CORE_UNLOCK_ESP_PARTUUID:-}"
CORE_UNLOCK_ESP_PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
CORE_UNLOCK_STEAMOS_EFI_PARTTYPE="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
CORE_UNLOCK_STEAMOS_EFI_PARTSET="${BC250_STEAMOS_EFI_PARTSET:-/dev/disk/by-partsets/self/efi}"
CORE_UNLOCK_EFI_DIR="$CORE_UNLOCK_ESP_ROOT/EFI/bc250"
CORE_UNLOCK_EFI_IMAGE="$CORE_UNLOCK_EFI_DIR/bc250-core-unlock.efi"
CORE_UNLOCK_EFI_LABEL="BC250 Core Unlock"
CORE_UNLOCK_EFI_LOADER='\EFI\bc250\bc250-core-unlock.efi'
CORE_UNLOCK_EFI_GUARD_GUID="4f6f6f13-1ec2-4f26-a250-bc250c0e77ff"
CORE_UNLOCK_EFIVARS_DIR="${BC250_EFIVARS_DIR:-/sys/firmware/efi/efivars}"
TOPOLOGY_SH="${TOPOLOGY_SH:-$SCRIPT_DIR/topology.sh}"
AMDGPU_MODULES_ROOT="${AMDGPU_MODULES_ROOT:-/usr/lib/modules}"
UPDATE_PERSIST_SH="$SCRIPT_DIR/bc250-update-persistence.sh"
STORAGE_SH="$SCRIPT_DIR/bc250-storage.sh"

log()  { echo -e "\033[1;32m[power]\033[0m $*"; }
warn() { echo -e "\033[1;33m[power]\033[0m $*"; }
die()  { echo -e "\033[1;31m[power]\033[0m $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
install_update_persistence() {
    [[ -f "$UPDATE_PERSIST_SH" ]] \
        || die "Update persistence helper missing: $UPDATE_PERSIST_SH"
    bash "$UPDATE_PERSIST_SH" install power
}
remove_update_persistence() {
    [[ -f "$UPDATE_PERSIST_SH" && ! -L "$UPDATE_PERSIST_SH" ]] \
        || die "Update persistence helper missing or unsafe: $UPDATE_PERSIST_SH"
    bash "$UPDATE_PERSIST_SH" remove power
}
recover_update_settings() {
    [[ -f "$UPDATE_PERSIST_SH" ]] \
        || die "Update persistence helper missing: $UPDATE_PERSIST_SH"
    bash "$UPDATE_PERSIST_SH" recover power
}

migrate_legacy_data() {
    local file marker="$POWER_MIGRATION_MARKER"
    [[ -f "$STORAGE_SH" ]] || die "Storage helper missing: $STORAGE_SH"
    bash "$STORAGE_SH" install
    install -d -o root -g root -m 0755 "$BIN_DIR" "$ACPI_DIR" \
        "$ROOT_DATA_DIR/helper" "$ROOT_DATA_DIR/governor" "$OC_DIR"
    if [[ -d "$LEGACY_PREFIX" && ! -e "$marker" ]]; then
        [[ ! -d "$LEGACY_PREFIX/acpi" ]] \
            || cp -a "$LEGACY_PREFIX/acpi"/. "$ACPI_DIR"/
        [[ ! -d "$LEGACY_PREFIX/smu-oc" ]] \
            || cp -a "$LEGACY_PREFIX/smu-oc"/. "$OC_DIR"/
        for file in cyan-skillfish-governor-smu cyan-skillfish-performance-mode \
            bc250-gpu-freq-restore; do
            if [[ ! -e "$BIN_DIR/$file" && -f "$LEGACY_PREFIX/bin/$file" ]]; then
                install -o root -g root -m 0755 "$LEGACY_PREFIX/bin/$file" "$BIN_DIR/$file"
            fi
        done
        touch "$marker"
    fi
    if [[ ! -e "$FREQ_STATE" && -f "$GOV_CONF_DIR/freq-state" && ! -L "$GOV_CONF_DIR/freq-state" ]]; then
        install -o root -g root -m 0644 "$GOV_CONF_DIR/freq-state" "$FREQ_STATE"
        rm -f "$GOV_CONF_DIR/freq-state"
    fi
}

cleanup_legacy_data() {
    local file
    [[ -d "$LEGACY_PREFIX" ]] || return 0
    for file in /etc/systemd/system/bc250-cu-live-manager.service \
        /etc/bc250-cu-live-manager.conf "$HEAL_UNIT" "$GOV_UNIT" \
        "$RESTORE_UNIT" "$OC_UNIT" "$CORE_UNLOCK_UNIT"; do
        if [[ -f "$file" ]] && grep -qF "$LEGACY_PREFIX" "$file"; then
            warn "Legacy data retained while $file still references it."
            return 0
        fi
    done
    [[ -e "$COMPUTE_MIGRATION_MARKER" && -e "$POWER_MIGRATION_MARKER" ]] || return 0
    rm -rf "$LEGACY_PREFIX" "$ROOT_DATA_DIR/legacy-bc250-40cu"
    log "Removed fully migrated legacy data at $LEGACY_PREFIX."
}

RO_WAS_DISABLED=0
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable; RO_WAS_DISABLED=1
    fi
}
# NB: must return 0 when idle -- a nonzero return from the EXIT trap under
# set -e overrides the script's real exit status (every run would exit 1)
relock_rootfs() {
    if [[ $RO_WAS_DISABLED -eq 1 ]]; then
        steamos-readonly enable
        RO_WAS_DISABLED=0
    fi
}

prepare_pacman_keyring() {
    local keyring
    command -v pacman-key >/dev/null 2>&1 \
        || die "pacman-key is unavailable; cannot verify SteamOS packages."
    for keyring in archlinux holo; do
        [[ -s "/usr/share/pacman/keyrings/$keyring.gpg" ]] \
            || die "SteamOS package keyring is missing: $keyring.gpg"
    done
    log "Initialising the packaged SteamOS pacman trust keys..."
    pacman-key --init \
        || die "Could not initialise the pacman keyring."
    pacman-key --populate \
        || die "Could not populate the SteamOS package signing keys."
}

# Both the GPU governor and the CPU OC tool drive the SMU through the same
# PCI-config indirect window (0xB8/0xBC) -- never let them run concurrently.
GOV_STOPPED=0
pause_governor() {
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        log "Pausing GPU governor while touching the SMU..."
        if systemctl stop "$GOV_SVC"; then
            GOV_STOPPED=1
        else
            warn "Could not stop $GOV_SVC; refusing concurrent SMU access."
            return 1
        fi
    fi
}
resume_governor() {
    if [[ $GOV_STOPPED -eq 1 ]]; then
        if systemctl start "$GOV_SVC"; then
            log "GPU governor resumed."
            GOV_STOPPED=0
            if [[ -f "$FREQ_STATE" && -f "$RESTORE_UNIT" ]]; then
                systemctl restart "$RESTORE_SVC" \
                    || warn "GPU governor resumed, but the saved frequency range was not restored."
            fi
        else
            warn "GPU governor failed to resume; run: systemctl start $GOV_SVC"
            return 1
        fi
    fi
}

TEMP_DIRS=()
TEMP_FILES=()
GRUB_LOCK_HELD=0
CPU_MITIGATIONS_TRANSACTION_ACTIVE=0
CPU_MITIGATIONS_TRANSACTION_CONFIG_BACKUP=""
CPU_MITIGATIONS_TRANSACTION_GRUB_BACKUP=""
CPU_MITIGATIONS_TRANSACTION_HAD_CONFIG=0
CPU_MITIGATIONS_TRANSACTION_HAD_GRUB=0
EFI_TRANSACTION_ACTIVE=0
EFI_TRANSACTION_BOOTNUM=""
efi_transaction_rollback() {
    local number rc=0
    [[ $EFI_TRANSACTION_ACTIVE -eq 1 ]] || return 0
    if ! efi_recovery_read || ! verify_core_unlock_recovery_esp_state; then
        warn "Rollback retained EFI artifacts because ESP ownership could not be revalidated."
        return 1
    fi
    if ! efi_read_boot_listing; then
        warn "Rollback retained EFI artifacts because EFI Boot entries could not be read."
        return 1
    fi
    if [[ -n "$EFI_TRANSACTION_BOOTNUM" ]]; then
        number="$EFI_TRANSACTION_BOOTNUM"
        if efi_number_in_csv "$EFI_RECOVERY_BEFORE" "$number"; then
            warn "Rollback retained EFI artifacts because Boot$number failed exact transaction validation."
            return 1
        fi
        if efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING" \
            && ! efi_boot_entry_matches_in "$number" 0 "$EFI_BOOT_LISTING"; then
            warn "Rollback retained EFI artifacts because Boot$number failed exact transaction validation."
            return 1
        fi
    else
        if ! efi_recovery_resolve_boot_number "$EFI_BOOT_LISTING"; then
            warn "Rollback retained EFI artifacts because the created Boot entry could not be identified safely."
            return 1
        fi
        number="$EFI_RECOVERY_RESOLVED_BOOTNUM"
    fi
    if [[ -n "$number" ]] && efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING"; then
        if ! efibootmgr --bootnum "$number" --delete-bootnum >/dev/null 2>&1 \
            || ! efi_read_boot_listing \
            || efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING"; then
            warn "Rollback retained EFI artifacts because Boot$number could not be deleted and verified absent."
            return 1
        fi
    fi
    rm -f "$CORE_UNLOCK_EFI_STATE" "$CORE_UNLOCK_EFI_BOOTNUM" \
        "$CORE_UNLOCK_EFI_IMAGE_HASH" "$CORE_UNLOCK_EFI_RECOVERY" \
        "$CORE_UNLOCK_EFI_IMAGE" \
        "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_LICENSE" \
        "$CORE_UNLOCK_EFI_HEADER_LICENSE" || rc=1
    rmdir "$CORE_UNLOCK_EFI_DIR" 2>/dev/null || true
    EFI_TRANSACTION_ACTIVE=0
    return "$rc"
}
cleanup() {
    local temp_dir temp_file
    tui_show_cursor
    cpu_mitigations_rollback || true
    efi_transaction_rollback || true
    resume_governor || true
    for temp_dir in "${TEMP_DIRS[@]-}"; do
        [[ -z "$temp_dir" ]] || rm -rf "$temp_dir"
    done
    for temp_file in "${TEMP_FILES[@]-}"; do
        [[ -z "$temp_file" ]] || rm -f "$temp_file"
    done
    relock_rootfs || true
    grub_config_unlock || true
    gpu_control_unlock || true
}
trap cleanup EXIT

# ========================= pure-bash TUI menu =============================
# Zero dependencies: ANSI colors + read -rsn1 keyboard handling. The guided
# menu (run with no arguments) is a thin skin -- every action calls the same
# cmd_* function as the CLI, so nothing is menu-only.
C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'

TUI_CURSOR_HIDDEN=0
tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then printf '\033[?25h'; TUI_CURSOR_HIDDEN=0; fi
}

# menu_select "Title" "label|badge|hint" ...
# up/down or j/k to move, Enter selects (MENU_CHOICE=index), q/Esc backs out
# (returns 1). Clears and redraws from the top so nested menus stay anchored.
menu_select() {
    local title="$1"; shift
    local items=("$@") n=$# cur=0 key rest i label badge hint label_width=0
    for i in "${!items[@]}"; do
        IFS='|' read -r label badge hint <<< "${items[$i]}"
        if ((${#label} > label_width)); then label_width=${#label}; fi
    done
    printf '\033[?25l'; TUI_CURSOR_HIDDEN=1
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
            $'\033[A'|k) if (( cur > 0 ));   then cur=$((cur-1)); else cur=$((n-1)); fi ;;
            $'\033[B'|j) if (( cur < n-1 )); then cur=$((cur+1)); else cur=0; fi ;;
            "")          MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

pause_key() {
    echo
    printf '%s' "${CD}-- press any key to return to the menu --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

ask() {   # ask "Prompt" [default] -> REPLY
    local prompt="$1" def="${2:-}"
    REPLY=""
    if [[ -n "$def" ]]; then
        read -rp "  $prompt [$def]: " REPLY || true
        [[ -n "$REPLY" ]] || REPLY="$def"
    else
        read -rp "  $prompt: " REPLY || true
    fi
}

# run a cmd_* in a subshell with its own cleanup trap: a die() inside an
# action drops back to the menu instead of killing it, and the subshell
# still relocks the rootfs / resumes the governor on the way out
run_action() {
    local rc=0
    set +e
    ( set -e; trap cleanup EXIT; "$@" )
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        echo -e "${CR}${CB}[power]${C0} action failed (exit $rc) -- see message above."
    fi
    pause_key
}

b_ok()   { printf '%s' "${CG}[$1]${C0}"; }
b_mid()  { printf '%s' "${CY}[$1]${C0}"; }
b_off()  { printf '%s' "${CD}[$1]${C0}"; }

c_state() {   # colorize systemctl is-enabled / is-active words
    case "$1" in
        enabled|active|running) printf '%s' "${CG}$1${C0}" ;;
        failed|masked)          printf '%s' "${CR}$1${C0}" ;;
        disabled|inactive|-)    printf '%s' "${CD}$1${C0}" ;;
        *)                      printf '%s' "${CY}$1${C0}" ;;
    esac
}

badge_acpi() {
    if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then b_ok "active"
    elif acpi_boot_ready; then b_mid "installed - reboot pending"
    elif [[ -f "$HEAL_UNIT" ]]; then b_mid "installed - boot repair needed"
    else b_off "not installed"; fi
}

current_os_build() {
    if [[ -r /etc/os-release ]]; then
        ( . /etc/os-release; printf '%s\n' "${BUILD_ID:-${VERSION_ID:-unknown}}" )
    else
        printf '%s\n' unknown
    fi
}

acpi_boot_ready() {
    local ready=""
    acpi_payload_current || return 1
    [[ -f "$CPIO_MASTER" && -f "$CPIO_BOOT" && -f "$ACPI_READY" ]] || return 1
    cmp -s "$CPIO_MASTER" "$CPIO_BOOT" || return 1
    IFS= read -r ready < "$ACPI_READY" || return 1
    [[ "$ready" == "$(current_os_build)" ]] || return 1
    grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' \
        "$GRUB_ACPI_DEFAULT" 2>/dev/null
}
badge_governor() {
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then b_ok "running"
    elif [[ -x "$GOV_BIN" ]]; then b_mid "installed - not running"
    else b_off "not installed"; fi
}
badge_gov_boot() {
    if [[ "$(systemctl is-enabled "$GOV_SVC" 2>/dev/null)" == enabled ]]; then b_ok "enabled"
    else b_off "not enabled"; fi
}
badge_freq() {
    if [[ -f "$FREQ_STATE" ]]; then
        # shellcheck source=/dev/null
        b_mid "saved: $(tr '\n' ' ' < "$FREQ_STATE" | xargs || true)"
    else b_off "config defaults"; fi
}
badge_load_target() {
    local cfg=""
    cfg=$(lt_config_get)
    if [[ -z "$cfg" ]]; then b_off "governor built-ins"
    elif [[ "$cfg" == "$LT_DEF_UPPER $LT_DEF_LOWER" ]]; then b_ok "tuned default ${cfg/ /\/}"
    else b_mid "custom: ${cfg/ /\/}"; fi
    return 0
}
badge_ramp() {
    local adj n ms step
    adj=$(toml_get timing.intervals adjust)
    n=$(toml_get timing.ramp-rates normal)
    if [[ -z "$adj" || -z "$n" ]]; then b_off "governor built-ins"
    else
        ms=$(( adj / 1000 ))
        step=$(awk -v n="$n" -v m="$ms" 'BEGIN{ printf "%d", n * m }')
        if [[ "$ms" == "$RAMP_DEF_ADJ_MS" && "$n" == "$RAMP_DEF_NORMAL" ]]; then
            b_ok "default: ${step} MHz/${ms} ms"
        else
            b_mid "custom: ${step} MHz/${ms} ms"
        fi
    fi
    return 0
}
badge_oc() {
    local d=""
    d=$(oc_detected_result "$OC_CONF")
    if [[ -z "$d" && -f "$OC_CONF" ]]; then
        d="$(sed -n 's/^frequency = //p' "$OC_CONF" | head -1) MHz"
    fi
    if [[ "$(systemctl is-enabled "$OC_SVC" 2>/dev/null)" == enabled ]]; then b_ok "enabled${d:+ - $d}"
    elif [[ -f "$OC_CONF" || -f "$OC_STAGE_CONF" ]]; then b_mid "detected - not enabled"
    else b_off "stock"; fi
}
badge_oc_saved() {   # persistence verdict, for the enable row
    case "$(oc_persist_state)" in
        none)  b_off "nothing detected yet" ;;
        saved) b_ok "saved - applies at boot" ;;
        stale) b_mid "NOT saved - boot config older" ;;
        live)  b_mid "NOT saved - live only" ;;
    esac
    return 0
}
badge_oc_last() {   # last measured detect result, for the detect row
    local f res
    for f in "$OC_STAGE_CONF" "$OC_CONF"; do
        res=$(oc_detected_result "$f")
        if [[ -n "$res" ]]; then b_mid "last: $res"; break; fi
    done
    return 0
}
badge_oc_live() {   # live CPU voltage, for the status row
    local mv_=""
    mv_=$(oc_live_mv) || mv_=""
    if [[ -n "$mv_" ]]; then b_ok "CPU now: ${mv_} mV"; else b_off "live mV: root only"; fi
    return 0
}
badge_cpu_mitigations() {
    local configured boot
    configured=$(cpu_mitigations_configured_state)
    boot=$(cpu_mitigations_boot_state)
    case "$configured:$boot" in
        enabled:enabled) b_ok "enabled" ;;
        disabled:disabled) b_mid "disabled" ;;
        enabled:disabled|disabled:enabled) b_mid "reboot needed" ;;
        *) b_mid "$configured" ;;
    esac
}

badge_core_unlock() {
    local mode="${1:-$(core_unlock_mode)}"
    case "$mode" in
        systemd)  b_ok "standard boot method enabled" ;;
        efi)      b_ok "EFI pre-boot method enabled" ;;
        partial)  b_mid "EFI cleanup needed" ;;
        conflict) b_mid "boot method conflict" ;;
        none)
            if [[ -x "$CORE_UNLOCK_BIN" ]]; then b_off "automatic unlock off - helper kept"
            else b_off "not installed"; fi
            ;;
    esac
}

badge_core_unlock_files() {
    if [[ -x "$CORE_UNLOCK_BIN" ]]; then b_mid "helper installed"
    elif [[ "${1:-none}" != none ]]; then b_mid "artifacts remain"
    else b_off "nothing installed"; fi
}

# ============================== ACPI fix ==================================
bc250_platform_present() {
    local path vendor device
    for path in "$PCI_DEVICES_ROOT"/*; do
        [[ -r "$path/vendor" && -r "$path/device" ]] || continue
        IFS= read -r vendor < "$path/vendor" || continue
        IFS= read -r device < "$path/device" || continue
        [[ "${vendor,,}" == 0x1002 && "${device,,}" == 0x13fe ]] && return 0
    done
    return 1
}

acpi_source_digest() {
    local table_dir="${1:-$ACPI_TABLE_DIR}" cst pst
    [[ -f "$table_dir/SSDT-CST.dsl" && ! -L "$table_dir/SSDT-CST.dsl" \
        && -f "$table_dir/SSDT-PST.dsl" && ! -L "$table_dir/SSDT-PST.dsl" ]] \
        || return 1
    cst=$(sha256sum "$table_dir/SSDT-CST.dsl" | awk '{print $1}')
    pst=$(sha256sum "$table_dir/SSDT-PST.dsl" | awk '{print $1}')
    printf '%s\n%s\n' "$cst" "$pst" | sha256sum | awk '{print $1}'
}

acpi_lifecycle_lock() {
    grub_config_lock || return 1
    command -v flock >/dev/null 2>&1 \
        || { warn "flock is required for safe ACPI lifecycle changes."; grub_config_unlock; return 1; }
    exec 7> "$ACPI_LIFECYCLE_LOCK" \
        || { warn "Could not open $ACPI_LIFECYCLE_LOCK"; grub_config_unlock; return 1; }
    flock 7 \
        || { exec 7>&-; warn "Could not lock $ACPI_LIFECYCLE_LOCK"; grub_config_unlock; return 1; }
}

acpi_lifecycle_unlock() {
    flock -u 7 2>/dev/null || true
    exec 7>&-
    grub_config_unlock
}

grub_config_lock() {
    [[ $GRUB_LOCK_HELD -eq 0 ]] || return 0
    command -v flock >/dev/null 2>&1 \
        || { warn "flock is required for safe GRUB changes."; return 1; }
    exec 6> "$GRUB_CONFIG_LOCK" \
        || { warn "Could not open $GRUB_CONFIG_LOCK"; return 1; }
    flock 6 \
        || { exec 6>&-; warn "Could not lock $GRUB_CONFIG_LOCK"; return 1; }
    GRUB_LOCK_HELD=1
}

grub_config_unlock() {
    [[ $GRUB_LOCK_HELD -eq 1 ]] || return 0
    flock -u 6 2>/dev/null || true
    exec 6>&-
    GRUB_LOCK_HELD=0
}

acpi_payload_current() {
    local installed="" source_expected="" archive_expected="" extra=""
    local source_actual archive_actual
    [[ -f "$CPIO_MASTER" && ! -L "$CPIO_MASTER" \
        && -f "$ACPI_PAYLOAD_MARKER" && ! -L "$ACPI_PAYLOAD_MARKER" ]] \
        || return 1
    read -r installed source_expected archive_expected extra \
        < "$ACPI_PAYLOAD_MARKER" || return 1
    [[ "$installed" == "$ACPI_PAYLOAD_VERSION" && -z "$extra" \
        && "$source_expected" =~ ^[0-9a-f]{64}$ \
        && "$archive_expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    source_actual=$(acpi_source_digest) || return 1
    archive_actual=$(sha256sum "$CPIO_MASTER" | awk '{print $1}')
    [[ "$source_actual" == "$source_expected" \
        && "$archive_actual" == "$archive_expected" ]]
}

ensure_acpi_build_tools() {
    local packages=()
    command -v cpio >/dev/null 2>&1 \
        || command -v python3 >/dev/null 2>&1 \
        || packages+=(cpio)
    command -v iasl >/dev/null 2>&1 || packages+=(acpica)
    [[ ${#packages[@]} -gt 0 ]] || return 0

    unlock_rootfs
    prepare_pacman_keyring
    pacman -Sy --noconfirm --needed "${packages[@]}" \
        || die "ACPI build tools unavailable and pacman install failed."
}

write_newc_archive() {
    local root="$1" output="$2"
    if command -v cpio >/dev/null 2>&1; then
        if ( cd "$root" && find kernel -print | cpio -o -H newc > "$output" ); then
            return 0
        fi
        warn "System cpio failed; retrying with the Python fallback."
        rm -f "$output"
    fi
    command -v python3 >/dev/null 2>&1 \
        || die "Neither cpio nor python3 is available to build the ACPI archive."
    python3 - "$root" "$output" <<'PY'
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = Path(sys.argv[2])
paths = sorted(root.joinpath("kernel").rglob("*"), key=lambda path: path.as_posix())
paths.insert(0, root / "kernel")

with output.open("wb") as stream:
    def write_entry(name, mode, data, inode):
        fields = (
            inode, mode, 0, 0, 1, 0, len(data),
            0, 0, 0, 0, len(name) + 1, 0,
        )
        header = "070701" + "".join(f"{value:08x}" for value in fields)
        stream.write(header.encode("ascii"))
        stream.write(name.encode("ascii") + b"\0")
        stream.write(b"\0" * (-stream.tell() % 4))
        stream.write(data)
        stream.write(b"\0" * (-stream.tell() % 4))

    for inode, path in enumerate(paths, 1):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise SystemExit(f"unsafe ACPI archive input: {path}")
        name = path.relative_to(root).as_posix()
        mode = (stat.S_IFDIR | 0o755) if path.is_dir() else (stat.S_IFREG | 0o644)
        write_entry(name, mode, b"" if path.is_dir() else path.read_bytes(), inode)
    write_entry("TRAILER!!!", 0, b"", len(paths) + 1)
    stream.write(b"\0" * (-stream.tell() % 512))
PY
}

build_acpi_payload() {
    local work archive_tmp marker_tmp table output source_hash archive_hash
    for table in SSDT-CST.dsl SSDT-PST.dsl; do
        [[ -f "$ACPI_TABLE_DIR/$table" && ! -L "$ACPI_TABLE_DIR/$table" ]] \
            || die "Universal ACPI table source missing or unsafe: $ACPI_TABLE_DIR/$table"
    done

    ensure_acpi_build_tools
    work=$(mktemp -d /tmp/bc250-acpi.XXXXXX)
    TEMP_DIRS+=("$work")
    mkdir -p "$work/kernel/firmware/acpi"
    install -m 0644 "$ACPI_TABLE_DIR/SSDT-CST.dsl" "$work/SSDT-CST.dsl"
    install -m 0644 "$ACPI_TABLE_DIR/SSDT-PST.dsl" "$work/SSDT-PST.dsl"
    source_hash=$(acpi_source_digest "$work") \
        || die "Could not hash staged ACPI table sources."

    log "Compiling universal 6/8-core ACPI tables..."
    for table in SSDT-CST SSDT-PST; do
        output="$work/kernel/firmware/acpi/$table"
        iasl -vs -we -p "$output" "$work/$table.dsl"
        [[ -s "$output.aml" ]] || die "iasl produced no $table.aml"
    done

    write_newc_archive "$work" "$work/acpi_override.cpio"
    [[ -s "$work/acpi_override.cpio" ]] || die "ACPI override archive is empty."
    archive_hash=$(sha256sum "$work/acpi_override.cpio" | awk '{print $1}')

    archive_tmp="$ACPI_DIR/.acpi_override.cpio.$$"
    marker_tmp="$ACPI_DIR/.payload-version.$$"
    TEMP_FILES+=("$archive_tmp" "$marker_tmp")
    install -o root -g root -m 0644 \
        "$work/kernel/firmware/acpi/SSDT-CST.aml" "$ACPI_DIR/SSDT-CST.aml"
    install -o root -g root -m 0644 \
        "$work/kernel/firmware/acpi/SSDT-PST.aml" "$ACPI_DIR/SSDT-PST.aml"
    install -o root -g root -m 0644 "$work/acpi_override.cpio" "$archive_tmp"
    mv -f "$archive_tmp" "$CPIO_MASTER"
    printf '%s %s %s\n' \
        "$ACPI_PAYLOAD_VERSION" "$source_hash" "$archive_hash" > "$marker_tmp"
    chmod 0644 "$marker_tmp"
    mv -f "$marker_tmp" "$ACPI_PAYLOAD_MARKER"
    log "Master cpio -> $CPIO_MASTER ($ACPI_PAYLOAD_VERSION)"
}

install_acpi_boot_archive() {
    local boot_tmp="${CPIO_BOOT}.tmp.$$"
    TEMP_FILES+=("$boot_tmp")
    install -o root -g root -m 0644 "$CPIO_MASTER" "$boot_tmp"
    sync "$boot_tmp"
    mv -f "$boot_tmp" "$CPIO_BOOT"
    sync "${CPIO_BOOT%/*}"
}

cmd_acpi() {
    require_root
    bc250_platform_present \
        || die "BC-250 GPU PCI ID 1002:13fe was not detected; refusing the ACPI override."
    acpi_lifecycle_lock || return $?
    install_update_persistence
    migrate_legacy_data
    mkdir -p "$ACPI_DIR"

    # --- compile SSDTs and build the persistent override cpio -------------
    if ! acpi_payload_current; then
        build_acpi_payload
    else
        log "Master cpio is current at $CPIO_MASTER ($ACPI_PAYLOAD_VERSION)"
    fi

    # --- install into /boot and wire up GRUB ------------------------------
    unlock_rootfs
    install_acpi_boot_archive
    log "Installed -> $CPIO_BOOT"

    # The dedicated drop-in survives updates without retaining Valve's full
    # release-specific /etc/default/grub file.
    mkdir -p "${GRUB_ACPI_DEFAULT%/*}"
    printf '%s\n' 'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' \
        > "$GRUB_ACPI_DEFAULT"
    log "GRUB_EARLY_INITRD_LINUX_CUSTOM set in $GRUB_ACPI_DEFAULT"

    log "Regenerating GRUB config..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    else
        mkdir -p "${GRUB_CFG%/*}"
        grub-mkconfig -o "$GRUB_CFG"
    fi

    if grep -q 'acpi_override.cpio' "$GRUB_CFG" 2>/dev/null; then
        log "$GRUB_CFG references the override -- good."
    else
        warn "$GRUB_CFG does NOT reference acpi_override.cpio."
        warn "Your SteamOS grub build may ignore GRUB_EARLY_INITRD_LINUX_CUSTOM."
        warn "Fallback: manually prepend it on the initrd line(s) in $GRUB_CFG:"
        warn "    initrd /acpi_override.cpio /initramfs-...img"
        warn "(the self-heal service will retry and report a failure if it cannot repair this)"
    fi

    # --- self-heal service: SteamOS updates wipe /boot --------------------
    log "Installing boot-time self-heal service..."
    cat > "$HEAL_HELPER" << EOF
#!/usr/bin/env bash
set -euo pipefail
ROOTFS_WAS_READONLY=0
BOOT_TMP=""
READY_MARKER="$ACPI_READY"
GRUB_CFG="$GRUB_CFG"
GRUB_ACPI_DEFAULT="$GRUB_ACPI_DEFAULT"
GRUB_CONFIG_LOCK="$GRUB_CONFIG_LOCK"
PAYLOAD_MARKER="$ACPI_PAYLOAD_MARKER"
MASTER_CPIO="$CPIO_MASTER"
LIFECYCLE_LOCK="$ACPI_LIFECYCLE_LOCK"
current_os_build() {
    if [[ -r /etc/os-release ]]; then
        ( . /etc/os-release; printf '%s\n' "\${BUILD_ID:-\${VERSION_ID:-unknown}}" )
    else
        printf '%s\n' unknown
    fi
}
relock() {
    local rc=\$?
    trap - EXIT
    [[ -z "\$BOOT_TMP" ]] || rm -f "\$BOOT_TMP"
    if [[ \$ROOTFS_WAS_READONLY -eq 1 ]]; then
        steamos-readonly enable || rc=1
    fi
    exit "\$rc"
}
trap relock EXIT
if [[ "\${BC250_ACPI_LOCK_HELD:-0}" != 1 ]]; then
    command -v flock >/dev/null 2>&1 \
        || { echo "bc250: flock is required for ACPI self-healing" | systemd-cat -p err; exit 1; }
    exec 6> "\$GRUB_CONFIG_LOCK"
    flock 6
    exec 7> "\$LIFECYCLE_LOCK"
    flock 7
fi
rm -f "\$READY_MARKER"

read -r _ _ expected_archive_hash extra < "\$PAYLOAD_MARKER" \
    || { echo "bc250: ACPI payload marker is unreadable" | systemd-cat -p err; exit 1; }
actual_archive_hash=\$(sha256sum "\$MASTER_CPIO" | awk '{print \$1}')
if [[ -n "\$extra" || ! "\$expected_archive_hash" =~ ^[0-9a-f]{64}$ \
   || "\$actual_archive_hash" != "\$expected_archive_hash" ]]; then
    echo "bc250: persistent ACPI payload failed checksum validation" | systemd-cat -p err
    exit 1
fi

if [[ ! -f $CPIO_BOOT ]] || ! cmp -s "$CPIO_MASTER" "$CPIO_BOOT" \
   || ! grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' "\$GRUB_ACPI_DEFAULT" 2>/dev/null \
   || ! grep -q acpi_override.cpio "\$GRUB_CFG" 2>/dev/null; then
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        ROOTFS_WAS_READONLY=1
    fi
    BOOT_TMP="${CPIO_BOOT}.tmp.\$\$"
    install -o root -g root -m 0644 "\$MASTER_CPIO" "\$BOOT_TMP"
    sync "\$BOOT_TMP"
    mv -f "\$BOOT_TMP" "$CPIO_BOOT"
    BOOT_TMP=""
    sync "${CPIO_BOOT%/*}"
    mkdir -p "\${GRUB_ACPI_DEFAULT%/*}"
    printf '%s\n' 'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' \
        > "\$GRUB_ACPI_DEFAULT"
    if command -v update-grub >/dev/null; then
        update-grub
    else
        mkdir -p "\${GRUB_CFG%/*}"
        grub-mkconfig -o "\$GRUB_CFG"
    fi
    if grep -q acpi_override.cpio "\$GRUB_CFG" 2>/dev/null; then
        echo "bc250: ACPI override restored after OS update; REBOOT to re-activate C/P-states" | systemd-cat -p warning
    else
        echo "bc250: \$GRUB_CFG still lacks acpi_override.cpio after regen -- add the initrd line manually (see bc250-power.sh acpi output)" | systemd-cat -p err
        exit 1
    fi
fi
if [[ -f $CPIO_BOOT ]] && cmp -s "$CPIO_MASTER" "$CPIO_BOOT" \
   && grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' "\$GRUB_ACPI_DEFAULT" 2>/dev/null \
   && grep -q acpi_override.cpio "\$GRUB_CFG" 2>/dev/null; then
    current_os_build > "\$READY_MARKER"
else
    echo "bc250: ACPI boot configuration could not be validated" | systemd-cat -p err
    exit 1
fi
EOF
    chmod 755 "$HEAL_HELPER"
    rm -f /etc/bc250-acpi-heal.sh

    cat > "$HEAL_UNIT" << EOF
[Unit]
Description=BC-250 ACPI override self-heal (restore after SteamOS updates)
Requires=$RECOVERY_SVC
Wants=steamos-post-update.service
After=$RECOVERY_SVC local-fs.target steamos-post-update.service
RequiresMountsFor=$ROOT_DATA_DIR

[Service]
Type=oneshot
ExecStart=$HEAL_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # --- cpufreq governor setter (schedutil once P-states exist) ----------
    cat > "$CPUFREQ_UNIT" << 'EOF'
[Unit]
Description=BC-250 set schedutil cpufreq governor (needs ACPI P-states)

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then \
    echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null; \
  else \
    echo "bc250: cpufreq not present -- ACPI override not active this boot" | systemd-cat -p warning; \
  fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bc250-acpi-heal.service bc250-cpufreq.service
    BC250_ACPI_LOCK_HELD=1 "$HEAL_HELPER"
    cleanup_legacy_data
    relock_rootfs
    acpi_lifecycle_unlock

    log "ACPI fix installed. REBOOT required, then verify:"
    log "  ls /sys/devices/system/cpu/cpu0/cpuidle/          # state0..state3"
    log "  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies"
    log "  (expect 800 MHz .. 3200 MHz steps)"
}

# ============================ GPU governor ================================
# Single source for the tuned voltage curve: written on governor install and
# restored by 'gpu-volt reset'.
default_safe_points() {
    cat << 'EOF'
# Voltage curve: 300 MHz floor with a flat 1000 mV ceiling (2026 community
# finding: most boards hold it; bump the TOP point +15-25 mV only if unstable)
[[safe-points]]
frequency = 300
voltage = 700

[[safe-points]]
frequency = 1000
voltage = 800

[[safe-points]]
frequency = 1500
voltage = 900

[[safe-points]]
frequency = 2000
voltage = 1000

[[safe-points]]
frequency = 2150
voltage = 1000
EOF
}

check_conflicts() {
    local s
    for s in cyan-skillfish-governor.service cyan-skillfish-governor-tt.service \
             oberon-governor.service; do
        if systemctl is-active "$s" >/dev/null 2>&1 \
            || systemctl is-enabled "$s" >/dev/null 2>&1; then
            warn "Conflicting governor $s installed -- disabling (two controllers fight)."
            systemctl disable --now "$s"
        fi
    done
}

write_governor_unit() {
    cat > "$GOV_UNIT" << EOF
[Unit]
Description=Cyan Skillfish GPU governor (SMU) -- BC-250
Requires=$RECOVERY_SVC
After=$RECOVERY_SVC bc250-cu-live-manager.service
Conflicts=cyan-skillfish-governor.service cyan-skillfish-governor-tt.service oberon-governor.service
RequiresMountsFor=$ROOT_DATA_DIR

[Service]
Type=simple
ExecStart=$GOV_BIN $GOV_CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

cmd_governor() {
    require_root
    migrate_legacy_data
    recover_update_settings
    mkdir -p "$BIN_DIR" "$GOV_CONF_DIR"
    check_conflicts

    log "Resolving latest cyan-skillfish-governor-smu release..."
    local url api_json rel_tag
    api_json=$(curl -fsSL "$GOV_API") || die "GitHub API request failed (network?)."
    # Pin any raw-file fallback fetches to the SAME release as the binary --
    # branch HEAD can have renamed D-Bus interfaces vs the release binary.
    rel_tag=$(grep -oP '"tag_name":\s*"\K[^"]+' <<< "$api_json" | head -1 || true)
    [[ -n "$rel_tag" ]] && GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/$rel_tag"
    log "Release: ${rel_tag:-unknown} (raw fallbacks pinned to it)"
    # NB: '|| true' guards are load-bearing -- under set -e/pipefail a
    # non-matching grep would otherwise kill the script silently.
    url=$(grep -oP '"browser_download_url":\s*"\K[^"]*smu[^"]*x86_64[^"]*\.tar\.gz' \
              <<< "$api_json" | head -1 || true)
    [[ -n "$url" ]] || url=$(grep -oP '"browser_download_url":\s*"\K[^"]*\.tar\.gz' \
              <<< "$api_json" | head -1 || true)
    [[ -n "$url" ]] || die "No .tar.gz asset found in the latest release. Assets were:
$(grep -oP '"browser_download_url":\s*"\K[^"]*' <<< "$api_json" || echo '  (none / API rate-limited)')"
    log "  $url"

    local work
    work=$(mktemp -d /tmp/csg-install.XXXXXX)
    TEMP_DIRS+=("$work")
    curl -fL -o "$work/csg.tar.gz" "$url"
    tar -xf "$work/csg.tar.gz" -C "$work"

    local bin perf
    bin=$(find "$work" -type f -name 'cyan-skillfish-governor-smu' \
              ! -name '*.service' ! -name '*.spec' | head -1 || true)
    [[ -n "$bin" ]] || die "No prebuilt binary in archive. Contents:
$(find "$work" -type f | head -20)"
    install -m 755 "$bin" "$GOV_BIN";  log "Binary -> $GOV_BIN"

    # perf-mode helper + D-Bus policy: not always in the tarball -- fall
    # back to fetching them straight from the smu branch of the repo.
    perf=$(find "$work" -type f -name 'cyan-skillfish-performance-mode*' | head -1 || true)
    if [[ -n "$perf" ]]; then
        install -m 755 "$perf" "$PERF_BIN"
    else
        log "Helper not in tarball; fetching from repo..."
        curl -fL -o "$PERF_BIN" "$GOV_RAW/scripts/cyan-skillfish-performance-mode" \
            || warn "Could not fetch perf-mode helper; busctl SetRange works as a substitute."
        if [[ -s "$PERF_BIN" ]]; then chmod 755 "$PERF_BIN"
        else rm -f "$PERF_BIN"; fi
    fi
    [[ -x "$PERF_BIN" ]] && log "Perf-mode helper -> $PERF_BIN"

    # D-Bus policy: upstream's shipped policy file is STALE vs its own binary
    # (file grants com.cyan.SkillFishGovernor; the v0.4.x binary requests
    # com.cyanskillfish.Governor -- verified via strings on the binary).
    # Write our own root-only policy granting both names. User-facing controls
    # go through sudo or the polkit-authorized desktop service.
    mkdir -p /etc/dbus-1/system.d
    cat > "$DBUS_POLICY" << 'EOF'
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="com.cyan.SkillFishGovernor"/>
    <allow own="com.cyanskillfish.Governor"/>
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
  </policy>
</busconfig>
EOF
    log "D-Bus policy (dual-name) -> $DBUS_POLICY"
    # dbus-broker only reliably reloads files in dirs it saw at launch; try a
    # reload, and warn that a reboot may be needed if the dir is brand new.
    busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig \
        2>/dev/null || warn "D-Bus policy reload failed; a reboot will activate it."

    if [[ -f "$GOV_CONF" ]]; then
        warn "Existing config kept at $GOV_CONF"
    else
        log "Writing tuned config (38/40 CU, docs-schema) -> $GOV_CONF"
        cat > "$GOV_CONF" << 'EOF'
# BC-250 SMU governor -- tuned for the 38/40 CU unlock on stock-class cooling.
# Full community voltage curve; operating range capped at 1500 MHz (the
# unlock sweet spot). Raise live without restart when cooling allows:
#   cyan-skillfish-performance-mode --range 0 2000
# Thermal throttling applies regardless of range.

[timing.intervals]
sample = 500
adjust = 200_000

[gpu-usage]
fix-metrics = true          # also fixes MangoHud/radeontop 655% bug
method = "busy-flag"
flush-every = 10

[gpu]
set-method = "smu"          # firmware calls; no kernel patch

[dbus]
enabled = true

[timing.ramp-rates]
normal = 1
burst = 50

[timing]
burst-samples = 60
down-events = 5

[frequency-thresholds]
adjust = 10

[load-target]
upper = 0.80
lower = 0.65

[frequency-range]
max = 1500                  # sustained-safe with 38 CUs routed

[temperature]
throttling = 85
throttling_recovery = 75

EOF
        default_safe_points >> "$GOV_CONF"
    fi

    log "Writing systemd unit (persistent paths) -> $GOV_UNIT"
    write_governor_unit
    systemctl daemon-reload

    install_freq_persistence force
    install_update_persistence

    log "Test-starting (not yet enabled at boot)..."
    systemctl restart "$GOV_SVC"; sleep 2
    systemctl is-active "$GOV_SVC" >/dev/null || {
        journalctl -u "$GOV_SVC" -n 30 --no-pager
        die "Governor failed to start -- log above."
    }
    systemctl restart "$RESTORE_SVC" \
        || warn "Governor started, but the saved frequency range was not restored."
    cleanup_legacy_data
    log "Running. Load the GPU for a few minutes; watch clocks and temps:"
    log "  watch -n1 'cat /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null; sensors | grep -E \"edge|PPT\"'"
    log "Then lock it in: sudo $0 enable"
}

# ================================ misc ====================================
# Live GPU frequency control. Prefers the perf-mode helper; falls back to
# direct busctl using the bus name the v0.4.x binary ACTUALLY registers
# (com.cyanskillfish.Governor -- not the documented com.cyan.SkillFishGovernor).
BUS_NAME="com.cyanskillfish.Governor"
BUS_PATH="/com/cyanskillfish/Governor"
BUS_IFACE="com.cyanskillfish.Governor.PerformanceMode"

gov_dbus() { busctl --system call "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" "$@"; }

# --- freq persistence: save the last applied setting and reapply at boot ---
# The governor's D-Bus state is runtime-only; a restart/reboot reverts to
# config.toml. We record the last 'freq' command in a state file and a
# oneshot service replays it once the governor's bus name is up.
install_freq_persistence() {
    local governor_enabled=0 restore_enabled=0
    [[ "$(systemctl is-enabled "$GOV_SVC" 2>/dev/null || true)" == enabled ]] \
        && governor_enabled=1
    [[ "$(systemctl is-enabled "$RESTORE_SVC" 2>/dev/null || true)" == enabled ]] \
        && restore_enabled=1
    # fast path for everyday 'freq' calls; 'force' (used by installs)
    # rewrites the files so script updates propagate
    if [[ "${1:-}" != force && -x "$RESTORE_BIN" && -f "$RESTORE_UNIT" ]] \
       && [[ $governor_enabled -eq $restore_enabled ]]; then
        return 0
    fi

    mkdir -p "$BIN_DIR" "$ROOT_DATA_DIR/governor"
    cat > "$RESTORE_BIN" << EOF
#!/usr/bin/env bash
# bc250: reapply the saved GPU freq setting after the governor starts.
# Written by bc250-power.sh -- do not edit; it gets regenerated.
set -u
STATE="$FREQ_STATE"
PERF="$PERF_BIN"
BUS_NAME="$BUS_NAME"; BUS_PATH="$BUS_PATH"; BUS_IFACE="$BUS_IFACE"
[[ -f "\$STATE" ]] || exit 0
MODE= A= B=
while IFS='=' read -r key value; do
    case "\$key" in
        MODE) MODE="\$value" ;;
        A) A="\$value" ;;
        B) B="\$value" ;;
    esac
done < "\$STATE"
case "\$MODE" in
    max) A= B= ;;
    pin) [[ "\$A" =~ ^[0-9]+$ ]] || exit 1; B= ;;
    range) [[ "\$A" =~ ^[0-9]+$ && "\$B" =~ ^[0-9]+$ ]] || exit 1 ;;
    *) exit 1 ;;
esac
# governor registers its bus name shortly after start; give it up to 30 s
for _ in \$(seq 1 30); do
    busctl --system status "\$BUS_NAME" >/dev/null 2>&1 && break
    sleep 1
done
if ! busctl --system status "\$BUS_NAME" >/dev/null 2>&1; then
    echo "bc250: governor bus name never appeared -- GPU freq state NOT restored" \
        | systemd-cat -p warning
    exit 1
fi
if [[ -x "\$PERF" ]]; then
    case "\$MODE" in
        max)   "\$PERF" --on ;;
        pin)   "\$PERF" --fixed-frequency "\$A" ;;
        range) "\$PERF" --range "\$A" "\$B" ;;
        *)     exit 0 ;;
    esac
else
    case "\$MODE" in
        max)   busctl --system set-property "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" Enabled b true ;;
        pin)   busctl --system call "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" SetFixedFrequency u "\$A" ;;
        range) busctl --system call "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" SetRange uu "\$A" "\$B" ;;
        *)     exit 0 ;;
    esac
fi && echo "bc250: restored GPU freq setting (\$MODE \${A:-} \${B:-})" | systemd-cat -p info
EOF
    chmod 755 "$RESTORE_BIN"

    cat > "$RESTORE_UNIT" << EOF
[Unit]
Description=BC-250 restore saved GPU freq setting (survives reboots)
Requires=$RECOVERY_SVC $GOV_SVC
After=$RECOVERY_SVC $GOV_SVC
PartOf=$GOV_SVC
RequiresMountsFor=$ROOT_DATA_DIR

[Service]
Type=oneshot
ExecStart=$RESTORE_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if [[ $governor_enabled -eq 1 ]]; then
        systemctl enable "$RESTORE_SVC" >/dev/null 2>&1
        log "Boot-time freq restore installed and enabled ($RESTORE_SVC)."
    else
        systemctl disable "$RESTORE_SVC" >/dev/null 2>&1 || true
        log "Boot-time freq restore installed; run '$0 enable' after load testing."
    fi
}

save_freq_state() {           # save_freq_state <max|pin|range> [a] [b]
    install_freq_persistence
    install -d -o root -g root -m 0755 "$(dirname "$FREQ_STATE")"
    printf 'MODE=%s\nA=%s\nB=%s\n' "$1" "${2:-}" "${3:-}" > "$FREQ_STATE"
    chown root:root "$FREQ_STATE"
    chmod 0644 "$FREQ_STATE"
    if [[ "$(systemctl is-enabled "$GOV_SVC" 2>/dev/null || true)" == enabled ]]; then
        log "Saved -- reapplied automatically at boot ('$0 freq auto' to clear)."
    else
        log "Saved -- run '$0 enable' after load testing to apply it at boot."
    fi
}

clear_freq_state() {
    if [[ -f "$FREQ_STATE" ]]; then
        rm -f "$FREQ_STATE"
        log "Saved freq state cleared -- boots return to config defaults."
    fi
}

gpu_control_lock() {
    local parent owner permissions descriptor_device descriptor_inode path_device path_inode
    [[ $GPU_CONTROL_LOCK_HELD -eq 0 ]] || return 0
    command -v flock >/dev/null 2>&1 \
        || { warn "flock is required for safe GPU control changes."; return 1; }
    parent="${GPU_CONTROL_LOCK%/*}"
    [[ "$GPU_CONTROL_LOCK" == /* && -n "$parent" && "$parent" != "$GPU_CONTROL_LOCK" ]] \
        || { warn "GPU control lock path is invalid: $GPU_CONTROL_LOCK"; return 1; }
    install -d -o "$(id -u)" -g "$(id -g)" -m 0755 "$parent" \
        || { warn "Could not prepare GPU control lock directory: $parent"; return 1; }
    [[ -d "$parent" && ! -L "$parent" ]] \
        || { warn "GPU control lock directory is unsafe: $parent"; return 1; }
    owner=$(stat -c %u "$parent")
    permissions=$(stat -c %a "$parent")
    [[ "$owner" == "$(id -u)" ]] && (( (8#$permissions & 8#022) == 0 )) \
        || { warn "GPU control lock directory is not trusted: $parent"; return 1; }
    if [[ ! -e "$GPU_CONTROL_LOCK" ]]; then
        ( umask 177; : > "$GPU_CONTROL_LOCK" ) \
            || { warn "Could not create GPU control lock: $GPU_CONTROL_LOCK"; return 1; }
    fi
    [[ -f "$GPU_CONTROL_LOCK" && ! -L "$GPU_CONTROL_LOCK" ]] \
        || { warn "GPU control lock file is unsafe: $GPU_CONTROL_LOCK"; return 1; }
    owner=$(stat -c %u "$GPU_CONTROL_LOCK")
    permissions=$(stat -c %a "$GPU_CONTROL_LOCK")
    [[ "$owner" == "$(id -u)" ]] && (( (8#$permissions & 8#022) == 0 )) \
        || { warn "GPU control lock file is not trusted: $GPU_CONTROL_LOCK"; return 1; }
    exec 5<> "$GPU_CONTROL_LOCK" \
        || { warn "Could not open GPU control lock: $GPU_CONTROL_LOCK"; return 1; }
    read -r descriptor_device descriptor_inode < <(stat -Lc '%d %i' /proc/self/fd/5)
    read -r path_device path_inode < <(stat -Lc '%d %i' "$GPU_CONTROL_LOCK")
    if [[ "$descriptor_device:$descriptor_inode" != "$path_device:$path_inode" ]]; then
        exec 5>&-
        warn "GPU control lock changed while opening: $GPU_CONTROL_LOCK"
        return 1
    fi
    if ! flock -w 10 5; then
        exec 5>&-
        warn "Another BC-250 control operation is still running."
        return 1
    fi
    GPU_CONTROL_LOCK_HELD=1
}

gpu_control_unlock() {
    [[ $GPU_CONTROL_LOCK_HELD -eq 1 ]] || return 0
    flock -u 5 2>/dev/null || true
    exec 5>&-
    GPU_CONTROL_LOCK_HELD=0
}

validate_gpu_frequency_request() {
    local first="${1:-}" second="${2:-}"
    case "$first" in
        ""|status|auto|off|max|on)
            [[ -z "$second" ]] || die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]"
            ;;
        *)
            [[ "$first" =~ ^[0-9]+$ ]] \
                || die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]"
            if [[ -n "$second" ]]; then
                [[ "$second" =~ ^[0-9]+$ ]] \
                    || die "GPU frequencies must be whole numbers."
                (( second >= GPU_FREQ_MIN && second <= GPU_FREQ_MAX )) \
                    || die "Maximum frequency must be ${GPU_FREQ_MIN}-${GPU_FREQ_MAX} MHz."
                (( first == 0 || (first >= GPU_FREQ_MIN && first <= GPU_FREQ_MAX) )) \
                    || die "Minimum frequency must be 0 (no floor) or ${GPU_FREQ_MIN}-${GPU_FREQ_MAX} MHz."
                (( first == 0 || first <= second )) \
                    || die "Minimum frequency exceeds maximum frequency."
            else
                (( first >= GPU_FREQ_MIN && first <= GPU_FREQ_MAX )) \
                    || die "Pinned frequency must be ${GPU_FREQ_MIN}-${GPU_FREQ_MAX} MHz."
            fi
            ;;
    esac
}

cmd_freq() {
    require_root
    gpu_control_lock || return $?
    systemctl is-active "$GOV_SVC" >/dev/null 2>&1 \
        || die "Governor not running -- freq control goes through it."

    local a="${1:-}" b="${2:-}"
    validate_gpu_frequency_request "$a" "$b"
    # Helper handles everything including status; use it when available.
    if [[ -x "$PERF_BIN" ]]; then
        case "$a" in
            "")            "$PERF_BIN" --status ;;
            status)        "$PERF_BIN" --status ;;
            auto|off)      "$PERF_BIN" --off && clear_freq_state ;;
            max|on)        "$PERF_BIN" --on  && save_freq_state max ;;
            [0-9]*)
                if [[ -n "$b" ]]; then "$PERF_BIN" --range "$a" "$b" && save_freq_state range "$a" "$b"
                else                   "$PERF_BIN" --fixed-frequency "$a" && save_freq_state pin "$a"; fi ;;
            *) die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]" ;;
        esac
        gpu_control_unlock
        return
    fi

    # busctl fallback (helper missing)
    case "$a" in
        ""|status)
            busctl --system get-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" Enabled \
                || warn "Bus name absent -- D-Bus policy not active? (reboot after policy install)" ;;
        auto|off)  busctl --system set-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" Enabled b false \
                       && log "Adaptive scaling restored (config defaults apply)." \
                       && clear_freq_state ;;
        max|on)    busctl --system set-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" Enabled b true \
                       && log "Performance mode ON (max frequency, no idle downscale)." \
                       && save_freq_state max ;;
        [0-9]*)
            if [[ -n "$b" ]]; then
                gov_dbus SetRange uu "$a" "$b" && log "Range set: ${a}-${b} MHz (0 = no limit)." \
                    && save_freq_state range "$a" "$b"
            else
                gov_dbus SetFixedFrequency u "$a" && log "Pinned at $a MHz ('$0 freq auto' when done)." \
                    && save_freq_state pin "$a"
            fi ;;
        *) die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]" ;;
    esac
    gpu_control_unlock
}

# ========================= GPU voltage control ============================
# GPU voltage belongs to the governor's safe-points curve (it applies mV per
# frequency continuously); forcing vid directly over SMU would fight it.
# These commands edit the curve in config.toml, restart the governor, and
# reapply the saved freq setting (a restart otherwise drops runtime state).
GPU_FREQ_MIN=300
GPU_FREQ_MAX=2150
VOLT_MIN=700    # below: artifact/crash territory even at low clocks
VOLT_MAX=1050   # above the community flat-1000 ceiling + small margin

restart_governor_reapply() {
    systemctl restart "$GOV_SVC"
    log "Governor restarted with the updated configuration."
    if [[ -f "$FREQ_STATE" && -x "$RESTORE_BIN" ]]; then
        if "$RESTORE_BIN"; then log "Saved freq setting reapplied."
        else warn "Could not reapply saved freq setting -- check 'freq status'."; fi
    fi
}

volt_curve_helper() {
    local mode="$1"
    shift
    command -v python3 >/dev/null 2>&1 \
        || die "python3 is required for safe voltage-curve updates."
    python3 -c 'import tomllib' >/dev/null 2>&1 \
        || die "Python 3.11 or newer is required for safe voltage-curve updates."
    python3 - "$mode" "$GOV_CONF" "$FREQ_STATE" "$RESTORE_BIN" "$GOV_SVC" \
        "$GPU_CONTROL_LOCK" "$SYSTEMCTL_BIN" "$GPU_FREQ_MIN" "$GPU_FREQ_MAX" \
        "$VOLT_MIN" "$VOLT_MAX" "$@" <<'PY'
import fcntl
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
from pathlib import Path


class CurveError(Exception):
    pass


class AtomicWriteError(CurveError):
    def __init__(self, message, replacement_done=False):
        super().__init__(message)
        self.replacement_done = replacement_done


class TransitionalServiceError(CurveError):
    pass


mode, config_arg, state_arg, restore_arg, service, lock_arg, systemctl = sys.argv[1:8]
frequency_min, frequency_max, voltage_min, voltage_max = map(int, sys.argv[8:12])
arguments = sys.argv[12:]
config_path = Path(config_arg)
state_path = Path(state_arg)
restore_path = Path(restore_arg)
lock_path = Path(lock_arg)


def read_regular(path, trusted=False):
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
            raise CurveError(f"Refusing unsafe file: {path}")
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise CurveError(f"File changed while opening: {path}")
            if trusted and (
                opened.st_nlink != 1
                or opened.st_uid != os.geteuid()
                or opened.st_mode & 0o022
            ):
                raise CurveError(f"File is not trusted: {path}")
            content = stream.read(1024 * 1024 + 1)
        if len(content) > 1024 * 1024:
            raise CurveError(f"File is unexpectedly large: {path}")
        return content.decode("utf-8"), before
    except CurveError:
        raise
    except (OSError, UnicodeError) as error:
        raise CurveError(f"Could not read {path}: {error}") from error


def parse_config(content):
    try:
        data = tomllib.loads(content)
    except (TypeError, ValueError) as error:
        raise CurveError(f"Governor config is invalid TOML: {error}") from error
    raw_points = data.get("safe-points")
    if not isinstance(raw_points, list) or not raw_points:
        raise CurveError("Governor config has no [[safe-points]] curve.")
    points = []
    for index, point in enumerate(raw_points, 1):
        if not isinstance(point, dict):
            raise CurveError(f"Curve point {index} is not a TOML table.")
        if set(point) != {"frequency", "voltage"}:
            raise CurveError(f"Curve point {index} contains unsupported fields.")
        frequency = point.get("frequency")
        voltage = point.get("voltage")
        if type(frequency) is not int or type(voltage) is not int:
            raise CurveError(f"Curve point {index} needs integer frequency and voltage values.")
        points.append((frequency, voltage))
    return points


def validate_points(points):
    if len(points) < 2:
        raise CurveError("The voltage curve must contain at least two points.")
    previous_frequency = None
    previous_voltage = None
    for frequency, voltage in points:
        if not frequency_min <= frequency <= frequency_max:
            raise CurveError(
                f"Frequency {frequency} is outside {frequency_min}-{frequency_max} MHz."
            )
        if not voltage_min <= voltage <= voltage_max:
            raise CurveError(
                f"Voltage {voltage} is outside {voltage_min}-{voltage_max} mV."
            )
        if previous_frequency is not None and frequency <= previous_frequency:
            raise CurveError("Curve frequencies must be sorted and unique.")
        if previous_voltage is not None and voltage < previous_voltage:
            raise CurveError("Curve voltage cannot decrease as frequency increases.")
        previous_frequency = frequency
        previous_voltage = voltage


def integer(value, label, signed=False):
    pattern = r"[+-]?[0-9]+" if signed else r"[0-9]+"
    if re.fullmatch(pattern, value or "") is None:
        raise CurveError(f"{label} must be a whole number.")
    return int(value)


def mutate_points(points, operation, values):
    if operation == "reset":
        if values:
            raise CurveError("reset takes no values.")
        return [(300, 700), (1000, 800), (1500, 900), (2000, 1000), (2150, 1000)]

    validate_points(points)
    if operation == "offset":
        if len(values) != 1:
            raise CurveError("offset needs one mV delta.")
        delta = integer(values[0], "Voltage offset", signed=True)
        return [(frequency, voltage + delta) for frequency, voltage in points]

    if operation == "add":
        if len(values) != 2:
            raise CurveError("add needs frequency and voltage values.")
        frequency = integer(values[0], "Frequency")
        voltage = integer(values[1], "Voltage")
        if any(existing == frequency for existing, _ in points):
            raise CurveError(f"A curve point already exists at {frequency} MHz.")
        return sorted([*points, (frequency, voltage)])

    if operation == "set":
        if len(values) != 2:
            raise CurveError("set needs frequency and voltage values.")
        frequency = integer(values[0], "Frequency")
        voltage = integer(values[1], "Voltage")
        if not any(existing == frequency for existing, _ in points):
            raise CurveError(f"No curve point exists at {frequency} MHz.")
        return [(existing, voltage if existing == frequency else current) for existing, current in points]

    if operation == "edit":
        if len(values) != 3:
            raise CurveError("edit needs old frequency, new frequency, and voltage values.")
        old_frequency = integer(values[0], "Existing frequency")
        frequency = integer(values[1], "New frequency")
        voltage = integer(values[2], "Voltage")
        if not any(existing == old_frequency for existing, _ in points):
            raise CurveError(f"No curve point exists at {old_frequency} MHz.")
        if frequency != old_frequency and any(existing == frequency for existing, _ in points):
            raise CurveError(f"A curve point already exists at {frequency} MHz.")
        return sorted(
            (frequency, voltage) if existing == old_frequency else (existing, current)
            for existing, current in points
        )

    if operation == "remove":
        if len(values) != 1:
            raise CurveError("remove needs one frequency value.")
        frequency = integer(values[0], "Frequency")
        if not any(existing == frequency for existing, _ in points):
            raise CurveError(f"No curve point exists at {frequency} MHz.")
        return [(existing, voltage) for existing, voltage in points if existing != frequency]

    raise CurveError(f"Unknown voltage-curve operation: {operation}")


def validate_frequency_state(points):
    if not state_path.exists():
        return False
    content, _ = read_regular(state_path, trusted=True)
    values = {}
    for line in content.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"MODE", "A", "B"}:
                values[key] = value
    state_mode = values.get("MODE", "")
    if state_mode == "adaptive":
        return False
    if state_mode == "max":
        return True
    low, high = points[0][0], points[-1][0]
    if state_mode == "pin":
        frequency = integer(values.get("A", ""), "Saved pinned frequency")
        if not low <= frequency <= high:
            raise CurveError("Saved pinned frequency falls outside the candidate curve.")
        return True
    if state_mode == "range":
        minimum = integer(values.get("A", ""), "Saved minimum frequency")
        maximum = integer(values.get("B", ""), "Saved maximum frequency")
        if (minimum != 0 and not low <= minimum <= high) or not low <= maximum <= high:
            raise CurveError("Saved frequency range falls outside the candidate curve.")
        if minimum and minimum > maximum:
            raise CurveError("Saved frequency range is inverted.")
        return True
    raise CurveError("Saved GPU frequency state is invalid.")


def render_config(content, points):
    lines = content.splitlines(keepends=True)
    safe_header = re.compile(r"^\s*\[\[safe-points\]\]\s*(?:#.*)?$")
    assignment = re.compile(
        r"^\s*(frequency|voltage)\s*=\s*([0-9]+)\s*(?:#.*)?$"
    )
    starts = [index for index, line in enumerate(lines) if safe_header.match(line.rstrip("\r\n"))]
    if not starts:
        raise CurveError("Governor config has no [[safe-points]] blocks to replace.")
    ranges = []
    for start in starts:
        found = set()
        end = None
        for index in range(start + 1, len(lines)):
            stripped = lines[index].rstrip("\r\n")
            if not stripped.strip() or stripped.lstrip().startswith("#"):
                continue
            matched = assignment.match(stripped)
            if matched is None or matched.group(1) in found:
                raise CurveError(
                    f"Curve block at line {start + 1} has unsupported content."
                )
            found.add(matched.group(1))
            if found == {"frequency", "voltage"}:
                end = index + 1
                break
        if end is None:
            raise CurveError(f"Curve block at line {start + 1} is incomplete.")
        ranges.append((start, end))
    rendered = "".join(
        f"[[safe-points]]\nfrequency = {frequency}\nvoltage = {voltage}\n\n"
        for frequency, voltage in points
    )
    output = []
    cursor = 0
    for index, (start, end) in enumerate(ranges):
        output.extend(lines[cursor:start])
        if index == 0:
            output.append(rendered)
        cursor = end
    output.extend(lines[cursor:])
    candidate = "".join(output)
    try:
        tomllib.loads(candidate)
    except (TypeError, ValueError) as error:
        raise CurveError(f"Candidate governor config is invalid TOML: {error}") from error
    reparsed = parse_config(candidate)
    validate_points(reparsed)
    if reparsed != points:
        raise CurveError(
            "Candidate curve does not match the requested points; normalize safe-point headers first."
        )
    return candidate


def atomic_write(path, content, metadata):
    parent = path.parent
    replacement_done = False
    try:
        parent_metadata = parent.lstat()
        if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
            raise CurveError(f"Governor config directory is unsafe: {parent}")
        if (
            parent_metadata.st_uid != os.geteuid()
            or parent_metadata.st_mode & 0o022
        ):
            raise CurveError(f"Governor config directory is not trusted: {parent}")
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        try:
            os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
            os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            replacement_done = True
            directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except CurveError:
        raise
    except OSError as error:
        raise AtomicWriteError(
            f"Could not atomically update {path}: {error}", replacement_done
        ) from error


def open_lock():
    if not lock_path.is_absolute() or lock_path.name in {"", ".", ".."}:
        raise CurveError(f"Control lock path is invalid: {lock_path}")
    parent = lock_path.parent
    try:
        parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        parent_metadata = parent.lstat()
        if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
            raise CurveError(f"Control lock directory is unsafe: {parent}")
        if parent_metadata.st_mode & 0o022 or parent_metadata.st_uid != os.geteuid():
            raise CurveError(f"Control lock directory is not trusted: {parent}")
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            descriptor = os.open(
                lock_path.name,
                os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            metadata = os.fstat(descriptor)
            named = lock_path.lstat()
            opened_parent = os.fstat(directory)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise CurveError(f"Control lock file is unsafe: {lock_path}")
            if (metadata.st_dev, metadata.st_ino) != (named.st_dev, named.st_ino):
                raise CurveError(f"Control lock changed while opening: {lock_path}")
            if (parent_metadata.st_dev, parent_metadata.st_ino) != (
                opened_parent.st_dev,
                opened_parent.st_ino,
            ):
                raise CurveError(f"Control lock directory changed while opening: {parent}")
            if metadata.st_mode & 0o022 or metadata.st_uid != os.geteuid():
                raise CurveError(f"Control lock file is not trusted: {lock_path}")
            return descriptor
        finally:
            os.close(directory)
    except CurveError:
        if "descriptor" in locals():
            os.close(descriptor)
        raise
    except OSError as error:
        raise CurveError(f"Could not open control lock {lock_path}: {error}") from error


def acquire_lock(descriptor):
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise CurveError("Another BC-250 control operation is still running.")
            time.sleep(0.05)


def run(command, description):
    try:
        result = subprocess.run(command, check=False)
    except OSError as error:
        raise CurveError(f"{description} could not run: {error}") from error
    if result.returncode != 0:
        raise CurveError(f"{description} failed with exit status {result.returncode}.")


def service_active():
    try:
        result = subprocess.run(
            [systemctl, "is-active", "--quiet", service], check=False
        )
    except OSError as error:
        raise CurveError(f"Could not query {service}: {error}") from error
    if result.returncode == 0:
        return True
    if result.returncode == 3:
        try:
            state = subprocess.run(
                [systemctl, "show", "--property=ActiveState", "--value", service],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise CurveError(f"Could not query {service}: {error}") from error
        if state.returncode != 0:
            raise CurveError(
                f"Governor service-state query failed with exit status {state.returncode}."
            )
        active_state = state.stdout.strip()
        if active_state == "active":
            return True
        if active_state in {"inactive", "failed"}:
            return False
        if active_state in {"activating", "deactivating", "reloading"}:
            raise TransitionalServiceError(
                f"Governor service is currently {active_state}; retry after it settles."
            )
        raise CurveError(f"Governor returned an unknown service state: {active_state or 'empty'}.")
    raise CurveError(
        f"Governor service-state query failed with exit status {result.returncode}."
    )


def trusted_executable(path):
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_nlink == 1
        and metadata.st_uid == os.geteuid()
        and not metadata.st_mode & 0o022
        and os.access(path, os.X_OK)
    )


def apply_runtime(has_state):
    run([systemctl, "restart", service], "Governor restart")
    run([systemctl, "is-active", "--quiet", service], "Governor health check")
    if has_state:
        if not trusted_executable(restore_path):
            raise CurveError(f"Saved frequency restore helper is unavailable: {restore_path}")
        run([str(restore_path)], "Saved frequency replay")


def main():
    original, metadata = read_regular(config_path)
    points = parse_config(original)
    if mode == "list":
        validate_points(points)
        for frequency, voltage in points:
            print(f"{frequency} {voltage}")
        return
    if mode != "mutate" or not arguments:
        raise CurveError("Internal voltage-curve helper usage error.")

    descriptor = open_lock()
    try:
        acquire_lock(descriptor)
        original, metadata = read_regular(config_path, trusted=True)
        points = parse_config(original)
        candidate_points = mutate_points(points, arguments[0], arguments[1:])
        validate_points(candidate_points)
        has_state = validate_frequency_state(candidate_points)
        candidate = render_config(original, candidate_points)
        active = service_active()
        if has_state and not trusted_executable(restore_path):
            raise CurveError(f"Saved frequency restore helper is unavailable: {restore_path}")

        written = False
        runtime_active = active
        try:
            try:
                atomic_write(config_path, candidate, metadata)
                written = True
            except BaseException as error:
                written = getattr(error, "replacement_done", False)
                raise
            if active:
                apply_runtime(has_state)
            else:
                try:
                    became_active = service_active()
                except TransitionalServiceError:
                    runtime_active = True
                    raise
                if became_active:
                    runtime_active = True
                    apply_runtime(has_state)
        except BaseException as error:
            if not written:
                raise
            rollback_errors = []
            try:
                atomic_write(config_path, original, metadata)
            except Exception as rollback_error:
                rollback_errors.append(f"config restore failed: {rollback_error}")
            if runtime_active:
                try:
                    apply_runtime(has_state)
                except Exception as rollback_error:
                    rollback_errors.append(f"runtime restore failed: {rollback_error}")
            if rollback_errors:
                raise CurveError(f"{error}; " + "; ".join(rollback_errors)) from error
            raise CurveError(f"{error}; previous curve and runtime restored") from error
    finally:
        os.close(descriptor)


try:
    main()
except CurveError as error:
    print(f"bc250: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

volt_points() {
    [[ -f "$GOV_CONF" ]] || die "No governor config at $GOV_CONF -- run '$0 governor' first."
    volt_curve_helper list
}

volt_show() {
    local points live
    points=$(volt_points) || return $?
    echo -e "${CB}=== GPU voltage curve ($GOV_CONF) ===${C0}"
    while read -r frequency voltage; do
        [[ -n "$frequency" ]] && printf '  %4d MHz -> %4d mV\n' "$frequency" "$voltage"
    done <<< "$points"
    live=$(sensors 2>/dev/null | grep -im1 vddgfx || true)
    [[ -n "$live" ]] && echo "  live: $live"
    echo "  (curve bounds: ${GPU_FREQ_MIN}-${GPU_FREQ_MAX} MHz, ${VOLT_MIN}-${VOLT_MAX} mV)"
}

volt_transaction() {
    require_root
    [[ -f "$GOV_CONF" ]] || die "No governor config -- run '$0 governor' first."
    volt_curve_helper mutate "$@"
    log "Curve saved atomically${GOV_SVC:+; active runtime reloaded when needed}."
}

volt_offset() {
    local delta="${1:-}"
    [[ $# -eq 1 ]] || die "Usage: $0 gpu-volt offset <+/-mV>   (e.g. offset -25)"
    [[ "$delta" =~ ^[+-]?[0-9]+$ ]] || die "Usage: $0 gpu-volt offset <+/-mV>   (e.g. offset -25)"
    volt_transaction offset "$delta"
    log "Whole curve shifted ${delta} mV."
    volt_show
    warn "Stress test now -- undervolts that boot fine can still crash under load."
}

volt_set() {
    local frequency="${1:-}" voltage="${2:-}"
    [[ $# -eq 2 ]] || die "Usage: $0 gpu-volt set <freqMHz> <mV>"
    [[ "$frequency" =~ ^[0-9]+$ && "$voltage" =~ ^[0-9]+$ ]] \
        || die "Usage: $0 gpu-volt set <freqMHz> <mV>"
    volt_transaction set "$frequency" "$voltage"
    log "Point $frequency MHz -> $voltage mV."
    warn "Stress test now -- undervolts that boot fine can still crash under load."
}

volt_add() {
    local frequency="${1:-}" voltage="${2:-}"
    [[ $# -eq 2 ]] || die "Usage: $0 gpu-volt add <freqMHz> <mV>"
    [[ "$frequency" =~ ^[0-9]+$ && "$voltage" =~ ^[0-9]+$ ]] \
        || die "Usage: $0 gpu-volt add <freqMHz> <mV>"
    volt_transaction add "$frequency" "$voltage"
    log "Added point $frequency MHz -> $voltage mV."
    warn "Stress test the changed curve before relying on it."
}

volt_edit() {
    local old_frequency="${1:-}" frequency="${2:-}" voltage="${3:-}"
    [[ $# -eq 3 ]] || die "Usage: $0 gpu-volt edit <oldFreqMHz> <newFreqMHz> <mV>"
    [[ "$old_frequency" =~ ^[0-9]+$ && "$frequency" =~ ^[0-9]+$ && "$voltage" =~ ^[0-9]+$ ]] \
        || die "Usage: $0 gpu-volt edit <oldFreqMHz> <newFreqMHz> <mV>"
    volt_transaction edit "$old_frequency" "$frequency" "$voltage"
    log "Point $old_frequency MHz changed to $frequency MHz -> $voltage mV."
    warn "Stress test the changed curve before relying on it."
}

volt_remove() {
    local frequency="${1:-}"
    [[ $# -eq 1 ]] || die "Usage: $0 gpu-volt remove <freqMHz>"
    [[ "$frequency" =~ ^[0-9]+$ ]] || die "Usage: $0 gpu-volt remove <freqMHz>"
    volt_transaction remove "$frequency"
    log "Removed point at $frequency MHz."
    warn "The first and last remaining points now define the available frequency range."
}

volt_reset() {
    [[ $# -eq 0 ]] || die "Usage: $0 gpu-volt reset"
    volt_transaction reset
    log "Curve reset to tuned defaults."
    volt_show
}

cmd_gpu_volt() {
    local sub="${1:-show}"
    shift || true
    case "$sub" in
        ""|show)  volt_show ;;
        offset)   volt_offset "$@" ;;
        set)      volt_set "$@" ;;
        add)      volt_add "$@" ;;
        edit)     volt_edit "$@" ;;
        remove)   volt_remove "$@" ;;
        reset)    volt_reset ;;
        *) die "Usage: $0 gpu-volt {show | offset <+/-mV> | set <freqMHz> <mV> | add <freqMHz> <mV> | edit <oldFreqMHz> <newFreqMHz> <mV> | remove <freqMHz> | reset}" ;;
    esac
}

# ========================= GPU load-target control ========================
# The governor only clocks UP when sampled GPU busy% exceeds load-target
# upper -- a frame-capped light game can sit at 60-75% busy at idle clocks
# forever and never trigger a ramp. These commands edit [load-target] in
# config.toml (persists) and push the same values live over D-Bus
# (SetLoadTarget -- no restart, saved freq state untouched).
LT_DEF_UPPER=0.80    # tuned defaults written by 'governor'
LT_DEF_LOWER=0.65
LT_EAGER_UPPER=0.40  # light-load preset: ramps on loads the default ignores
LT_EAGER_LOWER=0.10

lt_norm() {   # "60" or "0.60" -> "0.60"; rejects junk and out-of-range
    awk -v v="${1:-}" 'BEGIN{
        if (v !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
        v += 0; if (v > 1) v /= 100
        if (v < 0.05 || v > 0.99) exit 1
        printf "%.2f", v }'
}

lt_config_get() {   # config values as "upper lower", normalized; empty if absent
    [[ -f "$GOV_CONF" ]] || return 0
    awk '/^\[/{ lt = ($0=="[load-target]") }
         lt && /^upper = /{u=$3} lt && /^lower = /{l=$3}
         END{ if (u!="" && l!="") printf "%.2f %.2f", u, l }' "$GOV_CONF"
}

lt_live_get() {   # live values from the governor as "upper lower"; empty if down
    local u l
    u=$(busctl --system get-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" \
            LoadTargetMax 2>/dev/null | awk '{printf "%.2f", $2}') || true
    l=$(busctl --system get-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" \
            LoadTargetMin 2>/dev/null | awk '{printf "%.2f", $2}') || true
    [[ -n "$u" && -n "$l" ]] && echo "$u $l"
    return 0
}

lt_show() {
    [[ -f "$GOV_CONF" ]] || die "No governor config at $GOV_CONF -- run '$0 governor' first."
    echo -e "${CB}=== GPU load targets ===${C0}"
    local cfg live
    cfg=$(lt_config_get)
    if [[ -n "$cfg" ]]; then
        echo "  config (applies at boot):  upper ${cfg% *}  lower ${cfg#* }"
    else
        echo "  config: no [load-target] section -- governor built-ins apply (0.95/0.80)"
    fi
    live=$(lt_live_get)
    if [[ -n "$live" ]]; then
        echo "  live (governor, running):  upper ${live% *}  lower ${live#* }"
    else
        echo "  live: governor not running (or D-Bus down)"
    fi
    echo "  clocks UP when GPU busy% stays above upper; steps DOWN below lower."
    echo "  Lower upper = lighter loads trigger a ramp off idle clocks."
}

lt_apply_live() {   # push to the running governor; restart only as fallback
    local upper="$1" lower="$2"
    if ! systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        warn "Governor not running -- values take effect when it starts."
        return 0
    fi
    # D-Bus signature is SetLoadTarget(min, max) = (lower, upper)
    if gov_dbus SetLoadTarget dd "$lower" "$upper" >/dev/null 2>&1; then
        log "Applied live -- no restart needed."
    else
        warn "D-Bus call failed -- restarting the governor to load the new config."
        restart_governor_reapply
    fi
}

lt_set() {
    require_root
    local usage="Usage: $0 load-target set <upper> <lower>   (percent 60 45, or fractions 0.60 0.45)"
    local upper lower
    upper=$(lt_norm "${1:-}") || die "$usage"
    lower=$(lt_norm "${2:-}") || die "$usage"
    awk -v u="$upper" -v l="$lower" 'BEGIN{ exit !(l+0 < u+0) }' \
        || die "lower ($lower) must be below upper ($upper)."
    [[ -f "$GOV_CONF" ]] || die "No governor config -- run '$0 governor' first."
    gpu_control_lock || return $?
    if grep -q '^\[load-target\]' "$GOV_CONF"; then
        awk -v u="$upper" -v l="$lower" '
            /^\[/{ lt = ($0=="[load-target]") }
            lt && /^upper = /{ print "upper = " u; next }
            lt && /^lower = /{ print "lower = " l; next }
            { print }' "$GOV_CONF" > "$GOV_CONF.tmp"
    else
        # section missing (hand-edited config): insert ahead of the voltage
        # curve, or append -- both are valid TOML table placements
        awk -v u="$upper" -v l="$lower" '
            !done && (/^# Voltage curve/ || /^\[\[safe-points\]\]/) {
                print "[load-target]"; print "upper = " u
                print "lower = " l; print ""; done=1 }
            { print }
            END{ if (!done) { print "[load-target]"; print "upper = " u; print "lower = " l } }' \
            "$GOV_CONF" > "$GOV_CONF.tmp"
    fi
    mv "$GOV_CONF.tmp" "$GOV_CONF"
    log "Load targets saved: upper = $upper, lower = $lower (persists across reboots)."
    awk -v u="$upper" 'BEGIN{ exit !(u+0 < 0.40) }' \
        && warn "Upper below 0.40: very eager -- expect higher idle clocks/power."
    lt_apply_live "$upper" "$lower"
    gpu_control_unlock
}

cmd_load_target() {
    local sub="${1:-show}"
    shift || true
    case "$sub" in
        ""|show)  lt_show ;;
        set)      lt_set "$@" ;;
        eager)    lt_set "$LT_EAGER_UPPER" "$LT_EAGER_LOWER" ;;
        reset)    lt_set "$LT_DEF_UPPER" "$LT_DEF_LOWER" ;;
        *) die "Usage: $0 load-target {show | set <upper> <lower> | eager | reset}" ;;
    esac
}

# =========================== GPU ramp behavior ============================
# Every [timing.intervals] adjust cycle the governor moves its target by
# ramp-rates.normal x adjust_ms MHz. So climb SPEED is 'normal' alone
# (MHz/ms, interval-independent) and 'adjust' only sets step GRANULARITY.
# 'ramp set T' takes one number -- the idle-to-max climb time in ms -- and
# derives the smoothest step that cannot hunt: GPU busy% ~ 1/freq, so a
# step of S MHz at frequency f moves load by ~S/f; keeping
#   S <= f_min x (upper - lower) / upper
# means no single step can jump across the whole load-target band and
# oscillate. These are startup-only params (no D-Bus): governor restarts.
RAMP_DEF_ADJ_MS=200; RAMP_DEF_NORMAL=1; RAMP_DEF_BURST=50; RAMP_DEF_DE=5
RAMP_FALLBACK_MIN=500; RAMP_FALLBACK_MAX=2200

toml_get() {   # toml_get <section> <key> [file] -- value, underscores stripped
    local f="${3:-$GOV_CONF}"
    [[ -f "$f" ]] || return 0
    awk -v sec="[$1]" -v key="$2" '
        /^\[/{ insec = ($0 == sec) }
        insec && $1 == key && $2 == "=" { gsub("_", "", $3); print $3; exit }
    ' "$f"
}

toml_set() {   # toml_set <section> <key> <value> <file> -- edits file in place
    local f="$4"
    awk -v sec="[$1]" -v key="$2" -v val="$3" '
        function emit() { print key " = " val; done = 1 }
        /^\[/{ if (insec && !done) emit()             # leaving section, key absent
               insec = ($0 == sec); if (insec) found = 1 }
        insec && !done && $1 == key && $2 == "=" { emit(); next }
        { print }
        END{ if (!done) { if (!found) { print ""; print sec }; emit() } }
    ' "$f" > "$f.n" && mv "$f.n" "$f"
}

ramp_allowed_range() {   # hardware range from the running governor; empty if down
    local mn mx
    mn=$(busctl --system get-property "$BUS_NAME" "$BUS_PATH/Range/Allowed" \
             "$BUS_NAME.Range" min 2>/dev/null | awk '{print $2}') || true
    mx=$(busctl --system get-property "$BUS_NAME" "$BUS_PATH/Range/Allowed" \
             "$BUS_NAME.Range" max 2>/dev/null | awk '{print $2}') || true
    [[ -n "$mn" && -n "$mx" ]] && echo "$mn $mx"
    return 0
}

ramp_range() {   # "fmin fmax [assumed]" -- config range clamped by hw allowed
    local cmin cmax amin amax fmin fmax note=""
    cmin=$(toml_get frequency-range min)
    cmax=$(toml_get frequency-range max)
    read -r amin amax <<< "$(ramp_allowed_range)"
    if   [[ -n "$cmin" && -n "$amin" ]]; then fmin=$(( cmin > amin ? cmin : amin ))
    elif [[ -n "$cmin$amin" ]];          then fmin="${cmin:-$amin}"
    else fmin=$RAMP_FALLBACK_MIN; note=assumed; fi
    if   [[ -n "$cmax" && -n "$amax" ]]; then fmax=$(( cmax < amax ? cmax : amax ))
    elif [[ -n "$cmax$amax" ]];          then fmax="${cmax:-$amax}"
    else fmax=$RAMP_FALLBACK_MAX; note=assumed; fi
    echo "$fmin $fmax $note"
}

ramp_lt() {   # load targets from config as "upper lower", defaults if absent
    local lt
    lt=$(lt_config_get)
    echo "${lt:-$LT_DEF_UPPER $LT_DEF_LOWER}"
}

ramp_restart_if_active() {   # ramp params are read at startup only
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        restart_governor_reapply
    else
        warn "Governor not running -- new ramp params load when it starts."
    fi
}

ramp_show() {
    [[ -f "$GOV_CONF" ]] || die "No governor config at $GOV_CONF -- run '$0 governor' first."
    local adj_us sample normal de bs fmin fmax note upper lower
    adj_us=$(toml_get timing.intervals adjust);  adj_us=${adj_us:-20000}
    sample=$(toml_get timing.intervals sample);  sample=${sample:-2000}
    normal=$(toml_get timing.ramp-rates normal); normal=${normal:-1}
    de=$(toml_get timing down-events);           de=${de:-10}
    bs=$(toml_get timing burst-samples)
    read -r fmin fmax note <<< "$(ramp_range)"
    read -r upper lower   <<< "$(ramp_lt)"
    echo -e "${CB}=== GPU ramp behavior ===${C0}"
    awk -v aus="$adj_us" -v n="$normal" -v de="$de" -v fmin="$fmin" -v fmax="$fmax" \
        -v up="$upper" -v lo="$lower" -v bs="${bs:-0}" -v sus="$sample" 'BEGIN{
        ms = aus / 1000.0
        S = n * ms
        ceil = fmin * (up - lo) / up
        printf "  step:      %.0f MHz every %.0f ms  (rate %g MHz/ms)\n", S, ms, n
        printf "  climb:     idle->max ~%.0f ms across %d-%d MHz\n", (fmax - fmin) / n, fmin, fmax
        printf "  downhold:  %.0f ms of low load before stepping down (down-events %d)\n", de * ms, de
        if (bs > 0) printf "  burst:     jump to max after %.0f ms of saturated load\n", bs * sus / 1000.0
        else        printf "  burst:     disabled\n"
        printf "  hunting:   step ceiling %.0f MHz at load targets %.2f/%.2f -> %s\n", ceil, up, lo,
            (S <= ceil + 0.5) ? "OK, cannot oscillate" \
                              : "AT RISK -- may bounce at steady load (run: ramp set)"
    }'
    [[ -n "$note" ]] && echo "  (hardware floor assumed ${fmin} MHz -- start the governor for the real one)"
    return 0
}

ramp_set() {
    require_root
    local T="${1:-}"
    [[ "$T" =~ ^[0-9]+$ ]] || die "Usage: $0 ramp set <climb-ms>   (idle-to-max climb time, e.g. 500)"
    (( T >= 200 && T <= 5000 )) || die "Climb time $T ms outside the sane 200-5000 ms window."
    [[ -f "$GOV_CONF" ]] || die "No governor config -- run '$0 governor' first."
    gpu_control_lock || return $?

    local fmin fmax note upper lower
    read -r fmin fmax note <<< "$(ramp_range)"
    [[ -n "$note" ]] && warn "Governor not running -- assuming a ${fmin} MHz hardware floor."
    (( fmax > fmin )) || die "Bad operating range ${fmin}-${fmax} MHz."
    local R=$(( fmax - fmin ))
    read -r upper lower <<< "$(ramp_lt)"

    # speed normal = R/T; hunting-safe step S <= fmin*(upper-lower)/upper;
    # interval = S/normal clamped to 50-200 ms (>= ~3 frames per load
    # average, still responsive). If the clamp pushes S past the ceiling,
    # slow the climb to the smallest hunting-free time instead of hunting.
    local calc normal adjust_ms step de teff capped
    calc=$(awk -v R="$R" -v T="$T" -v fmin="$fmin" -v up="$upper" -v lo="$lower" 'BEGIN{
        normal = R / T
        ceil = fmin * (up - lo) / up
        S = 0.7 * ceil
        if (S < 30) S = 30                       # dither floor: 3x apply threshold
        adj = S / normal
        if (adj < 50) adj = 50; if (adj > 200) adj = 200
        adj = int(adj + 0.5)
        S = normal * adj
        capped = 0
        if (S > ceil && ceil >= 30) { S = ceil; normal = S / adj; capped = 1 }
        de = int(1000.0 / adj + 0.5); if (de < 2) de = 2
        printf "%.3g %d %d %d %d %d", normal, adj, int(S + 0.5), de, int(R / normal + 0.5), capped
    }')
    read -r normal adjust_ms step de teff capped <<< "$calc"
    if [[ "$capped" == 1 ]]; then
        warn "At load targets $upper/$lower a hunting-free step maxes out at $step MHz:"
        warn "climb time extended $T -> ~$teff ms. (Wider load-target band or a"
        warn "higher freq floor would allow faster smooth climbs.)"
    fi

    # upstream rejects burst <= normal; keep the config's burst rate otherwise
    local burst
    burst=$(toml_get timing.ramp-rates burst); burst=${burst:-$RAMP_DEF_BURST}
    if awk -v b="$burst" -v n="$normal" 'BEGIN{ exit !(b + 0 <= n + 0) }'; then
        burst=$(awk -v n="$normal" 'BEGIN{ printf "%g", 200 * n }')
        warn "Burst rate raised to $burst (must stay above the normal rate)."
    fi

    cp "$GOV_CONF" "$GOV_CONF.tmp"
    toml_set timing.intervals adjust "${adjust_ms}_000" "$GOV_CONF.tmp"
    toml_set timing.ramp-rates normal "$normal"         "$GOV_CONF.tmp"
    toml_set timing.ramp-rates burst  "$burst"          "$GOV_CONF.tmp"
    toml_set timing down-events "$de"                   "$GOV_CONF.tmp"
    mv "$GOV_CONF.tmp" "$GOV_CONF"
    log "Ramp saved: $step MHz steps every $adjust_ms ms -> idle-to-max in ~$teff ms,"
    log "downscale after $(( de * adjust_ms )) ms of low load (down-events $de)."
    ramp_restart_if_active
    gpu_control_unlock
}

ramp_reset() {
    require_root
    [[ -f "$GOV_CONF" ]] || die "No governor config -- run '$0 governor' first."
    gpu_control_lock || return $?
    cp "$GOV_CONF" "$GOV_CONF.tmp"
    toml_set timing.intervals adjust "${RAMP_DEF_ADJ_MS}_000" "$GOV_CONF.tmp"
    toml_set timing.ramp-rates normal "$RAMP_DEF_NORMAL"      "$GOV_CONF.tmp"
    toml_set timing.ramp-rates burst  "$RAMP_DEF_BURST"       "$GOV_CONF.tmp"
    toml_set timing down-events "$RAMP_DEF_DE"                "$GOV_CONF.tmp"
    mv "$GOV_CONF.tmp" "$GOV_CONF"
    log "Ramp params reset to install defaults (200 MHz steps / 200 ms, 1 s hold)."
    ramp_restart_if_active
    gpu_control_unlock
}

cmd_ramp() {
    local sub="${1:-show}"
    shift || true
    case "$sub" in
        ""|show)  ramp_show ;;
        set)      ramp_set "$@" ;;
        reset)    ramp_reset ;;
        *) die "Usage: $0 ramp {show | set <climb-ms> | reset}" ;;
    esac
}

cmd_helpers() {
    require_root
    migrate_legacy_data
    install_update_persistence
    mkdir -p "$BIN_DIR" /etc/dbus-1/system.d
    # Pin to the latest release tag so helper and installed binary agree on
    # the D-Bus interface name (HEAD renamed it after v0.4.x).
    local rel_tag
    rel_tag=$(curl -fsSL "$GOV_API" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)
    [[ -n "$rel_tag" ]] && GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/$rel_tag"
    log "Fetching helpers from ${rel_tag:-smu branch HEAD}..."
    if curl -fL -o "$PERF_BIN" "$GOV_RAW/scripts/cyan-skillfish-performance-mode"; then
        chmod 755 "$PERF_BIN"
        log "  -> $PERF_BIN"
    else
        warn "Helper fetch failed; check the scripts/ dir name on the smu branch."
    fi
    if [[ ! -s "$DBUS_POLICY" ]] \
        || ! grep -q 'com.cyanskillfish.Governor' "$DBUS_POLICY" \
        || grep -q '<policy context="default">' "$DBUS_POLICY"; then
        log "Writing root-only dual-name D-Bus policy (upstream's is stale vs its binary)..."
        cat > "$DBUS_POLICY" << 'EOF'
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="com.cyan.SkillFishGovernor"/>
    <allow own="com.cyanskillfish.Governor"/>
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
  </policy>
</busconfig>
EOF
        busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig \
            2>/dev/null || warn "D-Bus reload failed; reboot to activate the policy."
        systemctl restart "$GOV_SVC" 2>/dev/null || true
    else
        log "Root-only dual-name D-Bus policy already present."
    fi
    log "Test: sudo $PERF_BIN --status"
}

cmd_enable() {
    require_root
    migrate_legacy_data
    [[ -x "$GOV_BIN" && -f "$GOV_CONF" ]] \
        || die "Governor is not installed -- run '$0 governor' first."
    check_conflicts
    write_governor_unit
    install_freq_persistence force
    systemctl daemon-reload
    systemctl enable "$GOV_SVC" "$RESTORE_SVC"
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        systemctl restart "$RESTORE_SVC" \
            || warn "Governor enabled, but the saved frequency range was not restored."
    fi
    install_update_persistence
    log "Governor enabled at boot (order: CU table -> governor)."
    log "cpufreq + ACPI self-heal were enabled during 'acpi'. All set."
}

# Machine-readable lifecycle probe. Retained tuning and persistent data do not
# count as an installation, so this returns not-installed after an uninstall.
other_power_payload_is_installed() {
    [[ -e "$HEAL_UNIT" || -e "$CPUFREQ_UNIT" || -e "$GOV_UNIT" \
        || -e "$RESTORE_UNIT" || -e "$OC_UNIT" || -e "$GRUB_ACPI_DEFAULT" \
        || -e "$CPIO_BOOT" || -e "$DBUS_POLICY" \
        || -e "$HEAL_HELPER" || -e "$GOV_BIN" || -e "$PERF_BIN" \
        || -e "$RESTORE_BIN" || -e "$OC_DIR/bc250_apply.py" \
        || -e "$OC_DIR/bc250_smu" || -e "$LEGACY_HEAL_HELPER" \
        || -e "$CPU_MITIGATIONS_CONFIG" \
        || -L "$SYSTEMD_WANTS_DIR/bc250-acpi-heal.service" \
        || -L "$SYSTEMD_WANTS_DIR/bc250-cpufreq.service" \
        || -L "$SYSTEMD_WANTS_DIR/$GOV_SVC" \
        || -L "$SYSTEMD_WANTS_DIR/$RESTORE_SVC" \
        || -L "$SYSTEMD_WANTS_DIR/$OC_SVC" ]]
}

core_unlock_service_enabled() {
    [[ "$(systemctl is-enabled "$CORE_UNLOCK_SVC" 2>/dev/null || true)" == enabled \
        || -L "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC" ]]
}

core_unlock_auto_attempt_this_boot() {
    local marker_boot="" marker_kind="" current_boot=""
    [[ -f "$CORE_UNLOCK_PENDING" && -r "$CORE_UNLOCK_PENDING" ]] || return 1
    read -r marker_boot marker_kind < "$CORE_UNLOCK_PENDING" || return 1
    [[ -r /proc/sys/kernel/random/boot_id ]] || return 1
    read -r current_boot < /proc/sys/kernel/random/boot_id || return 1
    [[ "$marker_boot" == "$current_boot" \
        && ( "$marker_kind" == automatic || -z "$marker_kind" ) ]]
}

core_unlock_lifecycle_lock() {
    command -v flock >/dev/null 2>&1 \
        || { warn "flock is required for safe core-unlock removal."; return 1; }
    exec 8> "$CORE_UNLOCK_LIFECYCLE_LOCK" \
        || { warn "Could not open $CORE_UNLOCK_LIFECYCLE_LOCK"; return 1; }
    flock 8 \
        || { exec 8>&-; warn "Could not lock $CORE_UNLOCK_LIFECYCLE_LOCK"; return 1; }
}

core_unlock_operation_lock() {
    exec 9> "$CORE_UNLOCK_LOCK" \
        || { warn "Could not open $CORE_UNLOCK_LOCK"; return 1; }
    flock 9 \
        || { exec 9>&-; warn "Could not lock $CORE_UNLOCK_LOCK"; return 1; }
}

core_unlock_lifecycle_unlock() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
}

core_unlock_operation_unlock() {
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

efi_state_read() {
    local key value seen_boot=0 seen_source=0 seen_disk=0 seen_part=0
    local seen_partuuid=0 seen_label=0 seen_loader=0
    EFI_STATE_BOOTNUM="" EFI_STATE_SOURCE="" EFI_STATE_DISK="" EFI_STATE_PART=""
    EFI_STATE_PARTUUID="" EFI_STATE_LABEL="" EFI_STATE_LOADER=""
    [[ -f "$CORE_UNLOCK_EFI_STATE" && ! -L "$CORE_UNLOCK_EFI_STATE" ]] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            BOOTNUM) [[ $seen_boot -eq 0 ]] || return 1; seen_boot=1; EFI_STATE_BOOTNUM="$value" ;;
            ESP_SOURCE) [[ $seen_source -eq 0 ]] || return 1; seen_source=1; EFI_STATE_SOURCE="$value" ;;
            DISK) [[ $seen_disk -eq 0 ]] || return 1; seen_disk=1; EFI_STATE_DISK="$value" ;;
            PART) [[ $seen_part -eq 0 ]] || return 1; seen_part=1; EFI_STATE_PART="$value" ;;
            PARTUUID) [[ $seen_partuuid -eq 0 ]] || return 1; seen_partuuid=1; EFI_STATE_PARTUUID="$value" ;;
            LABEL) [[ $seen_label -eq 0 ]] || return 1; seen_label=1; EFI_STATE_LABEL="$value" ;;
            LOADER) [[ $seen_loader -eq 0 ]] || return 1; seen_loader=1; EFI_STATE_LOADER="$value" ;;
            "") ;;
            *) return 1 ;;
        esac
    done < "$CORE_UNLOCK_EFI_STATE"
    [[ $seen_boot -eq 1 && $seen_source -eq 1 && $seen_disk -eq 1 \
        && $seen_part -eq 1 && $seen_partuuid -eq 1 \
        && $seen_label -eq 1 && $seen_loader -eq 1 \
        && "$EFI_STATE_BOOTNUM" =~ ^[0-9A-Fa-f]{4}$ \
        && "$EFI_STATE_SOURCE" == /dev/* \
        && "$EFI_STATE_SOURCE" != *[$'\n\r\t ']* \
        && "$EFI_STATE_DISK" == /dev/* \
        && "$EFI_STATE_DISK" != *[$'\n\r\t ']* \
        && "$EFI_STATE_PART" =~ ^[1-9][0-9]*$ \
        && "$EFI_STATE_PARTUUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ \
        && "$EFI_STATE_LABEL" == "$CORE_UNLOCK_EFI_LABEL" \
        && "$EFI_STATE_LOADER" == "$CORE_UNLOCK_EFI_LOADER" ]] || return 1
    EFI_STATE_BOOTNUM=${EFI_STATE_BOOTNUM^^}
    EFI_STATE_PARTUUID=${EFI_STATE_PARTUUID,,}
}

efi_recovery_read() {
    local key value seen_phase=0 seen_source=0 seen_disk=0 seen_part=0
    local seen_partuuid=0 seen_before=0 seen_after=0 seen_candidate=0
    EFI_RECOVERY_SOURCE="" EFI_RECOVERY_DISK="" EFI_RECOVERY_PART=""
    EFI_RECOVERY_PARTUUID="" EFI_RECOVERY_BEFORE="" EFI_RECOVERY_AFTER=""
    EFI_RECOVERY_CANDIDATE="" EFI_RECOVERY_BEFORE_VALID=0 EFI_RECOVERY_AFTER_VALID=0
    [[ -f "$CORE_UNLOCK_EFI_RECOVERY" && ! -L "$CORE_UNLOCK_EFI_RECOVERY" ]] \
        || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            PHASE) [[ $seen_phase -eq 0 && "$value" == create ]] || return 1; seen_phase=1 ;;
            ESP_SOURCE) [[ $seen_source -eq 0 ]] || return 1; seen_source=1; EFI_RECOVERY_SOURCE="$value" ;;
            DISK) [[ $seen_disk -eq 0 ]] || return 1; seen_disk=1; EFI_RECOVERY_DISK="$value" ;;
            PART) [[ $seen_part -eq 0 ]] || return 1; seen_part=1; EFI_RECOVERY_PART="$value" ;;
            PARTUUID) [[ $seen_partuuid -eq 0 ]] || return 1; seen_partuuid=1; EFI_RECOVERY_PARTUUID="$value" ;;
            BEFORE) [[ $seen_before -eq 0 ]] || return 1; seen_before=1; EFI_RECOVERY_BEFORE="$value" ;;
            AFTER) [[ $seen_after -eq 0 ]] || return 1; seen_after=1; EFI_RECOVERY_AFTER="$value" ;;
            CANDIDATE) [[ $seen_candidate -eq 0 ]] || return 1; seen_candidate=1; EFI_RECOVERY_CANDIDATE="$value" ;;
            "") ;;
            *) return 1 ;;
        esac
    done < "$CORE_UNLOCK_EFI_RECOVERY"
    [[ $seen_phase -eq 1 && $seen_source -eq 1 && $seen_disk -eq 1 \
        && $seen_part -eq 1 && $seen_partuuid -eq 1 \
        && "$EFI_RECOVERY_SOURCE" == /dev/* \
        && "$EFI_RECOVERY_SOURCE" != *[$'\n\r\t ']* \
        && "$EFI_RECOVERY_DISK" == /dev/* \
        && "$EFI_RECOVERY_DISK" != *[$'\n\r\t ']* \
        && "$EFI_RECOVERY_PART" =~ ^[1-9][0-9]*$ \
        && "$EFI_RECOVERY_PARTUUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
        || return 1
    [[ $seen_before -eq 0 \
        || "$EFI_RECOVERY_BEFORE" =~ ^([0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*)?$ ]] \
        || return 1
    [[ $seen_after -eq 0 \
        || "$EFI_RECOVERY_AFTER" =~ ^([0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*)?$ ]] \
        || return 1
    [[ $seen_candidate -eq 0 || "$EFI_RECOVERY_CANDIDATE" =~ ^[0-9A-Fa-f]{4}$ ]] \
        || return 1
    EFI_RECOVERY_PARTUUID=${EFI_RECOVERY_PARTUUID,,}
    EFI_RECOVERY_BEFORE=${EFI_RECOVERY_BEFORE^^}
    EFI_RECOVERY_AFTER=${EFI_RECOVERY_AFTER^^}
    EFI_RECOVERY_CANDIDATE=${EFI_RECOVERY_CANDIDATE^^}
    [[ $seen_before -eq 0 ]] || EFI_RECOVERY_BEFORE_VALID=1
    [[ $seen_after -eq 0 ]] || EFI_RECOVERY_AFTER_VALID=1
}

efi_recovery_write() {
    local tmp="$CORE_UNLOCK_STATE_DIR/.efi-recovery.$$"
    TEMP_FILES+=("$tmp")
    {
        printf 'PHASE=create\nESP_SOURCE=%s\nDISK=%s\nPART=%s\nPARTUUID=%s\n' \
            "$EFI_RECOVERY_SOURCE" "$EFI_RECOVERY_DISK" \
            "$EFI_RECOVERY_PART" "$EFI_RECOVERY_PARTUUID"
        [[ $EFI_RECOVERY_BEFORE_VALID -eq 0 ]] \
            || printf 'BEFORE=%s\n' "$EFI_RECOVERY_BEFORE"
        [[ $EFI_RECOVERY_AFTER_VALID -eq 0 ]] \
            || printf 'AFTER=%s\n' "$EFI_RECOVERY_AFTER"
        [[ -z "$EFI_RECOVERY_CANDIDATE" ]] \
            || printf 'CANDIDATE=%s\n' "$EFI_RECOVERY_CANDIDATE"
    } > "$tmp"
    chmod 0600 "$tmp"
    sync "$tmp"
    mv -f "$tmp" "$CORE_UNLOCK_EFI_RECOVERY"
    sync "$CORE_UNLOCK_STATE_DIR"
}

efi_number_in_csv() {
    local list=",${1^^}," number=",${2^^},"
    [[ "$list" == *"$number"* ]]
}

efi_read_boot_listing() {
    command -v efibootmgr >/dev/null 2>&1 || return 1
    EFI_BOOT_LISTING=$(LC_ALL=C efibootmgr -v 2>/dev/null) || return 1
    [[ "$EFI_BOOT_LISTING" == *"BootOrder:"* ]] || return 1
}

efi_boot_entry_present_in() {
    local number="${1^^}" listing="$2" line
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot${number}\*?[[:space:]] ]] && return 0
    done <<< "$listing"
    return 1
}

efi_boot_entry_matches_in() {
    local number="${1^^}" require_active="$2" listing="$3"
    local line active rest lower expected="${CORE_UNLOCK_EFI_LOADER,,}"
    local loader_regex pattern
    loader_regex=${expected//\\/\\\\}
    loader_regex=${loader_regex//./\\.}
    pattern="^${CORE_UNLOCK_EFI_LABEL,,}[[:space:]]+hd\\(${CORE_UNLOCK_ESP_PART},gpt,${CORE_UNLOCK_ESP_PARTUUID,,},[^)]*\\)/((\\\\)?file\\(${loader_regex}\\)|${loader_regex})[[:space:]]*$"
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot${number}(\*)?[[:space:]]+(.+)$ ]] || continue
        active=${BASH_REMATCH[1]}
        rest=${BASH_REMATCH[2]//$'\t'/ }
        lower=${rest,,}
        [[ "$require_active" -eq 0 || "$active" == "*" ]] || return 1
        [[ "$lower" =~ $pattern ]] || return 1
        return 0
    done <<< "$listing"
    return 1
}

efi_boot_order_first_in() {
    local listing="$1" line
    while IFS= read -r line; do
        [[ "$line" =~ ^BootOrder:[[:space:]]*([0-9A-Fa-f]{4})(,|$) ]] || continue
        printf '%s\n' "${BASH_REMATCH[1]^^}"
        return 0
    done <<< "$listing"
    return 1
}

efi_boot_numbers_in() {
    local listing="$1" line
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        printf '%s\n' "${BASH_REMATCH[1]^^}"
    done <<< "$listing"
    return 0
}

efi_matching_boot_numbers_in() {
    local listing="$1" line rest lower number expected="${CORE_UNLOCK_EFI_LOADER,,}"
    local loader_regex pattern
    loader_regex=${expected//\\/\\\\}
    loader_regex=${loader_regex//./\\.}
    pattern="^${CORE_UNLOCK_EFI_LABEL,,}[[:space:]]+hd\\([^)]*\\)/((\\\\)?file\\(${loader_regex}\\)|${loader_regex})[[:space:]]*$"
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(.+)$ ]] || continue
        number=${BASH_REMATCH[1]^^}
        rest=${BASH_REMATCH[2]//$'\t'/ }
        lower=${rest,,}
        [[ "$lower" =~ $pattern ]] && printf '%s\n' "$number"
    done <<< "$listing"
    return 0
}

verify_core_unlock_recovery_esp_state() {
    discover_core_unlock_esp || return 1
    if [[ "$CORE_UNLOCK_ESP_SOURCE" != "$EFI_RECOVERY_SOURCE" \
        || "$CORE_UNLOCK_ESP_DISK" != "$EFI_RECOVERY_DISK" \
        || "$CORE_UNLOCK_ESP_PART" != "$EFI_RECOVERY_PART" \
        || "$CORE_UNLOCK_ESP_PARTUUID" != "$EFI_RECOVERY_PARTUUID" ]]; then
        ESP_DISCOVERY_ERROR="Mounted ESP identity differs from recorded EFI recovery state."
        return 1
    fi
}

efi_recovery_resolve_boot_number() {
    local listing="$1" number match unexpected=0
    local -a owned_matches=()
    EFI_RECOVERY_RESOLVED_BOOTNUM=
    while IFS= read -r number; do
        [[ -n "$number" ]] || continue
        efi_number_in_csv "$EFI_RECOVERY_BEFORE" "$number" && continue
        if efi_boot_entry_matches_in "$number" 0 "$listing"; then
            if [[ $EFI_RECOVERY_AFTER_VALID -eq 1 ]] \
                && efi_number_in_csv "$EFI_RECOVERY_AFTER" "$number"; then
                owned_matches+=("$number")
            else
                unexpected=1
            fi
        fi
    done < <(efi_boot_numbers_in "$listing")
    [[ $unexpected -eq 0 ]] || return 1
    if [[ -n "$EFI_RECOVERY_CANDIDATE" ]]; then
        [[ $EFI_RECOVERY_BEFORE_VALID -eq 1 ]] || return 1
        efi_number_in_csv "$EFI_RECOVERY_BEFORE" "$EFI_RECOVERY_CANDIDATE" \
            && return 1
        [[ $EFI_RECOVERY_AFTER_VALID -eq 1 ]] \
            && efi_number_in_csv "$EFI_RECOVERY_AFTER" "$EFI_RECOVERY_CANDIDATE" \
            || return 1
        if efi_boot_entry_present_in "$EFI_RECOVERY_CANDIDATE" "$listing"; then
            efi_boot_entry_matches_in "$EFI_RECOVERY_CANDIDATE" 0 "$listing" \
                || return 1
        fi
        for match in "${owned_matches[@]-}"; do
            [[ -z "$match" || "$match" == "$EFI_RECOVERY_CANDIDATE" ]] || return 1
        done
        EFI_RECOVERY_RESOLVED_BOOTNUM="$EFI_RECOVERY_CANDIDATE"
        return 0
    fi
    if [[ $EFI_RECOVERY_BEFORE_VALID -eq 0 && ${#owned_matches[@]} -gt 0 ]]; then
        return 1
    fi
    [[ ${#owned_matches[@]} -le 1 ]] || return 1
    [[ ${#owned_matches[@]} -eq 0 ]] \
        || EFI_RECOVERY_RESOLVED_BOOTNUM="${owned_matches[0]}"
}

efi_nvram_artifact_present() {
    local matches
    efi_read_boot_listing || return 2
    matches=$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")
    [[ -n "$matches" ]]
}

core_unlock_efi_guard_path() {
    printf '%s/BC250CoreUnlockAttempt-%s\n' \
        "$CORE_UNLOCK_EFIVARS_DIR" "$CORE_UNLOCK_EFI_GUARD_GUID"
}

efi_guard_present() {
    [[ -e "$(core_unlock_efi_guard_path)" ]]
}

efi_owned_files_present() {
    [[ -e "$CORE_UNLOCK_EFI_MASTER" || -e "$CORE_UNLOCK_EFI_STATE" \
        || -e "$CORE_UNLOCK_EFI_BOOTNUM" || -e "$CORE_UNLOCK_EFI_IMAGE_HASH" \
        || -e "$CORE_UNLOCK_EFI_RECOVERY" || -e "$CORE_UNLOCK_EFI_IMAGE" \
        || -e "$CORE_UNLOCK_EFI_LICENSE" || -e "$CORE_UNLOCK_EFI_HEADER_LICENSE" ]]
}

efi_artifacts_present() {
    local rc
    if efi_owned_files_present || efi_guard_present; then
        return 0
    fi
    efi_nvram_artifact_present && return 0
    rc=$?
    [[ $rc -eq 2 && -d "$CORE_UNLOCK_EFIVARS_DIR" ]] && return 0
    return 1
}

efi_configuration_complete() {
    local allow_recovery="${1:-0}"
    [[ -f "$CORE_UNLOCK_EFI_MASTER" && ! -L "$CORE_UNLOCK_EFI_MASTER" \
        && -f "$CORE_UNLOCK_EFI_IMAGE" && ! -L "$CORE_UNLOCK_EFI_IMAGE" \
        && -f "$CORE_UNLOCK_EFI_LICENSE" && ! -L "$CORE_UNLOCK_EFI_LICENSE" \
        && -f "$CORE_UNLOCK_EFI_HEADER_LICENSE" && ! -L "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
        && -f "$CORE_UNLOCK_EFI_BOOTNUM" && ! -L "$CORE_UNLOCK_EFI_BOOTNUM" \
        && -f "$CORE_UNLOCK_EFI_IMAGE_HASH" && ! -L "$CORE_UNLOCK_EFI_IMAGE_HASH" ]] \
        || return 1
    [[ "$allow_recovery" -eq 1 || ! -e "$CORE_UNLOCK_EFI_RECOVERY" ]] || return 1
    efi_guard_present && return 1
    cmp -s "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_IMAGE" || return 1
    efi_state_read || return 1
    verify_core_unlock_esp_state || return 1
    [[ "$(tr -d '\n' < "$CORE_UNLOCK_EFI_BOOTNUM")" == "$EFI_STATE_BOOTNUM" ]] \
        || return 1
    local expected_hash actual_hash
    expected_hash=$(tr -d '\n' < "$CORE_UNLOCK_EFI_IMAGE_HASH")
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash=$(sha256sum "$CORE_UNLOCK_EFI_MASTER" | awk '{print $1}')
    [[ "$actual_hash" == "$expected_hash" ]] || return 1
    efi_read_boot_listing || return 1
    efi_boot_entry_matches_in "$EFI_STATE_BOOTNUM" 1 "$EFI_BOOT_LISTING" || return 1
    [[ "$(efi_boot_order_first_in "$EFI_BOOT_LISTING")" == "$EFI_STATE_BOOTNUM" \
        && "$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")" == "$EFI_STATE_BOOTNUM" ]]
}

# Authoritative persistence state. Support files left by a one-time test do not
# select a mode; enabled systemd replay and the complete EFI transaction do.
core_unlock_mode() {
    local systemd_active=0 efi_any=0 efi_complete=0
    core_unlock_service_enabled && systemd_active=1
    efi_artifacts_present && efi_any=1
    [[ $efi_any -eq 0 ]] || { efi_configuration_complete && efi_complete=1 || true; }
    if [[ $systemd_active -eq 1 && $efi_any -eq 1 ]]; then
        echo conflict
    elif [[ $efi_any -eq 1 && $efi_complete -eq 0 ]]; then
        echo partial
    elif [[ $efi_complete -eq 1 ]]; then
        echo efi
    elif [[ $systemd_active -eq 1 ]]; then
        echo systemd
    else
        echo none
    fi
}

core_unlock_require_no_efi() {
    local action="$1" mode
    mode=$(core_unlock_mode)
    case "$mode" in
        efi) die "$action and the EFI pre-boot method are mutually exclusive; run '$0 cpu-unlock off' first." ;;
        partial) die "$action is blocked by partial EFI core-unlock state; run '$0 cpu-unlock off' to remove toolkit-owned artifacts." ;;
        conflict) die "$action is blocked by conflicting standard Linux and EFI pre-boot methods; run '$0 cpu-unlock off'." ;;
    esac
}

power_is_installed() {
    other_power_payload_is_installed || [[ -e "$POWER_KEEP_FILE" ]] \
        || [[ -e "$CORE_UNLOCK_UNIT" || -e "$CORE_UNLOCK_BIN" \
            || -e "$CORE_UNLOCK_LICENSE" || -e "$CORE_UNLOCK_PENDING" \
            || -L "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC" ]] \
        || efi_artifacts_present
}

cmd_installed() {
    if power_is_installed; then
        printf '%s\n' installed
        return 0
    fi
    printf '%s\n' not-installed
    return 1
}

remove_power_unit() {
    local unit="$1" rc=0
    rm -f "$unit" "$unit.d/10-bc250-storage.conf" || rc=$?
    rmdir "$unit.d" 2>/dev/null || true
    return "$rc"
}

remove_acpi_boot_override() {
    local regenerated=0
    if [[ ! -e "$GRUB_ACPI_DEFAULT" && ! -e "$CPIO_BOOT" \
        && ! -e "$HEAL_UNIT" && ! -e "$CPUFREQ_UNIT" ]] \
        && ! grep -q 'acpi_override.cpio' "$GRUB_CFG" 2>/dev/null; then
        return 0
    fi
    rm -f "$ACPI_READY" "$GRUB_ACPI_DEFAULT"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub && regenerated=1
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o "$GRUB_CFG" && regenerated=1
    else
        warn "No GRUB configuration generator found; retaining $CPIO_BOOT for boot safety."
    fi

    if [[ $regenerated -eq 1 ]] && ! grep -q 'acpi_override.cpio' "$GRUB_CFG" 2>/dev/null; then
        rm -f "$CPIO_BOOT"
        log "Removed the ACPI override from the next boot."
        return 0
    fi
    if [[ -f "$CPIO_BOOT" ]]; then
        warn "$CPIO_BOOT was retained because GRUB rollback could not be verified."
        warn "The next boot remains safe, but may still load the ACPI override."
    fi
    mkdir -p "${GRUB_ACPI_DEFAULT%/*}"
    printf '%s\n' 'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' \
        > "$GRUB_ACPI_DEFAULT"
    return 1
}

reset_cpu_stock_live() {
    local rc=0
    [[ -d "$OC_DIR/bc250_smu" ]] || return 1
    pause_governor
    PYTHONPATH="$OC_DIR" python3 - << 'EOF' || rc=$?
from bc250_smu import Bc250Smu
smu = Bc250Smu(use_flock=True)
smu.check_test_message()
smu.q3_0x8f_set_max_cpu_boost_clk(3500)
smu.q3_0x50_scale_f_vid_curve(0)
smu.disable_extra_cpu_gpu_voltage(False)
smu.q3_0x8b_set_cpu_max_temperature(100)
smu.q3_0x8c_set_gpu_max_temperature(100)
print("CPU restored to stock: 3500 MHz, factory vid curve, 100 C limits")
EOF
    resume_governor || rc=$?
    return "$rc"
}

cmd_uninstall() {
    require_root
    local acpi_reverted=0 cpu_reverted=0

    core_unlock_lifecycle_lock || return $?
    if [[ -e "$CORE_UNLOCK_UNIT" || -e "$CORE_UNLOCK_BIN" \
        || -e "$CORE_UNLOCK_PENDING" || -L "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC" ]]; then
        core_unlock_operation_lock || return $?
        if core_unlock_auto_attempt_this_boot; then
            warn "A core-unlock automatic attempt/reboot is already in progress."
            warn "Refusing removal until the next boot so a queued reboot cannot be misreported."
            return 1
        fi
    fi
    remove_core_unlock_efi

    if reset_cpu_stock_live; then
        cpu_reverted=1
        log "CPU overclock/undervolt reverted to stock live."
    elif [[ -e "$OC_UNIT" || -e "$OC_CONF" ]]; then
        warn "CPU stock reset was unavailable; reboot will reset the SMU safely."
    fi

    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        if [[ -x "$PERF_BIN" ]]; then
            "$PERF_BIN" --off >/dev/null 2>&1 \
                || warn "Could not clear GPU performance mode before stopping the governor."
        else
            busctl --system set-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" \
                Enabled b false >/dev/null 2>&1 \
                || warn "Could not clear GPU performance mode before stopping the governor."
        fi
    fi
    local service
    systemctl disable --now "$RESTORE_SVC" "$GOV_SVC" "$OC_SVC" "$CORE_UNLOCK_SVC" \
        bc250-acpi-heal.service bc250-cpufreq.service >/dev/null 2>&1 || true
    for service in "$RESTORE_SVC" "$GOV_SVC" "$OC_SVC" "$CORE_UNLOCK_SVC" \
        bc250-acpi-heal.service bc250-cpufreq.service; do
        if systemctl is-active --quiet "$service"; then
            warn "Could not stop $service; refusing to remove its files."
            return 1
        fi
    done

    unlock_rootfs
    trap relock_rootfs EXIT
    acpi_lifecycle_lock || return $?
    remove_acpi_boot_override && acpi_reverted=1 || true
    if [[ -e "$CPU_MITIGATIONS_CONFIG" || -L "$CPU_MITIGATIONS_CONFIG" ]]; then
        cpu_mitigations_set enabled
    fi

    if [[ $acpi_reverted -eq 1 ]]; then
        remove_power_unit "$HEAL_UNIT"
        remove_power_unit "$CPUFREQ_UNIT"
        rm -f "$SYSTEMD_WANTS_DIR/bc250-acpi-heal.service" \
            "$SYSTEMD_WANTS_DIR/bc250-cpufreq.service"
        rm -f "$HEAL_HELPER" "$LEGACY_HEAL_HELPER"
    else
        systemctl enable bc250-acpi-heal.service bc250-cpufreq.service \
            >/dev/null 2>&1 || true
    fi
    remove_power_unit "$GOV_UNIT"
    remove_power_unit "$RESTORE_UNIT"
    remove_power_unit "$OC_UNIT"
    remove_power_unit "$CORE_UNLOCK_UNIT"
    rm -f "$SYSTEMD_WANTS_DIR/$GOV_SVC" "$SYSTEMD_WANTS_DIR/$RESTORE_SVC" \
        "$SYSTEMD_WANTS_DIR/$OC_SVC" "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC"
    rm -f "$DBUS_POLICY"
    rm -f "$GOV_BIN" "$PERF_BIN" "$RESTORE_BIN"
    rm -f "$CORE_UNLOCK_BIN" "$CORE_UNLOCK_LICENSE" "$CORE_UNLOCK_PENDING"
    rmdir "$CORE_UNLOCK_STATE_DIR" "$ROOT_DATA_DIR/licenses" 2>/dev/null || true
    rm -f "$OC_DIR/bc250_apply.py" "$OC_DIR/bc250_detect.py" \
        "$OC_DIR/bc250_limits.py" "$OC_DIR/stress_helper.py"
    rm -rf "$OC_DIR/bc250_smu" "$OC_DIR/__pycache__"
    systemctl daemon-reload
    busctl call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
    relock_rootfs
    trap - EXIT
    [[ $acpi_reverted -eq 0 ]] || remove_update_persistence
    acpi_lifecycle_unlock

    log "Power governor/OC/core-unlock services, executables, and D-Bus policy removed."
    if [[ $acpi_reverted -eq 1 ]]; then
        log "ACPI services and power update keep list removed."
    else
        warn "ACPI self-heal and its update keep list were retained for boot safety."
    fi
    log "Preserved governor/OC settings, saved frequency state, and persistent ACPI data."
    [[ $cpu_reverted -eq 1 ]] || warn "CPU overclock settings are guaranteed stock only after reboot."
    if [[ $acpi_reverted -eq 1 ]]; then
        warn "REBOOT REQUIRED to unload active ACPI tables and reset normal SMU tuning."
        warn "A full power-off is required to restore the firmware's six-core mask."
        warn "After power-off, CPU behavior is stock and the custom services stay disabled."
    else
        warn "REBOOT REQUIRED, but ACPI boot rollback needs attention before stock behavior is guaranteed."
        warn "Remove any remaining acpi_override.cpio GRUB reference, regenerate $GRUB_CFG, then reboot."
        return 1
    fi
}

# ============================ CPU core unlock =============================
# The SMU write changes what AGESA sees on the next boot. Linux and initramfs
# start too late to affect the current enumeration, so a cold boot needs one
# guarded automatic warm reboot before all eight cores are available.

core_unlock_topology() {
    [[ -f "$TOPOLOGY_SH" && ! -L "$TOPOLOGY_SH" ]] \
        || die "CPU topology helper missing or unsafe: $TOPOLOGY_SH"
    bash "$TOPOLOGY_SH"
}

core_unlock_metrics_state() {
    local rel module marker expected actual resolved
    rel=$(uname -r)
    module="$AMDGPU_MODULES_ROOT/$rel/updates/amdgpu.ko.zst"
    marker="$AMDGPU_MODULES_ROOT/$rel/updates/.bc250-metrics-fix"

    if [[ -f "$marker" && ! -L "$marker" && -f "$module" && ! -L "$module" ]]; then
        read -r expected < "$marker" || expected=
        actual=$(sha256sum "$module" 2>/dev/null | awk '{print $1}')
        resolved=$(modinfo -k "$rel" -F filename amdgpu 2>/dev/null || true)
        if [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" \
            && "$resolved" == */updates/amdgpu.ko* ]]; then
            echo compatible
            return 0
        fi
        echo invalid
        return 1
    fi
    if [[ -f "$module" && ! -L "$module" ]]; then
        echo legacy-override
    else
        echo not-installed
    fi
    return 1
}

install_core_unlock_files() {
    migrate_legacy_data || return $?
    [[ -f "$CORE_UNLOCK_SOURCE" && ! -L "$CORE_UNLOCK_SOURCE" ]] \
        || die "Core-unlock helper missing or unsafe: $CORE_UNLOCK_SOURCE"
    [[ -f "$CORE_UNLOCK_LICENSE_SOURCE" && ! -L "$CORE_UNLOCK_LICENSE_SOURCE" ]] \
        || die "Core-unlock MIT license missing or unsafe: $CORE_UNLOCK_LICENSE_SOURCE"
    install -d -o root -g root -m 0755 "$ROOT_DATA_DIR/helper" \
        "$ROOT_DATA_DIR/licenses" "$CORE_UNLOCK_STATE_DIR" \
        || die "Could not create core-unlock directories."
    install -o root -g root -m 0755 "$CORE_UNLOCK_SOURCE" "$CORE_UNLOCK_BIN" \
        || die "Could not install the core-unlock helper."
    install -o root -g root -m 0644 "$CORE_UNLOCK_LICENSE_SOURCE" "$CORE_UNLOCK_LICENSE" \
        || die "Could not install the core-unlock license."
}

core_unlock_secure_boot_disabled() {
    local state
    command -v mokutil >/dev/null 2>&1 \
        || die "mokutil is required to determine Secure Boot state."
    state=$(LC_ALL=C mokutil --sb-state 2>&1 || true)
    case "${state,,}" in
        *"secureboot disabled"*|*"secure boot disabled"*|*"this system doesn't support secure boot"*)
            return 0 ;;
        *"secureboot enabled"*|*"secure boot enabled"*)
            die "Secure Boot is enabled; the EFI helper is unsigned and cannot be installed." ;;
        *) die "Secure Boot state is unknown; refusing to install an unsigned EFI helper: ${state:-no result}" ;;
    esac
}

ensure_core_unlock_efi_tools() {
    local packages=()
    command -v clang >/dev/null 2>&1 || packages+=(clang)
    command -v lld-link >/dev/null 2>&1 || packages+=(lld)
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v file >/dev/null 2>&1 || packages+=(file)
    command -v efibootmgr >/dev/null 2>&1 || packages+=(efibootmgr)
    command -v mokutil >/dev/null 2>&1 || packages+=(mokutil)
    command -v findmnt >/dev/null 2>&1 || packages+=(util-linux)
    command -v lsblk >/dev/null 2>&1 || packages+=(util-linux)
    [[ ${#packages[@]} -gt 0 ]] || return 0
    unlock_rootfs
    prepare_pacman_keyring
    pacman -Sy --noconfirm --needed "${packages[@]}" \
        || die "EFI core-unlock build tools unavailable and pacman install failed."
}

discover_core_unlock_esp() {
    local mount_listing mount_info= line source target fstype options extra
    local block_info name type parent part partuuid parttype partition_ok=0
    local steamos_efi=
    ESP_DISCOVERY_ERROR=
    [[ -d "$CORE_UNLOCK_ESP_ROOT" && ! -L "$CORE_UNLOCK_ESP_ROOT" ]] \
        || { ESP_DISCOVERY_ERROR="EFI system partition mount is missing or unsafe: $CORE_UNLOCK_ESP_ROOT"; return 1; }
    [[ -w "$CORE_UNLOCK_ESP_ROOT" ]] \
        || { ESP_DISCOVERY_ERROR="EFI system partition is not writable: $CORE_UNLOCK_ESP_ROOT"; return 1; }
    mount_listing=$(findmnt -nro SOURCE,TARGET,FSTYPE,OPTIONS --target "$CORE_UNLOCK_ESP_ROOT" 2>/dev/null) \
        || { ESP_DISCOVERY_ERROR="Could not query the EFI system partition mount."; return 1; }
    while IFS= read -r line; do
        read -r source target fstype options extra <<< "$line"
        [[ -z "$extra" && "$target" == "$CORE_UNLOCK_ESP_ROOT" \
            && "${fstype,,}" != autofs ]] || continue
        [[ -z "$mount_info" ]] \
            || { ESP_DISCOVERY_ERROR="$CORE_UNLOCK_ESP_ROOT has multiple concrete mounts."; return 1; }
        mount_info="$line"
    done <<< "$mount_listing"
    [[ -n "$mount_info" ]] \
        || { ESP_DISCOVERY_ERROR="$CORE_UNLOCK_ESP_ROOT is not an actual mountpoint behind its automount."; return 1; }
    read -r source target fstype options extra <<< "$mount_info"
    case "${fstype,,}" in
        vfat|fat|fat32) ;;
        *) ESP_DISCOVERY_ERROR="EFI system partition must use FAT/vfat, not ${fstype:-unknown}."; return 1 ;;
    esac
    [[ ",$options," == *,rw,* ]] \
        || { ESP_DISCOVERY_ERROR="EFI system partition is mounted read-only."; return 1; }
    block_info=$(lsblk -dnpro NAME,TYPE,PKNAME,PARTN,PARTUUID,PARTTYPE "$source" 2>/dev/null) \
        || { ESP_DISCOVERY_ERROR="Could not inspect ESP block identity for $source."; return 1; }
    read -r name type parent part partuuid parttype extra <<< "$block_info"
    case "${parttype,,}" in
        "$CORE_UNLOCK_ESP_PARTTYPE") partition_ok=1 ;;
        "$CORE_UNLOCK_STEAMOS_EFI_PARTTYPE")
            if [[ -L "$CORE_UNLOCK_STEAMOS_EFI_PARTSET" ]]; then
                steamos_efi=$(readlink -f "$CORE_UNLOCK_STEAMOS_EFI_PARTSET" 2>/dev/null || true)
                [[ "$steamos_efi" == "$name" ]] && partition_ok=1
            fi
            ;;
    esac
    [[ -z "$extra" && "$name" == /dev/* && "$type" == part \
        && "$parent" == /dev/* && "$part" =~ ^[1-9][0-9]*$ \
        && "$partuuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ \
        && $partition_ok -eq 1 ]] \
        || { ESP_DISCOVERY_ERROR="Mounted EFI path is not a supported GPT EFI partition."; return 1; }
    CORE_UNLOCK_ESP_SOURCE="$name"
    CORE_UNLOCK_ESP_DISK="$parent"
    CORE_UNLOCK_ESP_PART="$part"
    CORE_UNLOCK_ESP_PARTUUID=${partuuid,,}
}

verify_core_unlock_esp_state() {
    local source="$EFI_STATE_SOURCE" disk="$EFI_STATE_DISK"
    local part="$EFI_STATE_PART" partuuid="$EFI_STATE_PARTUUID"
    discover_core_unlock_esp || return 1
    if [[ "$CORE_UNLOCK_ESP_SOURCE" != "$source" \
        || "$CORE_UNLOCK_ESP_DISK" != "$disk" \
        || "$CORE_UNLOCK_ESP_PART" != "$part" \
        || "$CORE_UNLOCK_ESP_PARTUUID" != "$partuuid" ]]; then
        ESP_DISCOVERY_ERROR="Mounted ESP identity differs from recorded core-unlock ownership state."
        return 1
    fi
}

build_core_unlock_efi() {
    local work head description output
    for output in "$CORE_UNLOCK_EFI_SOURCE" "$CORE_UNLOCK_EFI_LICENSE_SOURCE" \
        "$CORE_UNLOCK_EFI_HEADER_LICENSE_SOURCE"; do
        [[ -f "$output" && ! -L "$output" ]] \
            || die "EFI core-unlock source/license missing or unsafe: $output"
    done
    work=$(mktemp -d /tmp/bc250-core-unlock-efi.XXXXXX)
    TEMP_DIRS+=("$work")
    git -C "$work" init -q
    git -C "$work" remote add origin "$CORE_UNLOCK_EFI_REPO"
    log "Fetching yoppeh/efi @ ${CORE_UNLOCK_EFI_PIN:0:7} (pinned headers only)..."
    git -C "$work" fetch -q --no-tags --depth=1 origin "$CORE_UNLOCK_EFI_PIN" \
        || die "Could not fetch pinned yoppeh/efi headers."
    git -C "$work" checkout -q --detach FETCH_HEAD
    head=$(git -C "$work" rev-parse HEAD)
    [[ "$head" == "$CORE_UNLOCK_EFI_PIN" ]] \
        || die "Fetched EFI header commit mismatch: $head"

    clang -I "$work" -DEFI_PLATFORM=1 -target x86_64-unknown-windows \
        -ffreestanding -mno-red-zone -nostdlib -fuse-ld=lld \
        -Wl,-entry:efi_main -Wl,-subsystem:efi_application \
        -o "$work/bc250-core-unlock.efi" "$CORE_UNLOCK_EFI_SOURCE" \
        || die "Could not compile the EFI core-unlock application."
    description=$(LC_ALL=C file -b "$work/bc250-core-unlock.efi")
    [[ "$description" == *PE32+* \
        && ( "${description,,}" == *"efi application"* \
            || "${description,,}" == *"efi (application)"* ) \
        && "${description,,}" == *"x86-64"* ]] \
        || die "Built image is not an x86-64 PE EFI application: $description"
    CORE_UNLOCK_EFI_BUILD="$work/bc250-core-unlock.efi"
}

core_unlock_efi_enable() {
    require_root
    core_unlock_lifecycle_lock || return $?
    local mode number order state_tmp bootnum_tmp hash_tmp hash
    local master_tmp esp_tmp before_list after_list create_rc=0 candidate matches_list
    local -a new_numbers=()
    local -A before_numbers=()
    mode=$(core_unlock_mode)
    case "$mode" in
        systemd|conflict)
            die "EFI mode and the standard Linux boot method are mutually exclusive; run '$0 cpu-unlock off' first." ;;
        partial)
            if efi_configuration_complete 1; then
                rm -f "$CORE_UNLOCK_EFI_RECOVERY" \
                    || die "Could not finalize the validated EFI core-unlock transaction."
                sync "$CORE_UNLOCK_STATE_DIR"
                log "Validated and finalized the retained EFI core-unlock transaction."
                core_unlock_lifecycle_unlock
                return 0
            fi
            die "EFI mode cannot repair incomplete or invalid partial EFI state; run '$0 cpu-unlock off', then retry." ;;
        efi)
            log "EFI core unlock is already installed and its owned Boot entry is valid."
            core_unlock_lifecycle_unlock
            return 0 ;;
    esac

    install_core_unlock_files || return $?
    BC250_CORE_UNLOCK_STATE_DIR="$CORE_UNLOCK_STATE_DIR" \
        python3 -I "$CORE_UNLOCK_BIN" verify-unlocked || return $?
    ensure_core_unlock_efi_tools
    core_unlock_secure_boot_disabled
    discover_core_unlock_esp || die "$ESP_DISCOVERY_ERROR"
    build_core_unlock_efi
    efi_read_boot_listing \
        || die "Could not read EFI Boot entries before installation."
    matches_list=$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")
    [[ -z "$matches_list" ]] \
        || die "An unrecorded $CORE_UNLOCK_EFI_LABEL Boot entry already exists; refusing to claim or replace it."
    before_list=$(efi_boot_numbers_in "$EFI_BOOT_LISTING")
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] || before_numbers["$candidate"]=1
    done <<< "$before_list"

    install -d -o root -g root -m 0755 "$CORE_UNLOCK_STATE_DIR" \
        "$ROOT_DATA_DIR/licenses" "$CORE_UNLOCK_EFI_DIR"
    EFI_RECOVERY_SOURCE="$CORE_UNLOCK_ESP_SOURCE"
    EFI_RECOVERY_DISK="$CORE_UNLOCK_ESP_DISK"
    EFI_RECOVERY_PART="$CORE_UNLOCK_ESP_PART"
    EFI_RECOVERY_PARTUUID="$CORE_UNLOCK_ESP_PARTUUID"
    EFI_RECOVERY_BEFORE="${before_list//$'\n'/,}"
    EFI_RECOVERY_AFTER=""
    EFI_RECOVERY_CANDIDATE=""
    EFI_RECOVERY_BEFORE_VALID=1
    EFI_RECOVERY_AFTER_VALID=0
    efi_recovery_write
    EFI_TRANSACTION_ACTIVE=1
    master_tmp="$CORE_UNLOCK_STATE_DIR/.bc250-core-unlock.efi.$$"
    esp_tmp="$CORE_UNLOCK_EFI_DIR/.bc250-core-unlock.efi.$$"
    TEMP_FILES+=("$master_tmp" "$esp_tmp")
    install -o root -g root -m 0644 "$CORE_UNLOCK_EFI_BUILD" "$master_tmp"
    mv -f "$master_tmp" "$CORE_UNLOCK_EFI_MASTER"
    sync "$CORE_UNLOCK_EFI_MASTER"
    install -o root -g root -m 0644 "$CORE_UNLOCK_EFI_BUILD" "$esp_tmp"
    sync "$esp_tmp"
    mv -f "$esp_tmp" "$CORE_UNLOCK_EFI_IMAGE"
    sync "$CORE_UNLOCK_EFI_DIR"
    install -o root -g root -m 0644 "$CORE_UNLOCK_EFI_LICENSE_SOURCE" \
        "$CORE_UNLOCK_EFI_LICENSE"
    install -o root -g root -m 0644 "$CORE_UNLOCK_EFI_HEADER_LICENSE_SOURCE" \
        "$CORE_UNLOCK_EFI_HEADER_LICENSE"
    hash=$(sha256sum "$CORE_UNLOCK_EFI_MASTER" | awk '{print $1}')
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "Could not hash the staged EFI image."
    hash_tmp="$CORE_UNLOCK_STATE_DIR/.efi-image.sha256.$$"
    TEMP_FILES+=("$hash_tmp")
    printf '%s\n' "$hash" > "$hash_tmp"
    chmod 0600 "$hash_tmp"
    mv -f "$hash_tmp" "$CORE_UNLOCK_EFI_IMAGE_HASH"
    sync "$CORE_UNLOCK_EFI_IMAGE_HASH"
    sync "$CORE_UNLOCK_STATE_DIR"
    sync "$ROOT_DATA_DIR/licenses"
    efibootmgr --create --disk "$CORE_UNLOCK_ESP_DISK" \
        --part "$CORE_UNLOCK_ESP_PART" --label "$CORE_UNLOCK_EFI_LABEL" \
        --loader "$CORE_UNLOCK_EFI_LOADER" >/dev/null || create_rc=$?
    efi_read_boot_listing \
        || die "Could not snapshot EFI Boot numbers after creating the core-unlock entry."
    after_list=$(efi_boot_numbers_in "$EFI_BOOT_LISTING")
    while IFS= read -r candidate; do
        [[ -z "$candidate" || -n "${before_numbers[$candidate]+owned}" ]] \
            || new_numbers+=("$candidate")
    done <<< "$after_list"
    [[ ${#new_numbers[@]} -eq 1 ]] \
        || die "Could not identify exactly one newly created EFI core-unlock Boot entry."
    number=${new_numbers[0]^^}
    EFI_TRANSACTION_BOOTNUM="$number"
    EFI_RECOVERY_AFTER="${after_list//$'\n'/,}"
    EFI_RECOVERY_AFTER_VALID=1
    EFI_RECOVERY_CANDIDATE="$number"
    efi_recovery_write
    [[ $create_rc -eq 0 ]] \
        || die "efibootmgr reported failure after adding Boot$number; retaining all EFI recovery evidence."
    bootnum_tmp="$CORE_UNLOCK_STATE_DIR/.efi-bootnum.$$"
    TEMP_FILES+=("$bootnum_tmp")
    printf '%s\n' "$number" > "$bootnum_tmp"
    chmod 0600 "$bootnum_tmp"
    mv -f "$bootnum_tmp" "$CORE_UNLOCK_EFI_BOOTNUM"

    state_tmp="$CORE_UNLOCK_STATE_DIR/.efi-state.$$"
    TEMP_FILES+=("$state_tmp")
    printf 'BOOTNUM=%s\nESP_SOURCE=%s\nDISK=%s\nPART=%s\nPARTUUID=%s\nLABEL=%s\nLOADER=%s\n' \
        "$number" "$CORE_UNLOCK_ESP_SOURCE" "$CORE_UNLOCK_ESP_DISK" \
        "$CORE_UNLOCK_ESP_PART" "$CORE_UNLOCK_ESP_PARTUUID" \
        "$CORE_UNLOCK_EFI_LABEL" "$CORE_UNLOCK_EFI_LOADER" > "$state_tmp"
    chmod 0600 "$state_tmp"
    mv -f "$state_tmp" "$CORE_UNLOCK_EFI_STATE"
    sync "$CORE_UNLOCK_EFI_BOOTNUM"
    sync "$CORE_UNLOCK_EFI_STATE"
    sync "$CORE_UNLOCK_STATE_DIR"
    efi_boot_entry_matches_in "$number" 1 "$EFI_BOOT_LISTING" \
        || die "Created Boot$number does not exactly match the expected active label, loader, and ESP identity."
    order=$(efi_boot_order_first_in "$EFI_BOOT_LISTING") \
        || die "Created EFI BootOrder could not be validated."
    [[ "$order" == "$number" ]] \
        || die "Firmware did not place Boot$number first in BootOrder; refusing an ineffective install."
    efi_configuration_complete 1 \
        || die "Installed EFI core-unlock transaction failed final validation."
    EFI_TRANSACTION_ACTIVE=0
    EFI_TRANSACTION_BOOTNUM=""
    rm -f "$CORE_UNLOCK_EFI_RECOVERY" \
        || die "Could not remove EFI transaction recovery state."
    sync "$CORE_UNLOCK_STATE_DIR"
    core_unlock_lifecycle_unlock
    log "Experimental EFI core unlock installed as Boot$number at $CORE_UNLOCK_EFI_IMAGE."
    warn "EFI runs before Linux, but firmware still performs one warm reset after cold power."
}

clear_core_unlock_efi_guard() {
    local guard
    guard=$(core_unlock_efi_guard_path)
    [[ -e "$guard" ]] || return 0
    if command -v chattr >/dev/null 2>&1; then
        chattr -i "$guard" 2>/dev/null || true
    fi
    rm -f "$guard" 2>/dev/null || true
    if [[ -e "$guard" ]]; then
        warn "Could not clear the EFI one-attempt guard at $guard."
        return 1
    fi
}

remove_core_unlock_efi() {
    local number matches
    if ! efi_owned_files_present; then
        if efi_read_boot_listing; then
            [[ -z "$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")" ]] \
                || die "An unrecorded EFI core-unlock entry exists; retaining it for manual ownership review."
        elif efi_guard_present; then
            die "Could not read EFI Boot entries; retaining the one-attempt guard."
        elif [[ -d "$CORE_UNLOCK_EFIVARS_DIR" ]]; then
            die "Could not verify that no EFI core-unlock Boot entry remains."
        fi
        if efi_guard_present; then
            clear_core_unlock_efi_guard \
                || die "EFI guard removal is incomplete; no other core-unlock artifacts were changed."
        fi
        return 0
    fi
    if efi_state_read; then
        number="$EFI_STATE_BOOTNUM"
        verify_core_unlock_esp_state \
            || die "${ESP_DISCOVERY_ERROR:-ESP ownership validation failed}; retaining all EFI files and Boot entries."
    elif efi_recovery_read; then
        verify_core_unlock_recovery_esp_state \
            || die "${ESP_DISCOVERY_ERROR:-ESP recovery validation failed}; retaining all EFI files and Boot entries."
        number=
    else
        die "EFI ownership and recovery state are missing or invalid; retaining all EFI files and Boot entries."
    fi
    efi_read_boot_listing \
        || die "Could not read EFI Boot entries; retaining all EFI files and ownership state."
    if [[ -z "$number" ]]; then
        efi_recovery_resolve_boot_number "$EFI_BOOT_LISTING" \
            || die "Could not identify the transaction-owned EFI Boot entry safely; retaining all evidence."
        number="$EFI_RECOVERY_RESOLVED_BOOTNUM"
    fi
    if [[ -n "$number" ]] && efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING"; then
        efi_boot_entry_matches_in "$number" 0 "$EFI_BOOT_LISTING" \
            || die "Recorded Boot$number has mismatched label, loader, or ESP identity; retaining all evidence."
    fi
    matches=$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")
    if [[ -n "$matches" ]]; then
        [[ -n "$number" && "$matches" == "$number" ]] \
            || die "Duplicate or unowned EFI core-unlock entries exist; retaining all evidence."
    fi
    if [[ -n "$number" ]] && efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING"; then
        efibootmgr --bootnum "$number" --delete-bootnum >/dev/null \
            || die "Could not delete verified owned Boot$number; retaining EFI files and state."
        efi_read_boot_listing \
            || die "Could not verify Boot$number deletion; retaining EFI files and state."
        efi_boot_entry_present_in "$number" "$EFI_BOOT_LISTING" \
            && die "Boot$number still exists; retaining EFI files and state."
        [[ -z "$(efi_matching_boot_numbers_in "$EFI_BOOT_LISTING")" ]] \
            || die "Another EFI core-unlock entry remains; retaining EFI files and state."
    fi
    clear_core_unlock_efi_guard \
        || die "EFI guard removal failed after Boot entry deletion; retaining loader and ownership state."
    rm -f "$CORE_UNLOCK_EFI_STATE" "$CORE_UNLOCK_EFI_BOOTNUM" \
        "$CORE_UNLOCK_EFI_IMAGE_HASH" "$CORE_UNLOCK_EFI_RECOVERY" \
        "$CORE_UNLOCK_EFI_IMAGE" \
        "$CORE_UNLOCK_EFI_MASTER" "$CORE_UNLOCK_EFI_LICENSE" \
        "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
        || die "Could not remove all toolkit-owned EFI core-unlock files."
    rmdir "$CORE_UNLOCK_EFI_DIR" 2>/dev/null || true
}

write_core_unlock_unit() {
    local tmp
    tmp=$(mktemp "${CORE_UNLOCK_UNIT%/*}/.bc250-core-unlock.XXXXXX") \
        || die "Could not stage $CORE_UNLOCK_UNIT"
    cat > "$tmp" << EOF
[Unit]
Description=BC-250 eight-core unlock (rw-r-r-0644 SMU method)
Documentation=https://github.com/rw-r-r-0644/bc250-core-unlock
Requires=$RECOVERY_SVC
After=$RECOVERY_SVC
Before=$OC_SVC $GOV_SVC
RequiresMountsFor=$ROOT_DATA_DIR

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=BC250_CORE_UNLOCK_STATE_DIR=$CORE_UNLOCK_STATE_DIR
ExecStart=/usr/bin/python3 -I $CORE_UNLOCK_BIN boot

[Install]
WantedBy=multi-user.target
EOF
    install -o root -g root -m 0644 "$tmp" "$CORE_UNLOCK_UNIT" \
        || { rm -f "$tmp"; die "Could not install $CORE_UNLOCK_UNIT"; }
    rm -f "$tmp"
}

core_unlock_test() {
    require_root
    core_unlock_lifecycle_lock || return $?
    core_unlock_require_no_efi "One-time Linux core-unlock test"
    if core_unlock_service_enabled; then
        die "Core-unlock persistence is already enabled; run '$0 cpu-unlock off' before a one-time test."
    fi
    install_core_unlock_files || return $?
    pause_governor || return $?
    local rc=0 resume_rc=0
    BC250_CORE_UNLOCK_STATE_DIR="$CORE_UNLOCK_STATE_DIR" \
        python3 -I "$CORE_UNLOCK_BIN" apply || rc=$?
    resume_governor || resume_rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    core_unlock_lifecycle_unlock
    return "$resume_rc"
}

core_unlock_enable() {
    require_root
    core_unlock_lifecycle_lock || return $?
    core_unlock_require_no_efi "The standard Linux boot method"
    install_core_unlock_files || return $?
    BC250_CORE_UNLOCK_STATE_DIR="$CORE_UNLOCK_STATE_DIR" \
        python3 -I "$CORE_UNLOCK_BIN" verify-unlocked || return $?
    write_core_unlock_unit || return $?
    systemctl daemon-reload || return $?
    systemctl enable "$CORE_UNLOCK_SVC" || return $?
    if ! install_update_persistence; then
        systemctl disable "$CORE_UNLOCK_SVC" >/dev/null 2>&1 || true
        if core_unlock_service_enabled; then
            warn "Could not disable $CORE_UNLOCK_SVC after persistence failed; it remains enabled."
        else
            warn "Update persistence failed; disabled $CORE_UNLOCK_SVC for safety."
        fi
        return 1
    fi
    core_unlock_lifecycle_unlock
    log "Eight-core unlock enabled at boot (before CPU OC and the GPU governor)."
    log "Persistence enabled only after verifying this boot already has eight cores."
    if [[ "$(core_unlock_metrics_state)" != compatible ]]; then
        warn "Install the toolkit AMDGPU fixes to correct eight-core GPU metrics: ./bc250-toolkit.sh amdgpu"
    fi
    warn "After later cold boots, the service automatically requests one guarded warm reboot."
}

core_unlock_status() {
    echo -e "${CB}=== CPU core unlock ===${C0}"
    local en ac cores metrics_state mode
    mode=$(core_unlock_mode)
    case "$mode" in
        none)     echo "  automatic unlock: disabled" ;;
        systemd)  echo "  automatic unlock: standard Linux boot method" ;;
        efi)      echo "  automatic unlock: EFI pre-boot method" ;;
        partial)  echo "  automatic unlock: incomplete EFI state (cleanup required)" ;;
        conflict) echo "  automatic unlock: conflicting Linux and EFI methods" ;;
    esac
    case "$mode" in
        efi) echo "  EFI behavior: unlock runs before Linux; cold power still causes one firmware warm reset" ;;
        partial) warn "Partial EFI state blocks test/enable; retry efi-enable to finalize a valid retained transaction, or use 'cpu-unlock off'." ;;
        conflict) warn "Systemd and EFI artifacts conflict; use 'cpu-unlock off' before any enable action." ;;
    esac
    en=$(systemctl is-enabled "$CORE_UNLOCK_SVC" 2>/dev/null) || en=-
    ac=$(systemctl is-active "$CORE_UNLOCK_SVC" 2>/dev/null) || ac=-
    printf '  %-38s %s / %s\n' "$CORE_UNLOCK_SVC" "$(c_state "$en")" "$(c_state "$ac")"
    if [[ -x "$CORE_UNLOCK_BIN" ]]; then
        BC250_CORE_UNLOCK_STATE_DIR="$CORE_UNLOCK_STATE_DIR" \
            python3 -I "$CORE_UNLOCK_BIN" status
    else
        cores=$(awk -F: '/^core id/ { seen[$2]=1 } END { print length(seen) }' /proc/cpuinfo)
        echo "  detected physical cores: ${cores:-unknown}; helper not installed"
    fi
    cores=${cores:-$(awk -F: '/^core id/ { seen[$2]=1 } END { print length(seen) }' /proc/cpuinfo)}
    metrics_state=$(core_unlock_metrics_state) || true
    echo "  AMDGPU telemetry patch: $metrics_state"
    if [[ "$cores" == 8 && "$metrics_state" != compatible ]]; then
        warn "AMDGPU GPU-utilization correction is not installed for this kernel."
        warn "Run './bc250-toolkit.sh amdgpu' as the logged-in user, then reboot."
    fi
}

core_unlock_off() {
    require_root
    core_unlock_lifecycle_lock || return $?
    core_unlock_operation_lock || return $?
    if core_unlock_auto_attempt_this_boot; then
        die "An automatic unlock attempt/reboot is already in progress; wait for the next boot."
    fi
    systemctl disable --now "$CORE_UNLOCK_SVC" 2>/dev/null || true
    if systemctl is-active --quiet "$CORE_UNLOCK_SVC" \
        || core_unlock_service_enabled; then
        die "Could not fully disable $CORE_UNLOCK_SVC; automatic unlock remains enabled."
    fi
    rm -f "$CORE_UNLOCK_PENDING" \
        || die "Could not remove the core-unlock reboot guard."
    remove_core_unlock_efi
    core_unlock_operation_unlock
    core_unlock_lifecycle_unlock
    log "Automatic systemd/EFI core unlock disabled; Linux helper retained."
    warn "A full power-off is required for firmware to restore the six-core mask."
}

core_unlock_uninstall() {
    require_root
    core_unlock_lifecycle_lock || return $?
    core_unlock_operation_lock || return $?
    if core_unlock_auto_attempt_this_boot; then
        die "An automatic unlock attempt/reboot is already in progress; wait for the next boot."
    fi
    remove_core_unlock_efi
    systemctl disable --now "$CORE_UNLOCK_SVC" 2>/dev/null || true
    if systemctl is-active --quiet "$CORE_UNLOCK_SVC" \
        || core_unlock_service_enabled; then
        die "Could not fully disable $CORE_UNLOCK_SVC; refusing to remove its files."
    fi
    remove_power_unit "$CORE_UNLOCK_UNIT" || return $?
    rm -f "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC" "$CORE_UNLOCK_BIN" \
        "$CORE_UNLOCK_LICENSE" "$CORE_UNLOCK_PENDING" \
        "$CORE_UNLOCK_EFI_LICENSE" "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
        || die "Could not remove all core-unlock files."
    [[ ! -e "$CORE_UNLOCK_UNIT" && ! -e "$CORE_UNLOCK_BIN" \
        && ! -e "$CORE_UNLOCK_LICENSE" && ! -e "$CORE_UNLOCK_PENDING" \
        && ! -e "$CORE_UNLOCK_EFI_MASTER" && ! -e "$CORE_UNLOCK_EFI_STATE" \
        && ! -e "$CORE_UNLOCK_EFI_BOOTNUM" \
        && ! -e "$CORE_UNLOCK_EFI_IMAGE_HASH" \
        && ! -e "$CORE_UNLOCK_EFI_IMAGE" \
        && ! -e "$CORE_UNLOCK_EFI_LICENSE" \
        && ! -e "$CORE_UNLOCK_EFI_HEADER_LICENSE" \
        && ! -e "$CORE_UNLOCK_UNIT.d/10-bc250-storage.conf" \
        && ! -L "$SYSTEMD_WANTS_DIR/$CORE_UNLOCK_SVC" ]] \
        || die "Core-unlock files remain; refusing to report a successful uninstall."
    rmdir "$CORE_UNLOCK_STATE_DIR" "$ROOT_DATA_DIR/licenses" 2>/dev/null || true
    systemctl daemon-reload || return $?
    if other_power_payload_is_installed; then
        install_update_persistence || return $?
    else
        remove_update_persistence || return $?
    fi
    core_unlock_operation_unlock
    core_unlock_lifecycle_unlock
    log "CPU core-unlock systemd/EFI artifacts, helper, licenses, and pending state removed."
    warn "A full power-off is required for firmware to restore the six-core mask."
}

cmd_cpu_unlock() {
    local sub="${1:-status}"
    shift || true
    (($# == 0)) || die "Usage: $0 cpu-unlock {menu|topology|status|test|enable|efi-enable|off|uninstall}"
    case "$sub" in
        menu)      menu_cpu_unlock ;;
        topology)  core_unlock_topology ;;
        status)    core_unlock_status ;;
        test)      core_unlock_test ;;
        enable)    core_unlock_enable ;;
        efi-enable) core_unlock_efi_enable ;;
        off)       core_unlock_off ;;
        uninstall) core_unlock_uninstall ;;
        *) die "Usage: $0 cpu-unlock {menu|topology|status|test|enable|efi-enable|off|uninstall}" ;;
    esac
}

# =========================== CPU mitigations ==============================
render_cpu_mitigations_config() {
    cat <<'EOF'
# BC-250 CPU security policy managed by bc250-power.sh.
# Remove with: bc250-power.sh cpu-mitigations enable
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} mitigations=off"
EOF
}

cpu_mitigations_config_owned() {
    [[ -f "$CPU_MITIGATIONS_CONFIG" && ! -L "$CPU_MITIGATIONS_CONFIG" ]] || return 1
    cmp -s "$CPU_MITIGATIONS_CONFIG" <(render_cpu_mitigations_config)
}

foreign_cpu_mitigations_source() {
    local candidate
    for candidate in "$GRUB_DEFAULT" "${CPU_MITIGATIONS_CONFIG%/*}"/*; do
        [[ "$candidate" != "$CPU_MITIGATIONS_CONFIG" && -f "$candidate" && ! -L "$candidate" ]] \
            || continue
        if grep -Eq "(^|[[:space:]\"'])mitigations=" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

cpu_mitigations_configured_state() {
    if foreign_cpu_mitigations_source >/dev/null; then
        printf '%s\n' foreign
    elif [[ -e "$CPU_MITIGATIONS_CONFIG" || -L "$CPU_MITIGATIONS_CONFIG" ]]; then
        if cpu_mitigations_config_owned; then
            if validate_cpu_mitigations_grub "$GRUB_CFG" off; then printf '%s\n' disabled
            else printf '%s\n' incomplete
            fi
        else
            printf '%s\n' foreign
        fi
    else
        if validate_cpu_mitigations_grub "$GRUB_CFG" ""; then printf '%s\n' enabled
        else printf '%s\n' incomplete
        fi
    fi
}

cpu_mitigations_boot_state() {
    local token state=enabled
    [[ -r "$PROC_CMDLINE" ]] || { printf '%s\n' unknown; return; }
    for token in $(< "$PROC_CMDLINE"); do
        [[ "$token" == mitigations=* ]] || continue
        if [[ "$token" == mitigations=off ]]; then state=disabled
        else state=enabled
        fi
    done
    printf '%s\n' "$state"
}

validate_cpu_mitigations_grub() {
    local path=$1 expected=$2
    [[ -f "$path" && ! -L "$path" ]] || return 1
    awk -v expected="$expected" '
        $1 ~ /^linux/ || ($1 == "steamenv_boot" && $2 ~ /^linux/) {
            lines++
            on_line = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^mitigations=/) {
                    on_line++
                    if (expected == "" || $i != "mitigations=" expected)
                        bad = 1
                }
            }
            if ((expected == "" && on_line != 0) || (expected != "" && on_line != 1))
                bad = 1
        }
        END { exit(lines > 0 && !bad ? 0 : 1) }
    ' "$path"
}

preflight_cpu_mitigations() {
    local source
    if [[ -e "$CPU_MITIGATIONS_CONFIG" || -L "$CPU_MITIGATIONS_CONFIG" ]]; then
        cpu_mitigations_config_owned \
            || die "Existing CPU mitigations configuration is not toolkit-owned: $CPU_MITIGATIONS_CONFIG"
    fi
    if source=$(foreign_cpu_mitigations_source); then
        die "Another GRUB source already sets mitigations=: $source"
    fi
    command -v grub-mkconfig >/dev/null 2>&1 \
        || command -v update-grub >/dev/null 2>&1 \
        || die "Neither update-grub nor grub-mkconfig is available."
    if [[ -e "$GRUB_CFG" || -L "$GRUB_CFG" ]]; then
        [[ -f "$GRUB_CFG" && ! -L "$GRUB_CFG" ]] \
            || die "Refusing unsafe generated GRUB path: $GRUB_CFG"
    fi
}

regenerate_cpu_mitigations_grub() {
    local expected=$1 tmp
    mkdir -p "${GRUB_CFG%/*}"
    if command -v grub-mkconfig >/dev/null 2>&1; then
        tmp=$(mktemp "${GRUB_CFG%/*}/.bc250-grub.XXXXXX") || return 1
        if ! grub-mkconfig -o "$tmp" \
            || ! validate_cpu_mitigations_grub "$tmp" "$expected"; then
            rm -f "$tmp"
            return 1
        fi
        chmod 0644 "$tmp"
        mv -f "$tmp" "$GRUB_CFG"
    else
        update-grub || return 1
        validate_cpu_mitigations_grub "$GRUB_CFG" "$expected"
    fi
}

restore_cpu_mitigations_file() {
    local backup=$1 target=$2 tmp
    if [[ -f "$backup" ]]; then
        mkdir -p "${target%/*}"
        tmp=$(mktemp "${target%/*}/.bc250-restore.XXXXXX") || return 1
        cp -p "$backup" "$tmp" || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$target"
    else
        rm -f "$target"
    fi
}

cpu_mitigations_rollback() {
    local rc=0
    [[ $CPU_MITIGATIONS_TRANSACTION_ACTIVE -eq 1 ]] || return 0
    if [[ $CPU_MITIGATIONS_TRANSACTION_HAD_CONFIG -eq 1 ]]; then
        restore_cpu_mitigations_file "$CPU_MITIGATIONS_TRANSACTION_CONFIG_BACKUP" \
            "$CPU_MITIGATIONS_CONFIG" || rc=1
    else
        rm -f "$CPU_MITIGATIONS_CONFIG" || rc=1
    fi
    if [[ $CPU_MITIGATIONS_TRANSACTION_HAD_GRUB -eq 1 ]]; then
        restore_cpu_mitigations_file "$CPU_MITIGATIONS_TRANSACTION_GRUB_BACKUP" \
            "$GRUB_CFG" || rc=1
    else
        rm -f "$GRUB_CFG" || rc=1
    fi
    CPU_MITIGATIONS_TRANSACTION_ACTIVE=0
    [[ $rc -eq 0 ]] || warn "CPU mitigations rollback could not restore every boot file."
    return "$rc"
}

cpu_mitigations_set() {
    require_root
    local requested=$1 expected="" work config_backup grub_backup relock_after=0 unlock_grub_after=0
    [[ "$requested" == enabled || "$requested" == disabled ]] \
        || die "CPU mitigations state must be enabled or disabled."
    if [[ $GRUB_LOCK_HELD -eq 0 ]]; then
        grub_config_lock || die "Could not serialize the GRUB update."
        unlock_grub_after=1
    fi
    preflight_cpu_mitigations
    work=$(mktemp -d /tmp/bc250-cpu-mitigations.XXXXXX)
    TEMP_DIRS+=("$work")
    config_backup="$work/config"; grub_backup="$work/grub.cfg"
    CPU_MITIGATIONS_TRANSACTION_HAD_CONFIG=0
    CPU_MITIGATIONS_TRANSACTION_HAD_GRUB=0
    if [[ -f "$CPU_MITIGATIONS_CONFIG" ]]; then
        cp -p "$CPU_MITIGATIONS_CONFIG" "$config_backup"
        CPU_MITIGATIONS_TRANSACTION_HAD_CONFIG=1
    fi
    if [[ -f "$GRUB_CFG" ]]; then
        cp -p "$GRUB_CFG" "$grub_backup"
        CPU_MITIGATIONS_TRANSACTION_HAD_GRUB=1
    fi
    CPU_MITIGATIONS_TRANSACTION_CONFIG_BACKUP=$config_backup
    CPU_MITIGATIONS_TRANSACTION_GRUB_BACKUP=$grub_backup
    CPU_MITIGATIONS_TRANSACTION_ACTIVE=1
    if [[ $RO_WAS_DISABLED -eq 0 ]]; then unlock_rootfs; relock_after=1; fi
    if [[ "$requested" == disabled ]]; then
        mkdir -p "${CPU_MITIGATIONS_CONFIG%/*}"
        render_cpu_mitigations_config > "$CPU_MITIGATIONS_CONFIG.new.$$"
        chown root:root "$CPU_MITIGATIONS_CONFIG.new.$$"
        chmod 0644 "$CPU_MITIGATIONS_CONFIG.new.$$"
        mv -f "$CPU_MITIGATIONS_CONFIG.new.$$" "$CPU_MITIGATIONS_CONFIG"
        expected=off
    else
        rm -f "$CPU_MITIGATIONS_CONFIG"
    fi
    if ! regenerate_cpu_mitigations_grub "$expected" \
        || { [[ "$requested" != disabled ]] || ! install_update_persistence; }; then
        cpu_mitigations_rollback || true
        die "Could not update CPU mitigations; previous boot configuration restored."
    fi
    CPU_MITIGATIONS_TRANSACTION_ACTIVE=0
    [[ $relock_after -eq 0 ]] || relock_rootfs
    [[ $unlock_grub_after -eq 0 ]] || grub_config_unlock
    log "CPU security mitigations will be $requested after reboot."
}

power_keep_has_cpu_mitigations() {
    local first second
    [[ -f "$POWER_KEEP_FILE" && ! -L "$POWER_KEEP_FILE" ]] || return 1
    IFS= read -r first < "$POWER_KEEP_FILE" || return 1
    IFS= read -r second < <(sed -n '2p' "$POWER_KEEP_FILE") || return 1
    [[ "$first" == '# Toolkit state preserved by SteamOS atomic updates.' \
        && "$second" == '# Generated by bc250-update-persistence.sh.' ]] \
        && grep -Fxq /etc/default/grub.d/bc250-cpu-mitigations.cfg "$POWER_KEEP_FILE"
}

cpu_mitigations_status_json() {
    local configured boot reboot=false protected=false configured_json
    configured=$(cpu_mitigations_configured_state)
    boot=$(cpu_mitigations_boot_state)
    [[ "$configured" == "$boot" || "$configured" == foreign \
        || "$configured" == incomplete || "$boot" == unknown ]] || reboot=true
    power_keep_has_cpu_mitigations && protected=true
    case "$configured" in
        enabled) configured_json=true ;;
        disabled) configured_json=false ;;
        *) configured_json=null ;;
    esac
    printf '{"schemaVersion":1,"available":true,"state":"%s","configuredEnabled":%s,' \
        "$configured" "$configured_json"
    case "$boot" in
        enabled) printf '"bootEnabled":true' ;;
        disabled) printf '"bootEnabled":false' ;;
        *) printf '"bootEnabled":null' ;;
    esac
    printf ',"rebootRequired":%s,"protected":%s}\n' "$reboot" "$protected"
}

cpu_mitigations_status() {
    local configured boot
    configured=$(cpu_mitigations_configured_state)
    boot=$(cpu_mitigations_boot_state)
    echo "CPU security mitigations:"
    printf '  %-22s %s\n' "Configured:" "$configured"
    printf '  %-22s %s%s\n' "Current boot:" "$boot" \
        "$([[ "$configured" != "$boot" && "$configured" != foreign \
            && "$configured" != incomplete && "$boot" != unknown ]] && printf ' (reboot needed)' || true)"
}

cmd_cpu_mitigations() {
    local sub=${1:-status}
    shift || true
    (($# == 0)) || die "Usage: $0 cpu-mitigations {enable|disable|status|status-json}"
    case "$sub" in
        enable) cpu_mitigations_set enabled ;;
        disable) cpu_mitigations_set disabled ;;
        status) cpu_mitigations_status ;;
        status-json) cpu_mitigations_status_json ;;
        *) die "Usage: $0 cpu-mitigations {enable|disable|status|status-json}" ;;
    esac
}

menu_toggle_cpu_mitigations() {
    local configured
    configured=$(cpu_mitigations_configured_state)
    if [[ "$configured" == disabled ]]; then
        run_action cpu_mitigations_set enabled
        return
    fi
    if [[ "$configured" == foreign ]]; then
        run_action cpu_mitigations_status
        return
    fi
    echo
    warn "Disabling CPU mitigations reduces protection against processor security vulnerabilities."
    ask "Type DISABLE to continue" "cancel"
    [[ "$REPLY" == DISABLE ]] || { warn "CPU mitigations unchanged."; return; }
    run_action cpu_mitigations_set disabled
}

# ============================ CPU overclock ===============================
# Wraps bc250-collective/bc250_smu_oc: CPU max boost clock + vid-curve
# undervolt via SMU mailbox messages (queue 3). CPU only -- it never touches
# GPU clocks/voltage, so it coexists with the GPU governor; the only shared
# resource is the SMU indirect window, handled by pause_governor + unit
# ordering. SteamOS-friendly: pure-stdlib python run straight from files
# (no pip/git), sources fetched as a pinned-commit tarball with our patches
# overlaid (see smu-oc-patches/README.md), master copies in the hidden toolkit,
# with the config and unit retained through the atomic-update keep list.

fetch_oc_sources() {
    migrate_legacy_data
    [[ -f "$OC_PATCH_DIR/transport.py" && -f "$OC_PATCH_DIR/stress_helper.py" ]] \
        || die "Patch overlays not found at $OC_PATCH_DIR (should ship next to this script)."
    local work
    work=$(mktemp -d /tmp/bc250-smu-oc.XXXXXX)
    TEMP_DIRS+=("$work")
    log "Fetching bc250_smu_oc @ ${OC_PIN:0:7} (pinned)..."
    curl -fsSL "$OC_TARBALL" | tar -xz -C "$work" --strip-components=1 \
        || die "Fetch failed (network?): $OC_TARBALL"
    log "Overlaying SteamOS patches (transaction flock, no-'stress' fallback)..."
    install -m 644 "$OC_PATCH_DIR/transport.py"     "$work/bc250_smu/transport.py"
    install -m 644 "$OC_PATCH_DIR/stress_helper.py" "$work/stress_helper.py"
    mkdir -p "$OC_DIR/bc250_smu"
    install -m 644 "$work"/bc250_apply.py "$work"/bc250_detect.py \
                   "$work"/bc250_limits.py "$work"/stress_helper.py "$OC_DIR/"
    install -m 644 "$work"/bc250_smu/*.py "$OC_DIR/bc250_smu/"
    python3 -m py_compile "$OC_DIR"/*.py "$OC_DIR"/bc250_smu/*.py \
        || die "Staged sources do not compile -- bad fetch or patch/pin mismatch."
    rm -rf "$work"
    log "Staged -> $OC_DIR"
}

install_oc_files() {
    if [[ ! -f "$OC_DIR/bc250_apply.py" || "${1:-}" == force ]]; then
        fetch_oc_sources
    fi
    grep -q 'lock across the whole pair' "$OC_DIR/bc250_smu/transport.py" \
        || warn "transport.py missing the transaction-flock patch -- SMU races with the governor possible; run '$0 cpu-oc update'."
    grep -q '_burn' "$OC_DIR/stress_helper.py" \
        || warn "stress_helper.py missing the no-'stress' fallback -- 'cpu-oc detect' needs the stress binary; run '$0 cpu-oc update'."
}

# detect prefers the real `stress` tool; pacman packages are wiped by SteamOS
# updates, so this may reinstall later. The python burner fallback in
# stress_helper.py covers a failed/unavailable install either way.
ensure_stress() {
    command -v stress >/dev/null 2>&1 && return 0
    log "Installing 'stress' via pacman (SteamOS updates wipe it; will reinstall then)..."
    unlock_rootfs
    pacman -Sy --noconfirm stress \
        || warn "pacman install failed -- detect will use the python burner fallback."
    relock_rootfs
}

oc_detect() {
    require_root
    local freq="${1:-}" vid="${2:-}" temp="${3:-90}"
    [[ -n "$freq" && -n "$vid" ]] || die "Usage: $0 cpu-oc detect <targetMHz> <vidLimit_mV> [tempC]
Community reference: 4000 1275 (retry at 1300 mV if it crashes).
NEVER above 1325 mV -- exceeding it has bricked boards."
    [[ "$freq" =~ ^[0-9]+$ && "$vid" =~ ^[0-9]+$ && "$temp" =~ ^[0-9]+$ ]] \
        || die "Frequency, voltage, and temperature must be positive integers."
    (( freq >= 3500 && freq <= 4500 )) \
        || die "Target frequency must be between 3500 and 4500 MHz."
    (( vid >= 950 && vid <= 1325 )) \
        || die "VID limit must be between 950 and the hard safety limit of 1325 mV."
    (( temp >= 50 && temp <= 100 )) \
        || die "Temperature limit must be between 50 and 100 C."
    install_oc_files
    ensure_stress
    warn "This stress-steps the CPU in 100 MHz increments and CAN hard-crash"
    warn "the system if pushed too far. Close everything else first."
    warn "The result stays applied afterwards: 'cpu-oc enable' to persist,"
    warn "'cpu-oc off' to revert to stock."
    pause_governor
    # log lives in the tool's own root-owned dir: a fixed /tmp path breaks
    # under fs.protected_regular once any other user has created it, and
    # this way the last detect transcript sticks around for reference
    local rc=0 dlog="$OC_DIR/last-detect.log"
    python3 "$OC_DIR/bc250_detect.py" -f "$freq" -v "$vid" -t "$temp" \
            --keep -c "$OC_STAGE_CONF" 2>&1 | tee "$dlog" || rc=$?
    resume_governor
    [[ $rc -eq 0 ]] || die "Detection failed (rc=$rc)."
    # stamp the measured result into the config (the file only stores the
    # abstract vid-curve scale; the mV number is what humans care about)
    local res
    res=$(grep -oP 'Final Result: \K.*' "$dlog" | tail -1 || true)
    if [[ -n "$res" && -f "$OC_STAGE_CONF" ]]; then
        sed -i '/^# detected/d' "$OC_STAGE_CONF"
        echo "# detected: $res ($(date +%Y-%m-%d))" >> "$OC_STAGE_CONF"
    fi
    log "Detected config -> $OC_STAGE_CONF"
    oc_persist_report
    log "Stability-test now (games / OCCT), watch: grep MHz /proc/cpuinfo"
}

oc_apply() {
    require_root
    install_oc_files
    local conf="$OC_STAGE_CONF"
    [[ -f "$conf" ]] || conf="$OC_CONF"
    [[ -f "$conf" ]] || die "No overclock config -- run '$0 cpu-oc detect' first."
    pause_governor
    python3 "$OC_DIR/bc250_apply.py" --apply "$conf"
    resume_governor
}

oc_enable() {
    require_root
    recover_update_settings
    install_oc_files
    [[ -f "$OC_STAGE_CONF" || -f "$OC_CONF" ]] \
        || die "No overclock config -- run '$0 cpu-oc detect' first."
    if [[ -f "$OC_STAGE_CONF" ]]; then
        cp -f "$OC_STAGE_CONF" "$OC_CONF"
        log "Config -> $OC_CONF"
    fi
    cat > "$OC_UNIT" << EOF
[Unit]
Description=BC-250 CPU overclock/undervolt (bc250_smu_oc, SMU)
# strictly before the GPU governor: both drive the same SMU indirect window
Requires=$RECOVERY_SVC
After=$RECOVERY_SVC
Before=$GOV_SVC
RequiresMountsFor=$ROOT_DATA_DIR

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 $OC_DIR/bc250_apply.py --apply $OC_CONF

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$OC_SVC"
    install_update_persistence
    log "CPU OC enabled at boot (ordered before the GPU governor)."
    oc_apply
}

oc_off() {
    require_root
    systemctl disable --now "$OC_SVC" 2>/dev/null || true
    install_oc_files
    if [[ -d "$OC_DIR/bc250_smu" ]]; then
        reset_cpu_stock_live || die "Could not restore stock CPU SMU settings."
    fi
    log "CPU OC disabled at boot and reverted to stock. Config kept --"
    log "re-activate any time with '$0 cpu-oc enable'."
}

# staged (fresh detect) vs installed boot config, comments ignored
oc_confs_match() {
    [[ -f "$OC_STAGE_CONF" && -f "$OC_CONF" ]] || return 1
    cmp -s <(grep -E '^[a-z]' "$OC_STAGE_CONF") <(grep -E '^[a-z]' "$OC_CONF")
}

# persistence state token: none | saved | stale | live
oc_persist_state() {
    local enabled=0
    [[ "$(systemctl is-enabled "$OC_SVC" 2>/dev/null)" == enabled ]] && enabled=1
    if [[ ! -f "$OC_STAGE_CONF" && ! -f "$OC_CONF" ]]; then echo none
    elif [[ $enabled -eq 0 ]]; then echo live
    elif [[ ! -f "$OC_STAGE_CONF" ]] || oc_confs_match; then echo saved
    else echo stale
    fi
}

# one-line verdict on whether the current OC settings survive a reboot
oc_persist_report() {
    case "$(oc_persist_state)" in
        none)  ;;
        saved) log "Saved: this config is enabled and reapplies at every boot." ;;
        stale) warn "NOT saved: the boot config is OLDER than this detect result."
               warn "Run '$0 cpu-oc enable' to save the new settings." ;;
        live)  warn "NOT saved: applied live only -- a reboot reverts to stock."
               warn "Run '$0 cpu-oc enable' to keep it." ;;
    esac
}

oc_detected_result() {   # "3800 MHz @ 1176 mV" from a conf's detect stamp
    if [[ -f "${1:-}" ]]; then
        grep -oP '^# detected: \K[0-9]+ MHz @ [0-9]+ mV' "$1" | tail -1 || true
    fi
    return 0
}

oc_live_mv() {   # current CPU voltage over SMU; needs root + staged tool
    [[ $EUID -eq 0 && -f "$OC_DIR/bc250_smu/api.py" ]] || return 1
    PYTHONPATH="$OC_DIR" python3 - << 'EOF' 2>/dev/null
from bc250_smu import Bc250Smu
print(Bc250Smu(use_flock=True).q3_0x36_get_current_cpu_voltage())
EOF
}

oc_status() {
    echo -e "${CB}=== CPU OC (bc250_smu_oc) ===${C0}"
    local en ac
    en=$(systemctl is-enabled "$OC_SVC" 2>/dev/null) || en=-
    ac=$(systemctl is-active "$OC_SVC" 2>/dev/null) || ac=-
    printf '  %-38s %s / %s\n' "$OC_SVC" "$(c_state "$en")" "$(c_state "$ac")"
    if [[ -f "$OC_CONF" ]]; then
        echo "  boot config ($OC_CONF):"
        sed 's/^/    /' "$OC_CONF"
        if [[ -f "$OC_STAGE_CONF" ]] && ! oc_confs_match; then
            echo "  newer detect result, not yet enabled ($OC_STAGE_CONF):"
            sed 's/^/    /' "$OC_STAGE_CONF"
        fi
    elif [[ -f "$OC_STAGE_CONF" ]]; then
        echo "  detected config, not yet enabled ($OC_STAGE_CONF):"
        sed 's/^/    /' "$OC_STAGE_CONF"
    else
        echo "  no config -- start with: sudo $0 cpu-oc detect 4000 1275"
    fi
    local live
    if live=$(oc_live_mv) && [[ -n "$live" ]]; then
        echo "  live CPU voltage: ${live} mV (idle unless loaded)"
    fi
    oc_persist_report
    echo "  effective clocks: watch -n1 'grep MHz /proc/cpuinfo'"
}

cmd_cpu_oc() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        detect)  oc_detect "$@" ;;
        apply)   oc_apply ;;
        enable)  oc_enable ;;
        off)     oc_off ;;
        status)  oc_status ;;
        update)  require_root; install_oc_files force ;;
        *) die "Usage: $0 cpu-oc {detect <MHz> <mV> [tempC] | enable | apply | off | status | update}" ;;
    esac
}

cmd_status() {
    echo -e "${CB}=== Services ===${C0}"
    local s en ac
    for s in "$RECOVERY_SVC" bc250-cu-live-manager "$CORE_UNLOCK_SVC" "$GOV_SVC" bc250-acpi-heal bc250-cpufreq "$RESTORE_SVC" "$OC_SVC"; do
        en=$(systemctl is-enabled "$s" 2>/dev/null) || en=-
        ac=$(systemctl is-active "$s" 2>/dev/null) || ac=-
        printf '  %-38s %s / %s\n' "$s" "$(c_state "$en")" "$(c_state "$ac")"
    done
    echo
    echo "=== GPU ==="
    if [[ -f "$FREQ_STATE" ]]; then
        echo "  saved freq setting (reapplied at boot): $(tr '\n' ' ' < "$FREQ_STATE")"
    else
        echo "  no saved freq setting -- config defaults apply at boot"
    fi
    local configured_max initial_max current_max
    configured_max=$(toml_get frequency-range max)
    initial_max=$(busctl --system get-property "$BUS_NAME" \
        "$BUS_PATH/Range/Initial" com.cyanskillfish.Governor.Range Max \
        2>/dev/null | awk '{print $2}' || true)
    current_max=$(busctl --system get-property "$BUS_NAME" \
        "$BUS_PATH/Range/Current" com.cyanskillfish.Governor.Range Max \
        2>/dev/null | awk '{print $2}' || true)
    echo "  max MHz: config=${configured_max:--} initial=${initial_max:--} current=${current_max:--}"
    cat /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null || echo "  pp_dpm_sclk not exposed"
    echo
    echo "=== CPU (ACPI fix active if these exist) ==="
    cpu_mitigations_status
    if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then
        echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
        echo "  current:  $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) kHz"
        local state states=""
        for state in /sys/devices/system/cpu/cpu0/cpuidle/*; do
            [[ -e "$state" ]] && states+="${state##*/} "
        done
        echo "  c-states: $states"
    else
        echo "  cpufreq absent -- ACPI override not active (not installed, or reboot pending)"
    fi
    echo
    sensors 2>/dev/null | grep -E 'edge|junction|PPT|Tctl|power' || true
}

# ============================ guided menu =================================
menu_voltage_point() {
    local old_frequency="$1" old_voltage="$2"
    local items=(
        "Edit point||Change this point's frequency and voltage in one transaction."
        "Remove point||Delete this point; at least two points must remain."
    )
    menu_select "Curve point: $old_frequency MHz @ $old_voltage mV" "${items[@]}" || return 0
    case $MENU_CHOICE in
        0) ask "Frequency MHz ($GPU_FREQ_MIN-$GPU_FREQ_MAX)" "$old_frequency"; local frequency="$REPLY"
           ask "Voltage mV ($VOLT_MIN-$VOLT_MAX)" "$old_voltage"
           run_action volt_edit "$old_frequency" "$frequency" "$REPLY" ;;
        1) ask "Type REMOVE to delete the $old_frequency MHz point" "cancel"
           if [[ "$REPLY" == REMOVE ]]; then
               run_action volt_remove "$old_frequency"
           fi ;;
    esac
}

menu_voltage_curve() {
    while true; do
        local output row frequency voltage index count action
        local rows=() items=()
        if ! output=$(volt_points); then
            run_action volt_show
            return 0
        fi
        mapfile -t rows <<< "$output"
        count=${#rows[@]}
        for index in "${!rows[@]}"; do
            row="${rows[$index]}"
            read -r frequency voltage <<< "$row"
            local badge=""
            if (( index == 0 )); then badge="$(b_mid "floor")"
            elif (( index == count - 1 )); then badge="$(b_mid "ceiling")"; fi
            items+=("$frequency MHz @ $voltage mV|$badge|Select to edit or remove this point.")
        done
        items+=(
            "Add curve point||Insert a sorted frequency/voltage point."
            "Offset whole curve||Shift every voltage by the same signed mV amount."
            "Reset tuned defaults||Restore the 300-2150 MHz, 700-1000 mV default curve."
        )
        menu_select "GPU frequency / voltage curve  ${CD}(atomic + rollback protected)${C0}" "${items[@]}" || return 0
        if (( MENU_CHOICE < count )); then
            read -r frequency voltage <<< "${rows[$MENU_CHOICE]}"
            menu_voltage_point "$frequency" "$voltage"
            continue
        fi
        action=$((MENU_CHOICE - count))
        case $action in
            0) ask "New frequency MHz ($GPU_FREQ_MIN-$GPU_FREQ_MAX)" "1200"; frequency="$REPLY"
               ask "Voltage mV ($VOLT_MIN-$VOLT_MAX)" "850"
               run_action volt_add "$frequency" "$REPLY" ;;
            1) ask "Offset mV (negative = undervolt)" "-15"
               run_action volt_offset "$REPLY" ;;
            2) run_action volt_reset ;;
        esac
    done
}

menu_freq() {
    while true; do
        local items=(
            "Show current state|$(badge_freq)|Ask the governor for its performance-mode status."
            "Adaptive (auto)||Back to config defaults; clears the saved boot setting."
            "Set max cap||Raise/lower the ceiling, keep adaptive scaling + idle savings."
            "Set min + max range||Floor AND ceiling, adaptive in between."
            "Pin a frequency||Fixed clock, perf mode ON -- no idle downscale. For testing."
            "Max performance||Top of the voltage curve until you switch back to auto."
            "Edit frequency / voltage curve||List, add, edit, remove, offset, or reset safe-points transactionally."
        )
        menu_select "GPU frequency & voltage  ${CD}(persists across reboots)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action cmd_freq status ;;
            1) run_action cmd_freq auto ;;
            2) ask "Max MHz ($GPU_FREQ_MIN-$GPU_FREQ_MAX, 1500 = tuned default)" "2000"
               run_action cmd_freq 0 "$REPLY" ;;
            3) ask "Min MHz ($GPU_FREQ_MIN-$GPU_FREQ_MAX)" "1200"; local mn="$REPLY"
               ask "Max MHz" "1800"
               run_action cmd_freq "$mn" "$REPLY" ;;
            4) ask "Pin at MHz" "1800"
               run_action cmd_freq "$REPLY" ;;
            5) run_action cmd_freq max ;;
            6) menu_voltage_curve ;;
        esac
    done
}

menu_load_target() {
    while true; do
        local items=(
            "Show load targets|$(badge_load_target)|Config + live values, and what upper/lower mean."
            "Eager preset (0.40 / 0.10)||Light-load games clock up off idle. Fixes 'stuck at low clocks'."
            "Tuned default (0.80 / 0.65)||Install default: full ramps under real load, best idle savings."
            "Custom values||Set your own thresholds (percent or fraction)."
        )
        menu_select "GPU load targets  ${CD}(when the governor clocks up/down)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action lt_show ;;
            1) run_action lt_set "$LT_EAGER_UPPER" "$LT_EAGER_LOWER" ;;
            2) run_action lt_set "$LT_DEF_UPPER" "$LT_DEF_LOWER" ;;
            3) ask "Upper -- clock UP above this GPU busy% (10-99)" "60"; local u="$REPLY"
               ask "Lower -- step DOWN below this GPU busy%" "45"
               run_action lt_set "$u" "$REPLY" ;;
        esac
    done
}

menu_ramp() {
    while true; do
        local items=(
            "Show ramp behavior|$(badge_ramp)|Step size, climb time, downhold + hunting verdict from the config."
            "Responsive (climb in 500 ms)||Smoothest hunting-free step for a half-second idle-to-max climb."
            "Relaxed (climb in 1000 ms)||Install-default speed, but finer steps derived for smoothness."
            "Custom climb time||You pick idle-to-max ms; step, interval, down-events are derived."
            "Reset install defaults||200 MHz steps every 200 ms, 1 s hold before downscaling."
        )
        menu_select "GPU ramp behavior  ${CD}(how fast + how granular clocks move)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action ramp_show ;;
            1) run_action ramp_set 500 ;;
            2) run_action ramp_set 1000 ;;
            3) ask "Idle-to-max climb time ms (200-5000)" "500"
               run_action ramp_set "$REPLY" ;;
            4) run_action ramp_reset ;;
        esac
    done
}

menu_cpu_oc() {
    while true; do
        local items=(
            "Show OC status|$(badge_oc_live)|Full report: configs, measured + live mV, saved verdict."
            "Detect stable overclock|$(badge_oc_last)|Guided stress-stepped search. Start here. CAN hard-crash if pushed."
            "Enable at boot|$(badge_oc_saved)|Persist the detected config; applies before the GPU governor."
            "Apply now||Re-apply the saved config immediately."
            "Revert to stock||Disable at boot + back to 3500 MHz / factory curve now."
            "Update tool sources||Re-fetch bc250_smu_oc (pinned commit + our patches)."
        )
        menu_select "CPU overclock / undervolt  ${CD}(bc250_smu_oc)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action oc_status ;;
            1) echo
               echo -e "  ${CR}${CB}Vid limit is the safety-critical number. NEVER above 1325 mV --${C0}"
               echo -e "  ${CR}${CB}exceeding it has bricked boards. 1275 is the community reference;${C0}"
               echo -e "  ${CR}${CB}pure undervolt: target 3500 MHz with a 1000 mV limit.${C0}"
               echo
               ask "Target frequency MHz" "4000"; local f="$REPLY"
               ask "Vid limit mV (max 1325)" "1275"; local v="$REPLY"
               ask "Temp limit C" "90"
               run_action oc_detect "$f" "$v" "$REPLY" ;;
            2) run_action oc_enable ;;
            3) run_action oc_apply ;;
            4) run_action oc_off ;;
            5) run_action install_oc_files force ;;
        esac
    done
}

menu_power_setup() {
    while true; do
        local items=(
            "Step 1 - ACPI fix: CPU idle + scaling|$(badge_acpi)|Install the ACPI override, then reboot before judging CPU idle or scaling."
            "Step 2 - Install and test GPU governor|$(badge_governor)|Test-start adaptive GPU control. Load-test it before enabling boot startup."
            "Step 3 - Enable governor at boot|$(badge_gov_boot)|Only enable after the test-started governor has proved stable under load."
            "Reinstall D-Bus helpers||Repair frequency-control helpers and 'name is not activatable' errors."
        )
        menu_select "Power foundation  ${CD}(complete in order)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action cmd_acpi ;;
            1) run_action cmd_governor ;;
            2) run_action cmd_enable ;;
            3) run_action cmd_helpers ;;
        esac
    done
}

menu_gpu_tuning() {
    while true; do
        local items=(
            "Frequency & voltage|$(badge_freq)|Set adaptive caps, ranges, pinned clocks, or advanced voltage-curve changes."
            "Load targets|$(badge_load_target)|Choose when the governor clocks up and down."
            "Ramp behavior|$(badge_ramp)|Choose how quickly and granularly GPU clocks move."
        )
        menu_select "GPU performance tuning  ${CD}(governor required)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) menu_freq ;;
            1) menu_load_target ;;
            2) menu_ramp ;;
        esac
    done
}

menu_cpu_tuning() {
    while true; do
        local items=(
            "CPU overclock / undervolt|$(badge_oc)|Detect, apply, persist, or revert a CPU voltage/frequency profile."
            "CPU security mitigations (toggle)|$(badge_cpu_mitigations)|Trade kernel security mitigations for performance. Reboot required."
        )
        menu_select "CPU performance & security  ${CD}(advanced)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) menu_cpu_oc ;;
            1) menu_toggle_cpu_mitigations ;;
        esac
    done
}

menu_cpu_unlock() {
    [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. See '$0 help' for CLI commands."
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root -- setup actions will fail."
        ask "Restart with sudo? [Y/n]" "Y"
        if [[ "$REPLY" =~ ^[Yy] ]]; then exec sudo "$0" cpu-unlock menu; fi
        echo
    fi
    while true; do
        local mode
        mode=$(core_unlock_mode)
        local items=(
            "Status summary|$(badge_core_unlock "$mode")|Show the automatic unlock method, active cores, service state, reboot guard, and telemetry compatibility."
            "Core topology||Display active and unavailable CPU cores grouped by CCX."
            "Setup 1 - Test eight cores once||Write the volatile mask only. Manually reboot, stress-test, then return here."
            "Setup 2 - Standard Linux boot method||Recommended. Applies after Linux boots. Choose this OR EFI; they cannot be enabled together."
            "Setup 2 - EFI pre-boot method||Alternative. Applies before Linux to avoid an extra Linux boot. Choose this OR standard; they cannot be enabled together."
            "Disable automatic unlock (keep helper)|$(badge_core_unlock "$mode")|Stop future automatic unlock; retain the helper for testing or re-enabling."
            "Uninstall all core-unlock files|$(badge_core_unlock_files "$mode")|Disable automatic unlock and remove the helper, units, EFI files, licenses, and guard state."
        )
        menu_select "CPU core unlock  ${CD}(experimental 6c/12t -> 8c/16t: test, then choose one Setup 2 method)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action core_unlock_status ;;
            1) run_action core_unlock_topology ;;
            2) run_action core_unlock_test ;;
            3) run_action core_unlock_enable ;;
            4) run_action core_unlock_efi_enable ;;
            5) run_action core_unlock_off ;;
            6) run_action core_unlock_uninstall ;;
        esac
    done
}

cmd_menu() {
    [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. See '$0 help' for CLI commands."
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root -- setup actions will fail."
        ask "Restart with sudo? [Y/n]" "Y"
        if [[ "$REPLY" =~ ^[Yy] ]]; then exec sudo "$0" menu; fi
        echo
    fi
    while true; do
        local items=(
            "Status overview||Health check of every service, clock and temp. Always safe."
            "Power foundation|${CG}[guided]${C0}|Install ACPI, reboot, test the GPU governor, then enable it at boot."
            "GPU performance tuning|$(badge_freq)|Configure clocks, voltage, load response, and ramp behavior."
            "CPU performance & security|$(badge_oc)|Configure CPU undervolt/overclock and the security-mitigation policy."
            "Full help||The complete manual for every CLI command."
        )
        menu_select "BC-250 power setup  ${CD}(SteamOS)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_action cmd_status ;;
            1) menu_power_setup ;;
            2) menu_gpu_tuning ;;
            3) menu_cpu_tuning ;;
            4) cmd_help; pause_key ;;
        esac
    done
}

cmd_help() {
    cat << 'EOF'
bc250-power.sh -- BC-250 power management for SteamOS
==============================================================
CPU C/P-states via ACPI SSDT override + adaptive GPU governor (SMU).
Toolkit-owned /etc files are registered in SteamOS's atomic-update keep list.
Privileged binaries and state live in root-owned, offloaded /var/lib storage.

GUIDED MENU
  Run with no arguments (or 'menu') in a terminal for an interactive,
  color-coded menu: arrow keys / j k to move, Enter to run, q to back
  out. Shows live install/active state per step and walks the setup
  order. Every menu action is one of the CLI commands below.

SETUP COMMANDS (run once, in this order)
  acpi        Install the ACPI fix: SSDT-CST (CPU idle C-states) and
              SSDT-PST (CPU 800-3200 MHz scaling) loaded via GRUB
              early-initrd. Also installs two boot services:
                bc250-acpi-heal  -- restores the override if a SteamOS
                                    update wipes /boot
                bc250-cpufreq    -- sets the schedutil CPU governor
              REBOOT REQUIRED before it takes effect.

  governor    Install cyan-skillfish-governor-smu (filippor): adaptive
              GPU freq/voltage via SMU firmware calls, no kernel patch.
              Downloads the latest release, writes a tuned config
              (voltage curve from 300 to 2150 MHz, operating cap 1500 MHz,
              thermal throttle 85C), TEST-STARTS the service but does
              not enable it at boot -- verify under load first.

  helpers     (Re)install the perf-mode helper script and the D-Bus
              policy. Fixes 'name is not activatable' errors. Note the
              policy grants BOTH bus names (upstream's shipped policy
              is stale vs its own binary).

  enable      Enable the governor at boot. Run after you've load-tested
              a 'governor' install.

  installed   Noninteractive lifecycle probe. Prints exactly "installed"
              and exits 0 when power integration/payloads are present;
              otherwise prints "not-installed" and exits 1. Preserved
              settings and persistent data do not count as installed.

  uninstall   Stop and disable power services, revert CPU OC live when
              possible, remove automatic CPU core unlock, remove the ACPI
              override from the next boot, and
              remove component-owned units, executables, D-Bus policy, and
              update keep list. Keeps governor/OC tuning, saved frequency
              state, and persistent ACPI source data. A full power-off is
              required to unload active ACPI tables and restore six cores.

  all         acpi + governor in sequence.

CPU OVERCLOCK / UNDERVOLT (bc250-collective/bc250_smu_oc, CPU only)
  cpu-oc detect <MHz> <mV> [tempC]
              Find a stable OC: steps up from 3.5 GHz while scaling the
              vid curve to stay under <mV>. Stress-tests each step -- CAN
              hard-crash if pushed. Community reference: detect 4000 1275.
              HARD LIMIT 1325 mV (higher has bricked boards). Even at
              stock 3500 this nets a ~200 mV undervolt = thermal headroom.
              The GPU governor is paused during the run (shared SMU
              mailbox window) and resumed after. Installs the 'stress'
              load tool via pacman if missing (SteamOS updates wipe it;
              it just reinstalls on the next detect run -- and a python
              burner fallback covers it if pacman fails).
  cpu-oc enable     Persist the detected config: /etc/bc250-smu-oc.conf +
                    boot service ordered BEFORE the GPU governor.
  cpu-oc apply      Re-apply the saved config right now.
  cpu-oc off        Disable at boot + revert to stock live (3500 MHz,
                    factory curve, 100 C). Config is kept for re-enable.
  cpu-oc status     Service state, configs (incl. the measured mV noted
                    by the last detect), live CPU voltage via SMU, and a
                    clear saved / NOT-saved-at-boot verdict.
  cpu-oc update     Re-fetch the tool sources. They come from upstream
                    (bc250-collective/bc250_smu_oc) at a pinned commit
                    with our patches overlaid from smu-oc-patches/ --
                    no local clone, no pip, no git needed. The first
                    detect/apply/enable fetches automatically (network).

CPU SECURITY MITIGATIONS
  cpu-mitigations status
                     Show the configured next-boot state, current-boot state,
                     and whether a reboot is required.
  cpu-mitigations disable
                     Add mitigations=off through a toolkit-owned GRUB drop-in.
                     This may improve performance but reduces protection from
                     processor security vulnerabilities. REBOOT REQUIRED.
  cpu-mitigations enable
                     Remove only the toolkit-owned drop-in and return to secure
                     kernel defaults. REBOOT REQUIRED after a disabled boot.
                     Any mitigations= setting in another GRUB source is treated
                     as foreign and must be resolved manually.

CPU CORE UNLOCK (test before enabling persistence)
  cpu-unlock menu      Open the dedicated guided CPU core-unlock menu.
  cpu-unlock topology  Show active and unavailable CPU cores grouped by CCX.
  cpu-unlock test      Write the fixed 0xff mask ONCE without installing boot
                       persistence. Manually reboot, confirm 8c/16t, then
                       stress-test and check dmesg for hardware errors. If the
                       system is unstable, power off fully to restore six cores.
                       After a successful test, choose exactly ONE automatic
                       unlock method below. The standard Linux and EFI pre-boot
                       methods are mutually exclusive and cannot be enabled
                       together.
  cpu-unlock enable    Only after a successful test: verify this boot already
                       exposes eight physical cores, then enable the STANDARD
                       Linux boot method. It refuses while the system has six
                       cores or the EFI method is configured.
                       On later cold boots the firmware resets to six cores;
                       the service writes the mask and requests ONE guarded
                       warm reboot so AGESA can enumerate 8c/16t. Initramfs
                       cannot avoid this because AGESA runs before Linux.
  cpu-unlock efi-enable
                        ALTERNATIVE to 'enable', not an additional step. Verify
                        eight active cores, build the shipped hardened C source
                        with pinned yoppeh/efi headers, and create an owned BC250
                        Boot entry. It applies the unlock before Linux, avoiding
                        one extra Linux boot, but still performs
                        one firmware warm reset after cold power.
  cpu-unlock status    Show none/systemd/efi/conflict/partial mode, service,
                       physical-core, and reboot-guard state.
  cpu-unlock off       Disable/remove either automatic unlock method but retain
                       the helper for later testing or re-enabling.
  cpu-unlock uninstall Remove all systemd/EFI artifacts, helper, licenses, and
                       guard state. A mismatched recorded EFI entry is never
                       deleted and causes removal to fail safely.
                       Off/uninstall cannot relock live: a full power-off is
                       required to restore the firmware's six-core mask.
               WARNING: disabled cores may be defective. Upstream tested only
               BIOS 3.0/kernel 6.18.40; BIOS 5 is untested. Stress-test and
               check dmesg for hardware errors before relying on them.

EVERYDAY COMMANDS
  status      One-screen health check: all services, GPU DPM level
              table (* = active), CPU cpufreq/C-states (present only if
              the ACPI override loaded this boot), temps and power.

  freq        Live GPU frequency control (through the governor, D-Bus):
    freq              show performance-mode state
    freq 1800         pin at 1800 MHz  (perf mode ON: no idle downscale,
                      remember 'freq auto' when done)
    freq 0 2000       range 0-2000: raises the cap, keeps adaptive
                      scaling and idle savings (0 = no limit)
    freq 1200 1800    floor AND ceiling
    freq max          performance mode at the top of the voltage curve
    freq auto         back to adaptive + config defaults (1500 cap)
              Settings PERSIST across reboots: each set is saved to
              /var/lib/bc250-control/governor/freq-state and the
              bc250-gpu-freq-restore service reapplies it once the
              governor is up. 'freq auto' clears the saved state.
              Thermal throttling (85C) applies no matter what you set.

  gpu-volt    GPU voltage curve control. Edits the governor's safe-points
              (the layer that owns GPU voltage), restarts it, reapplies
              your saved freq setting:
    gpu-volt              show curve + live vddgfx
    gpu-volt offset -25   undervolt the whole curve 25 mV
    gpu-volt set 2000 985 change one point
    gpu-volt add 1200 850 add a sorted point
    gpu-volt edit 1200 1250 875
                          change a point's frequency and voltage
    gpu-volt remove 1250  remove a point (at least two must remain)
    gpu-volt reset        restore the tuned default curve
              Bounds 300-2150 MHz and 700-1050 mV are enforced, with
              sorted unique frequencies and nondecreasing voltages. Updates
              are atomic and rollback config/runtime after reload failure.
              Small steps (10-25 mV) and stress test after -- undervolts
              that boot fine can still crash under load. Changes persist.

  load-target GPU load targets: the busy% band the governor keeps the GPU
              in. It only clocks UP above 'upper' -- frame-capped light
              games can sit below it at idle clocks forever. Values go to
              config.toml (persist) AND apply live via D-Bus (no restart):
    load-target             show config + live values
    load-target eager       0.40/0.10 -- light loads ramp off idle clocks
    load-target reset       0.80/0.65 tuned defaults (best idle savings)
    load-target set 70 55   custom upper/lower (percent or fraction)
              Alternative for single problem games -- per-game floor via
              Steam launch options (see STEAM LAUNCH OPTION below), which
              leaves global idle behavior untouched.

  ramp        GPU ramp behavior: how fast AND how granular clocks move.
              'set' takes ONE number -- idle-to-max climb time in ms --
              and derives the rest for smoothness: climb speed = range/T;
              step capped by the no-hunting bound (busy% ~ 1/freq, so a
              step above f_min x (upper-lower)/upper can oscillate at
              steady load = the notchy feel); interval clamped 50-200 ms;
              down-events scaled to keep a 1 s hold before downscaling.
              Startup-only params -> the governor restarts (saved freq
              setting reapplied automatically):
    ramp                    show step, climb time, hunting verdict
    ramp set 500            idle-to-max in 500 ms, smoothest safe steps
    ramp reset              install defaults (200 MHz / 200 ms, 1 s hold)
              Re-run after changing load-target or the freq range -- the
              derived step depends on both. Burst mode is left alone: 30 ms
              of saturated load still jumps straight to max.

PERMANENT TUNING (config file, not this script)
  /etc/cyan-skillfish-governor-smu/config.toml
    [frequency-range] max = 1500     <- permanent ceiling
    [[safe-points]]                  <- the freq/voltage curve; anything
                                        you want to run must have a
                                        voltage point at or above it
  then: systemctl restart cyan-skillfish-governor-smu

STEAM LAUNCH OPTION (per-game max clocks, auto-restores on exit)
  /var/lib/bc250-control/bin/cyan-skillfish-performance-mode %command%
  /var/lib/bc250-control/bin/cyan-skillfish-performance-mode --range 0 2000 %command%

FILE MAP
  /var/lib/bc250-control/bin/
                               governor + helper binaries   (persists)
  /var/lib/bc250-control/acpi/
                               SSDTs + master override cpio (persists)
  /var/lib/bc250-control/smu-oc/
                               CPU OC tool (fetched @ pinned commit,
                               patched from smu-oc-patches/)
  /var/lib/bc250-control/helper/bc250-unlock-cores
                               modified MIT helper from rw-r-r-0644
  /var/lib/bc250-control/core-unlock/bc250-core-unlock.efi
                               persistent master EFI image + ownership state
  /efi/EFI/bc250/bc250-core-unlock.efi
                               namespaced unsigned EFI boot image
  /etc/bc250-smu-oc.conf       CPU OC config       (atomic-update keep list)
  /etc/default/grub.d/bc250-cpu-mitigations.cfg
                               optional mitigations=off (atomic-update keep list)
  /etc/cyan-skillfish-governor-smu/config.toml     (atomic-update keep list)
  /var/lib/bc250-control/governor/freq-state  last 'freq' setting,
                               replayed at boot by bc250-gpu-freq-restore
  /etc/systemd/system/*.service, /etc/dbus-1/system.d/
                                      retained by atomic-update keep list
  /boot/acpi_override.cpio     WIPED by updates -- bc250-acpi-heal
                               restores it and warns in the journal

RELATED (separate scripts, same family)
  bc250-40cu.sh     the 38/40 CU unlock (umr + live manager)
  bc250-cu-status.sh           read-only CU dispatch report
EOF
}

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    cmd_menu
    exit 0
fi
case "${1:-}" in
    acpi)         cmd_acpi ;;
    governor)     cmd_governor ;;
    helpers)      cmd_helpers ;;
    freq)         shift; cmd_freq "$@" ;;
    gpu-volt)     shift; cmd_gpu_volt "$@" ;;
    load-target)  shift; cmd_load_target "$@" ;;
    ramp)         shift; cmd_ramp "$@" ;;
    cpu-oc)       shift; cmd_cpu_oc "$@" ;;
    cpu-unlock)   shift; cmd_cpu_unlock "$@" ;;
    cpu-mitigations) shift; cmd_cpu_mitigations "$@" ;;
    enable)       cmd_enable ;;
    installed)    (($# == 1)) || die "Usage: $0 installed"; cmd_installed ;;
    uninstall)    (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    status)       cmd_status ;;
    all)          cmd_acpi; cmd_governor ;;
    menu)         cmd_menu ;;
    help|-h|--help) cmd_help ;;
    *) echo "Usage: $0 {acpi|governor|helpers|freq|gpu-volt|load-target|ramp|cpu-oc|cpu-unlock|cpu-mitigations|enable|installed|uninstall|status|all|menu|help}"
       echo "  (no arguments on a terminal opens the guided menu)"
       echo "  freq                 show performance-mode state"
       echo "  freq 1800            pin GPU at 1800 MHz (perf mode)"
       echo "  freq 0 2000          range: no floor, 2000 MHz cap, adaptive"
       echo "  freq auto            back to adaptive + config defaults"
       echo "  freq max             performance mode, full-curve max"
       echo
       echo "Run '$0 help' for the full explanation of every command."
       exit 1 ;;
esac
