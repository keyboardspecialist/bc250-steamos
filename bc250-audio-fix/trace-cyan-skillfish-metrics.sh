#!/bin/bash
# Capture one table-3 CPU metrics transfer through its probe-only hook.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

METRICS=${1:-}
if [ -z "$METRICS" ]; then
    for candidate in /sys/class/drm/card*/device/gpu_metrics; do
        device=${candidate%/gpu_metrics}
        [ -r "$candidate" ] && [ -r "$device/vendor" ] \
            && [ -r "$device/device" ] || continue
        read -r vendor < "$device/vendor"
        read -r device_id < "$device/device"
        if [ "$vendor" = 0x1002 ] && [ "$device_id" = 0x13fe ]; then
            METRICS=$candidate
            break
        fi
    done
fi
[ -n "$METRICS" ] && [ -r "$METRICS" ] \
    || { echo "FATAL: no readable gpu_metrics node found" >&2; exit 1; }

grep -qw cyan_skillfish_trace_cpu_metrics /proc/kallsyms \
    || { echo "FATAL: loaded amdgpu lacks the table-3 CPU metrics hook" >&2; exit 1; }

if [ -w /sys/kernel/tracing/dynamic_events ]; then
    TRACEFS=/sys/kernel/tracing
elif [ -w /sys/kernel/debug/tracing/dynamic_events ]; then
    TRACEFS=/sys/kernel/debug/tracing
else
    echo "FATAL: writable tracefs dynamic events are unavailable" >&2
    exit 1
fi

PREFIX=${2:-/tmp/bc250-table3-cpu-metrics-$(date +%Y%m%d-%H%M%S)}
RAW=$PREFIX.gpu-metrics.bin
TRACE=$PREFIX.table3.trace
CPU=$PREFIX.cpufreq
HWMON=$PREFIX.hwmon
GROUP=bc250_metrics
EVENT=snapshot_$$
INSTANCE=$TRACEFS/instances/$EVENT

cleanup() {
    if [ -n "${INSTANCE:-}" ]; then
        printf '0\n' > "$INSTANCE/events/$GROUP/$EVENT/enable" 2>/dev/null || true
        rmdir "$INSTANCE" 2>/dev/null || true
    fi
    if [ -w "$TRACEFS/dynamic_events" ]; then
        printf -- '-:%s/%s\n' "$GROUP" "$EVENT" > "$TRACEFS/dynamic_events" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

mkdir "$INSTANCE"
printf 'p:%s/%s amdgpu:cyan_skillfish_trace_cpu_metrics power=+0x118($arg1):x32[8] temperature=+0x158($arg1):x32[8] frequency=+0x198($arg1):x32[8] l3_temperature=+0x2a8($arg1):x32[2] l3_frequency=+0x2c0($arg1):x32[2]\n' \
    "$GROUP" "$EVENT" > "$TRACEFS/dynamic_events"
printf '1\n' > "$INSTANCE/events/$GROUP/$EVENT/enable"
printf '1\n' > "$INSTANCE/tracing_on"

{
    for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -r "$path" ] || continue
        printf '%s ' "$path"
        read -r value < "$path"
        printf '%s\n' "$value"
    done
} > "$CPU"

{
    for path in /sys/class/hwmon/hwmon*/temp*_input; do
        [ -r "$path" ] || continue
        printf '%s ' "$path"
        read -r value < "$path"
        printf '%s\n' "$value"
    done
} > "$HWMON"

# This performs one normal GPU poll plus its Robin 3 CPU table-3 transfer.
dd if="$METRICS" of="$RAW" status=none
printf '0\n' > "$INSTANCE/tracing_on"
dd if="$INSTANCE/trace" of="$TRACE" status=none

grep -q "$EVENT:" "$TRACE" \
    || { echo "FATAL: the metrics hook was not observed" >&2; exit 1; }
chmod 0644 "$RAW" "$TRACE" "$CPU" "$HWMON"

echo "gpu_metrics: $RAW ($(stat -c %s "$RAW") bytes)"
echo "table 3 CPU: $TRACE"
echo "CPU clocks: $CPU"
echo "hwmon:      $HWMON"
echo
grep "$EVENT:" "$TRACE"
