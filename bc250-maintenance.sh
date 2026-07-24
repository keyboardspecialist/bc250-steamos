#!/usr/bin/env bash
# Inventory and safely remove BC-250 SteamOS toolkit components.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
POWER_SH="${POWER_SH:-$SCRIPT_DIR/bc250-power.sh}"
COMPUTE_SH="${COMPUTE_SH:-$SCRIPT_DIR/bc250-40cu.sh}"
CEC_SH="${CEC_SH:-$SCRIPT_DIR/bc250-cec.sh}"
STORAGE_SH="${STORAGE_SH:-$SCRIPT_DIR/bc250-storage.sh}"
PERSISTENCE_SH="${PERSISTENCE_SH:-$SCRIPT_DIR/bc250-update-persistence.sh}"
AIC_SH="${AIC_SH:-$SCRIPT_DIR/aic8800/steamdeck-setup.sh}"
RTW89_SH="${RTW89_SH:-$SCRIPT_DIR/rtw89/steamdeck-setup.sh}"
ROOT_DATA_DIR="${ROOT_DATA_DIR:-/var/lib/bc250-control}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
MODPROBE_DIR="${MODPROBE_DIR:-/etc/modprobe.d}"
ATOMIC_KEEP_DIR="${ATOMIC_KEEP_DIR:-/etc/atomic-update.conf.d}"
MODULE_BASE="${MODULE_BASE:-/usr/lib/modules}"
RTW89_DATA_DIR="${RTW89_DATA_DIR:-/home/.steamos/offload/var/lib/rtw89-steamos}"
AUDIO_SH="${AUDIO_SH:-$SCRIPT_DIR/bc250-audio-fix/patch-driver.sh}"
AUDIO_CLEAN_SH="${AUDIO_CLEAN_SH:-$SCRIPT_DIR/bc250-audio-fix/clean.sh}"
DECKY_SH="${DECKY_SH:-$SCRIPT_DIR/decky-plugin/install.sh}"
DESKTOP_SH="${DESKTOP_SH:-$SCRIPT_DIR/desktop-control/install.sh}"

COMPONENTS=(desktop decky cec power compute audio aic rtw89)
UNINSTALL_ORDER=(desktop decky cec power compute audio rtw89 aic)

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0

log() { echo "[bc250-maintenance] $*"; }
die() { echo "[bc250-maintenance] $*" >&2; exit 1; }
require_normal_user() {
    [[ $EUID -ne 0 ]] \
        || die "Run as the logged-in Deck user, not with sudo. This tool requests administrator access when needed."
}
require_script() { [[ -f "$1" && ! -L "$1" ]] || die "Required component script is missing or unsafe: $1"; }

component_label() {
    case "$1" in
        desktop) echo "Plasma desktop control" ;;
        decky) echo "Decky plugin" ;;
        cec) echo "CEC integration" ;;
        power) echo "Power management" ;;
        compute) echo "Compute-unit manager" ;;
        audio) echo "AMDGPU audio fix" ;;
        aic) echo "AIC8800D80 WiFi / Bluetooth (USB)" ;;
        rtw89) echo "Realtek RTW89 WiFi 6/7 (PCIe / USB)" ;;
        storage) echo "Persistent infrastructure" ;;
        *) die "Unknown component: $1" ;;
    esac
}

component_script() {
    case "$1" in
        desktop) echo "$DESKTOP_SH" ;;
        decky) echo "$DECKY_SH" ;;
        cec) echo "$CEC_SH" ;;
        power) echo "$POWER_SH" ;;
        compute) echo "$COMPUTE_SH" ;;
        audio) echo "$AUDIO_SH" ;;
        aic) echo "$AIC_SH" ;;
        rtw89) echo "$RTW89_SH" ;;
        storage) echo "$STORAGE_SH" ;;
        *) die "Unknown component: $1" ;;
    esac
}

component_probe() {
    local component="$1" script
    script=$(component_script "$component")
    require_script "$script"
    case "$component" in
        power|compute|cec) bash "$script" installed >/dev/null 2>&1 ;;
        desktop|decky|audio|aic|rtw89) bash "$script" status >/dev/null 2>&1 ;;
        storage) bash "$script" installed >/dev/null 2>&1 ;;
    esac
}

component_has_artifacts() {
    case "$1" in
        desktop)
            [[ -e /var/lib/bc250-control/desktop \
                || -e /etc/systemd/system/bc250-control.service \
                || -e /etc/systemd/system/bc250-desktop-control-repair.service \
                || -e /etc/dbus-1/system.d/io.github.keyboardspecialist.BC250Control1.conf \
                || -e /usr/share/polkit-1/actions/io.github.keyboardspecialist.bc250-control.policy \
                || -e /etc/atomic-update.conf.d/bc250-desktop.conf \
                || -L /etc/systemd/system/multi-user.target.wants/bc250-control.service \
                || -L /etc/systemd/system/multi-user.target.wants/bc250-desktop-control-repair.service \
                || -e "$HOME/.local/share/plasma/plasmoids/io.github.keyboardspecialist.bc250control" ]]
            ;;
        decky) [[ -e "$HOME/homebrew/plugins/BC-250 Control" ]] ;;
        cec)
            [[ -e "$HOME/.config/systemd/user/bc250-cec-boot-wake.service" \
                || -e /etc/systemd/system/bc250-cec-poweroff-standby.service \
                || -e /etc/systemd/system-sleep/bc250-cec-amp.sh ]]
            ;;
        power)
            [[ -e /etc/systemd/system/cyan-skillfish-governor-smu.service \
                || -e /etc/systemd/system/bc250-acpi-heal.service \
                || -e /etc/systemd/system/bc250-smu-oc.service ]]
            ;;
        compute) [[ -e /etc/systemd/system/bc250-cu-live-manager.service ]] ;;
        audio)
            compgen -G '/usr/lib/modules/*/updates/amdgpu.ko.zst' >/dev/null \
                || compgen -G '/usr/lib/modules/*/updates/.bc250-audio-fix' >/dev/null \
                || [[ -e /usr/lib/depmod.d/10-bc250-audio-fix.conf \
                    || -e /usr/lib/depmod.d/10-updates.conf ]]
            ;;
        aic)
            [[ -e /etc/systemd/system/aic8800-modules.service \
                || -e /etc/modprobe.d/aic8800.conf \
                || -e /etc/udev/rules.d/40-aic8800-modeswitch.rules \
                || -e /etc/usb_modeswitch.d/1111:1111 \
                || -e /etc/atomic-update.conf.d/bc250-aic.conf \
                || -e /var/lib/bc250-control/aic8800/uninstall-pending \
                || -L /etc/systemd/system/multi-user.target.wants/aic8800-modules.service ]] \
                || compgen -G '/usr/lib/modules/*/updates/aic8800/*.ko' >/dev/null
            ;;
        rtw89)
            [[ -e "$SYSTEMD_DIR/rtw89-modules.service" \
                || -e "$MODPROBE_DIR/rtw89-steamos.conf" \
                || -e "$ATOMIC_KEEP_DIR/rtw89-steamos.conf" \
                || -e "$RTW89_DATA_DIR/helper/rtw89-ensure-modules" \
                || -e "$RTW89_DATA_DIR/firmware/manifest" \
                || -e "$RTW89_DATA_DIR/firmware/initramfs-pending" \
                || -e "$RTW89_DATA_DIR/modules/install-transaction" \
                || -e "$RTW89_DATA_DIR/uninstall-pending" \
                || -e "$ROOT_DATA_DIR/rtw89" \
                || -e "$ROOT_DATA_DIR/helper/rtw89-ensure-modules" \
                || -e "$MODPROBE_DIR/bc250-rtw89.conf" \
                || -e "$ATOMIC_KEEP_DIR/bc250-rtw89.conf" \
                || -L "$SYSTEMD_DIR/multi-user.target.wants/rtw89-modules.service" ]] \
                || compgen -G "$MODULE_BASE/*/updates/rtw89/*.ko" >/dev/null
            ;;
        storage)
            [[ -e /var/lib/bc250-control \
                || -e '/etc/systemd/system/var-lib-bc250\x2dcontrol.mount' \
                || -e /etc/systemd/system/bc250-persistence-recovery.service ]]
            ;;
    esac
}

component_state() {
    local component="$1"
    if component_probe "$component"; then
        echo installed
    elif component_has_artifacts "$component"; then
        echo partial
    elif [[ "$component" == storage \
        && -d /home/.steamos/offload/var/lib/bc250-control ]]; then
        echo data-preserved
    else
        echo not-installed
    fi
}

state_badge() {
    case "$1" in
        installed) printf '%s' "${CG}[installed]${C0}" ;;
        partial) printf '%s' "${CY}[partial]${C0}" ;;
        data-preserved) printf '%s' "${CY}[data preserved]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
    esac
}

show_status() {
    require_normal_user
    local component state
    for component in "${COMPONENTS[@]}" storage; do
        state=$(component_state "$component")
        printf '%-28s %s\n' "$(component_label "$component"):" "$state"
    done
}

plan_component() {
    local component="$1" state
    state=$(component_state "$component")
    printf '%s (%s)\n' "$(component_label "$component")" "$state"
    case "$component" in
        desktop) echo "  Remove the Plasma applet, D-Bus service, polkit policy, repair service, and desktop payload." ;;
        decky) echo "  Remove the Decky plugin and restart plugin_loader; shared hardware helpers remain." ;;
        cec) echo "  Remove CEC boot, shutdown, and sleep integrations; preserve CEC preferences." ;;
        power) echo "  Restore stock CPU state, disable tuning services, and remove the ACPI override on next boot." ;;
        compute) echo "  Restore stock CU dispatch when possible and remove boot integration; preserve the WGP profile and UMR." ;;
        audio) echo "  Restore stock AMDGPU modules for every patched kernel; preserve source and build caches." ;;
        aic) echo "  Disable module repair, unload drivers when possible, and remove installed modules, firmware, and device rules." ;;
        rtw89) echo "  Disable module repair, remove manifest-owned Realtek modules and firmware, and restore the stock WiFi driver after reboot." ;;
        storage) echo "  Remove the bind mount and recovery infrastructure; preserve the backing directory." ;;
    esac
}

show_plan() {
    require_normal_user
    local requested="${1:-all}" component
    if [[ "$requested" == all ]]; then
        echo "BC-250 uninstall order:"
        for component in "${UNINSTALL_ORDER[@]}"; do
            plan_component "$component"
        done
        plan_component storage
        echo
        echo "Saved tuning profiles, CEC preferences, source/build caches, and persistent backing data will be preserved."
        echo "A reboot may be required to finish restoring stock hardware behavior."
    else
        component_label "$requested" >/dev/null
        plan_component "$requested"
    fi
}

remove_persistence_for() {
    local component="$1" persistence=""
    case "$component" in
        desktop|cec|power|compute|aic) persistence="$component" ;;
        *) return 0 ;;
    esac
    require_script "$PERSISTENCE_SH"
    sudo bash "$PERSISTENCE_SH" remove "$persistence"
}

run_component_uninstall() {
    local component="$1" script rc=0
    script=$(component_script "$component")
    require_script "$script"
    case "$component" in
        desktop|decky|cec|audio) bash "$script" uninstall || rc=$? ;;
        power|compute|aic|rtw89|storage) sudo bash "$script" uninstall || rc=$? ;;
        *) die "Unknown component: $component" ;;
    esac
    [[ $rc -eq 0 ]] || return "$rc"
    remove_persistence_for "$component"
}

confirm_component() {
    local component="$1" answer
    show_plan "$component"
    [[ -t 0 && -t 1 ]] || die "Confirmation requires a terminal; use --yes for automation."
    printf '%s' "Remove $(component_label "$component")? [y/N] "
    IFS= read -r answer
    [[ "$answer" =~ ^([yY]|yes|YES)$ ]]
}

confirm_all() {
    local answer
    show_plan all
    [[ -t 0 && -t 1 ]] || die "Confirmation requires a terminal; use --yes for automation."
    echo
    printf '%s' 'Type UNINSTALL ALL to continue: '
    IFS= read -r answer
    [[ "$answer" == "UNINSTALL ALL" ]]
}

uninstall_one() {
    local component="$1" state
    state=$(component_state "$component")
    if [[ ( "$state" == not-installed && "$component" != audio ) \
        || "$state" == data-preserved ]]; then
        log "$(component_label "$component") is not installed."
        return 0
    fi
    run_component_uninstall "$component"
    log "Removed $(component_label "$component")."
}

uninstall_all() {
    local component state
    local -a failures=()
    for component in "${UNINSTALL_ORDER[@]}"; do
        state=$(component_state "$component")
        if [[ "$state" == not-installed && "$component" != audio ]]; then
            log "Skipping $(component_label "$component"): not installed."
            continue
        fi
        if ! run_component_uninstall "$component"; then
            failures+=("$component")
            log "Failed to remove $(component_label "$component"); continuing with independent components."
        fi
    done
    if ((${#failures[@]})); then
        printf '[bc250-maintenance] Uninstall incomplete; failed components:' >&2
        printf ' %s' "${failures[@]}" >&2
        printf '\n[bc250-maintenance] Shared storage was not removed.\n' >&2
        return 1
    fi

    require_script "$PERSISTENCE_SH"
    sudo bash "$PERSISTENCE_SH" remove all
    if [[ "$(component_state storage)" != data-preserved \
        && "$(component_state storage)" != not-installed ]]; then
        run_component_uninstall storage
    fi
    log "All installed components were removed. Preserved data can be deleted later with '$SELF purge'."
    log "Reboot to complete any pending ACPI, compute, audio, or driver rollback."
}

all_components_removed() {
    local component state
    for component in "${COMPONENTS[@]}"; do
        state=$(component_state "$component")
        [[ "$state" == not-installed ]] || return 1
    done
}

purge_preserved_data() {
    local path owner mode
    all_components_removed \
        || die "Installed or partial components remain. Run '$SELF uninstall all' first."
    require_script "$STORAGE_SH"
    if sudo test -L /etc/cyan-skillfish-governor-smu; then
        die "Refusing to purge symlinked power settings directory."
    fi
    require_script "$AUDIO_CLEAN_SH"
    # Status cannot inspect SteamOS's inactive root slot without privilege.
    # Re-run the ownership-checked rollback before allowing cache deletion.
    require_script "$AUDIO_SH"
    bash "$AUDIO_SH" uninstall
    bash "$AUDIO_CLEAN_SH" --all --dry-run >/dev/null
    sudo bash "$STORAGE_SH" purge --yes
    for path in /home /home/.steamos /home/.steamos/offload \
        /home/.steamos/offload/var /home/.steamos/offload/var/lib; do
        sudo test -d "$path" && ! sudo test -L "$path" \
            || die "Unsafe RTW89 persistent-data ancestor: $path"
        read -r owner mode < <(sudo stat -Lc '%u %a' "$path")
        [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
            || die "Unsafe RTW89 persistent-data ownership: $path"
    done
    sudo test ! -L /home/.steamos/offload/var/lib/rtw89-steamos \
        || die "Refusing to purge symlinked RTW89 persistent data."
    sudo rm -rf -- /home/.steamos/offload/var/lib/rtw89-steamos

    sudo rm -f -- /etc/bc250-cu-live-manager.conf /etc/bc250-smu-oc.conf
    sudo rm -rf -- /etc/cyan-skillfish-governor-smu

    rm -f -- "$HOME/.config/cecd/config.d/50-bc250.toml" \
        "$HOME/.config/cecd/config.d/99-zz-bc250.toml" \
        "$HOME/.config/bc250-cec.conf"
    rmdir "$HOME/.config/cecd/config.d" "$HOME/.config/cecd" 2>/dev/null || true

    bash "$AUDIO_CLEAN_SH" --all
    rm -rf -- "$SCRIPT_DIR/decky-plugin/out" "$SCRIPT_DIR/decky-plugin/node_modules"
    log "Preserved BC-250 settings, backing data, and reproducible build caches were purged."
    log "The toolkit checkout and shared pnpm installation were retained."
}

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}
trap tui_show_cursor EXIT

menu_select() {
    local title="$1"; shift
    local items=("$@") n=$# cur=0 drawn=0 key rest i label badge hint
    local lines=$((n + 4))
    printf '\033[?25l'; TUI_CURSOR_HIDDEN=1
    while true; do
        if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$lines"; fi
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CD}  up/down move - Enter select - q back${C0}"
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K%s\n' "  ${CI}${CB} > ${label} ${C0} ${badge}"
            else
                printf '\033[K%s\n' "     ${label}  ${badge}"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
        drawn=1
        IFS= read -rsn1 key || { tui_show_cursor; return 1; }
        if [[ $key == $'\033' ]]; then
            rest=""; IFS= read -rsn2 -t 0.05 rest || true; key+="$rest"
        fi
        case "$key" in
            $'\033[A'|k) if ((cur > 0)); then cur=$((cur - 1)); else cur=$((n - 1)); fi ;;
            $'\033[B'|j) if ((cur < n - 1)); then cur=$((cur + 1)); else cur=0; fi ;;
            "") MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

pause_key() {
    echo
    printf '%s' "${CD}-- press any key to return to maintenance --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

run_menu_action() {
    local rc=0
    echo
    bash "$SELF" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-maintenance]${C0} action failed (exit $rc)"
    fi
    pause_key
}

cmd_menu() {
    require_normal_user
    [[ -t 0 && -t 1 ]] || die "The maintenance menu requires an interactive terminal."
    local component
    while true; do
        local items=("Show component inventory|${CD}[read only]${C0}|Inspect installed, partial, and preserved-data state.")
        for component in "${COMPONENTS[@]}"; do
            items+=("Remove $(component_label "$component")|$(state_badge "$(component_state "$component")")|Review the plan and remove only this component.")
        done
        items+=(
            "Uninstall all components|${CR}[destructive]${C0}|Restore stock behavior and remove all integrations; preserve settings and data."
            "Purge preserved data|${CR}[permanent]${C0}|After uninstall, delete profiles, backing data, and reproducible build caches."
        )
        menu_select "BC-250 installed components" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action status ;;
            1|2|3|4|5|6|7|8)
                component=${COMPONENTS[$((MENU_CHOICE - 1))]}
                run_menu_action uninstall "$component"
                ;;
            9) run_menu_action uninstall all ;;
            10) run_menu_action purge ;;
        esac
    done
}

cmd_help() {
    cat << EOF
Usage: $0 {menu|status|plan [COMPONENT|all]|uninstall COMPONENT|all [--yes]|purge [--yes]|help}

Components: desktop, decky, cec, power, compute, audio, aic, rtw89, storage

  status                 Show lifecycle state for every component.
  plan [COMPONENT|all]   Describe removals and preserved data without changing anything.
  uninstall COMPONENT    Restore stock behavior and remove one component.
  uninstall all          Remove components in dependency-safe order, then remove storage infrastructure.
  purge                  Permanently delete preserved profiles, backing data, and build caches.

Uninstall preserves settings and persistent data by default. Destructive commands
prompt for confirmation; --yes is available for explicit noninteractive automation.
EOF
}

show_purge_plan() {
    cat << EOF
Purge permanently deletes preserved BC-250 data:
  - tuning and compute profiles under /etc
  - CEC preferences under $HOME/.config
  - persistent backing data under /home/.steamos/offload/var/lib/bc250-control
  - standalone RTW89 source and module caches under $RTW89_DATA_DIR
  - reproducible AMDGPU and Decky build caches in this checkout

The toolkit checkout and shared pnpm installation are retained. Purge is only
allowed after every installed or partial component has been removed.
EOF
}

require_normal_user
case "${1:-menu}" in
    menu) (($# <= 1)) || die "Usage: $0 menu"; cmd_menu ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    plan)
        (($# <= 2)) || die "Usage: $0 plan [COMPONENT|all]"
        show_plan "${2:-all}"
        ;;
    uninstall)
        if [[ $# -ne 2 && !( $# -eq 3 && ${3:-} == --yes ) ]]; then
            die "Usage: $0 uninstall COMPONENT|all [--yes]"
        fi
        if [[ "$2" == all ]]; then
            [[ "${3:-}" == --yes ]] || confirm_all || { log "Cancelled."; exit 0; }
            uninstall_all
        else
            component_label "$2" >/dev/null
            [[ "${3:-}" == --yes ]] || confirm_component "$2" || { log "Cancelled."; exit 0; }
            uninstall_one "$2"
        fi
        ;;
    purge)
        if [[ $# -ne 1 && !( $# -eq 2 && ${2:-} == --yes ) ]]; then
            die "Usage: $0 purge [--yes]"
        fi
        if [[ "${2:-}" != --yes ]]; then
            [[ -t 0 && -t 1 ]] || die "Confirmation requires a terminal; use --yes for automation."
            show_purge_plan
            printf '%s' 'Type PURGE DATA to permanently delete preserved data: '
            IFS= read -r answer
            [[ "$answer" == "PURGE DATA" ]] || { log "Cancelled."; exit 0; }
        fi
        purge_preserved_data
        ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
