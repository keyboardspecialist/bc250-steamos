#!/usr/bin/env bash
set -euo pipefail

container="${BC250_CRACKTRO_CONTAINER:-bc250-cracktro-ubuntu2404}"
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${source_dir}/build-ubuntu2404"

if ! command -v distrobox >/dev/null 2>&1; then
    printf '%s\n' "distrobox is required. Install it for your user, then rerun this helper." >&2
    exit 1
fi

if ! distrobox enter "${container}" -- true >/dev/null 2>&1; then
    printf 'Creating distrobox %s from ubuntu:24.04...\n' "${container}"
    distrobox create --name "${container}" --image ubuntu:24.04 --yes
fi

check='command -v cmake >/dev/null && command -v ninja >/dev/null && command -v g++ >/dev/null && pkg-config --exists Qt6Core Qt6Quick Qt6QuickControls2 Qt6DBus Qt6Multimedia Qt6Test && dpkg-query -W qml6-module-qt-labs-settings qml6-module-qtmultimedia qml6-module-qtqml-workerscript qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-dialogs qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qttest gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-pulseaudio >/dev/null 2>&1'
if ! distrobox enter "${container}" -- bash -lc "${check}"; then
    printf '%s\n' "The build container is missing required tools. Run:" >&2
    printf '  distrobox enter %q -- sudo apt update\n' "${container}" >&2
    printf '  distrobox enter %q -- sudo apt install cmake ninja-build g++ pkg-config qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-tools-dev qt6-tools-dev-tools qml6-module-qt-labs-settings qml6-module-qtmultimedia qml6-module-qtqml-workerscript qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-dialogs qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qttest gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-pulseaudio\n' "${container}" >&2
    printf '%s\n' "Then rerun this helper. It never modifies the SteamOS root." >&2
    exit 2
fi

printf 'Building in %s...\n' "${container}"
distrobox enter "${container}" -- bash -lc \
    "cmake -S '${source_dir}' -B '${build_dir}' -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON && cmake --build '${build_dir}' && ctest --test-dir '${build_dir}' --output-on-failure"

binary="${build_dir}/bc250-cracktro"
if [[ ! -x "${binary}" ]]; then
    printf 'Expected binary was not produced: %s\n' "${binary}" >&2
    exit 3
fi

printf '%s\n' "Host linkage:"
ldd "${binary}"
printf '%s\n' "Host offscreen smoke test:"
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    "${binary}" --mock --smoke-test
printf 'Build verified: %s\n' "${binary}"
