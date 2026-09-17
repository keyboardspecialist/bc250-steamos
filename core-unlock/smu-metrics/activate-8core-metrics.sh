#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PARAM=${BC250_8CORE_METRICS_PARAM:-/sys/module/amdgpu/parameters/bc250_8core_metrics}
REVISION=${BC250_AMDGPU_REVISION_PARAM:-/sys/module/amdgpu/parameters/bc250_amdgpu_revision}
GPU_VENDOR=${BC250_GPU_VENDOR:-/sys/bus/pci/devices/0000:01:00.0/vendor}
GPU_DEVICE=${BC250_GPU_DEVICE:-/sys/bus/pci/devices/0000:01:00.0/device}
LOCK=${BC250_SMU_METRICS_LOCK:-/run/lock/bc250-8core-metrics.lock}
CPUINFO=${BC250_CPUINFO:-/proc/cpuinfo}

fail() { echo "bc250-8core-metrics: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "needs root"
command -v flock >/dev/null || fail "flock is required"
exec 9>"$LOCK"
flock 9
[[ -r "$GPU_VENDOR" && -r "$GPU_DEVICE" ]] || fail "BC-250 GPU identity is unavailable"
[[ "$(<"$GPU_VENDOR")" == 0x1002 && "$(<"$GPU_DEVICE")" == 0x13fe ]] \
    || fail "PCI device 1002:13fe was not found at 0000:01:00.0"

for _ in {1..300}; do
    [[ -e "$PARAM" && -e "$REVISION" ]] && break
    sleep 0.1
done
[[ -f "$PARAM" && ! -L "$PARAM" && -w "$PARAM" ]] \
    || fail "the loaded amdgpu module has no safe eight-core metrics selector"
[[ -f "$REVISION" && ! -L "$REVISION" && -r "$REVISION" ]] \
    || fail "the loaded amdgpu module has no metrics revision attestation"
[[ "$(<"$REVISION")" == smu-8core-metrics-r1 ]] \
    || fail "the loaded amdgpu module is not the matching eight-core metrics revision; reboot after installing the driver"

# Fail closed before checking topology so a six-core rollback cannot retain a
# decoder selected by an old kernel command line or interrupted service run.
printf 'N\n' > "$PARAM"
cores=$(awk -F: '/^physical id/ { package=$2 } /^core id/ { seen[package ":" $2]=1 } END { print length(seen) }' "$CPUINFO")
if [[ "$cores" != 8 ]]; then
    echo "bc250-8core-metrics: ${cores:-0} physical cores active; stock decoder selected"
    exit 0
fi

python3 -I "$HERE/unlock.py"
python3 -I "$HERE/patcher.py"
python3 -I "$HERE/patcher.py" --check
sleep 0.01
printf 'Y\n' > "$PARAM"
[[ "$(<"$PARAM")" == Y ]] || fail "amdgpu rejected the eight-core metrics selector"

echo "bc250-8core-metrics: Robin 1/3 firmware and amdgpu decoder are active"
