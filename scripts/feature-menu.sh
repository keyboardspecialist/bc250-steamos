#!/usr/bin/env bash
# Shared, read-only tracking/health badges. Refresh once on menu entry and
# after an action, not once per badge. No sudo, writes, or persisted health.
FEATURE_MENU_TRACKING="tracking unavailable"
FEATURE_MENU_HEALTH="health unavailable"
FEATURE_MENU_LEVEL=error

bc250_feature_menu_refresh() {
    local status helper="$SCRIPT_DIR/scripts/feature-recovery.py"
    FEATURE_MENU_TRACKING="tracking unavailable"
    FEATURE_MENU_HEALTH="health unavailable"
    FEATURE_MENU_LEVEL=error
    if [[ -f "$helper" && ! -L "$helper" ]] \
        && status=$(python3 -I "$helper" menu-status 2>/dev/null) \
        && [[ "$status" != *$'\n'* ]]; then
        IFS='|' read -r FEATURE_MENU_TRACKING FEATURE_MENU_HEALTH FEATURE_MENU_LEVEL <<< "$status"
    fi
}

bc250_feature_menu_badge() {
    local color="$CD" label="$FEATURE_MENU_TRACKING"
    if [[ "$1" == health ]]; then
        label="$FEATURE_MENU_HEALTH"
        case "$FEATURE_MENU_LEVEL" in
            healthy) color="$CG" ;;
            warning) color="$CY" ;;
            error) color="$CR" ;;
        esac
    elif [[ "$FEATURE_MENU_TRACKING" == *unavailable* || "$FEATURE_MENU_TRACKING" == *untracked* ]]; then
        color="$CY"
    fi
    printf '%s' "${color}[${label}]${C0}"
}
