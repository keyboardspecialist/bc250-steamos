#!/usr/bin/env bash
set -euo pipefail

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${source_dir}/.." && pwd)"
build_dir="${source_dir}/build-macos"
mode="${1:-all}"

case "${mode}" in
    all|build|test|run) ;;
    *)
        printf 'Usage: %s [all|build|test|run]\n' "$0" >&2
        exit 64
        ;;
esac

brew_bin="$(command -v brew || true)"
if [[ -z "${brew_bin}" ]]; then
    printf '%s\n' \
        "Homebrew is required (https://brew.sh). After installing it, run: brew install cmake ninja qt bash coreutils" >&2
    exit 2
fi

formulae=(cmake ninja qt bash coreutils)
missing=()
for formula in "${formulae[@]}"; do
    if ! "${brew_bin}" list --versions "${formula}" >/dev/null 2>&1; then
        missing+=("${formula}")
    fi
done
if (( ${#missing[@]} )); then
    printf '%s' 'Missing Homebrew dependencies. Run: brew install' >&2
    printf ' %s' "${missing[@]}" >&2
    printf '\n' >&2
    exit 2
fi

cmake_prefix="$("${brew_bin}" --prefix cmake)"
ninja_prefix="$("${brew_bin}" --prefix ninja)"
qt_prefix="$("${brew_bin}" --prefix qt)"
bash_prefix="$("${brew_bin}" --prefix bash)"
coreutils_prefix="$("${brew_bin}" --prefix coreutils)"

brew_bash="${bash_prefix}/bin/bash"
gnu_bin="${coreutils_prefix}/libexec/gnubin"
cmake_bin="${cmake_prefix}/bin/cmake"
ctest_bin="${cmake_prefix}/bin/ctest"
ninja_bin="${ninja_prefix}/bin/ninja"

if [[ "${BC250_MACOS_HOMEBREW_BASH:-0}" != 1 ]]; then
    exec env BC250_MACOS_HOMEBREW_BASH=1 "${brew_bash}" "$0" "$@"
fi

export PATH="${bash_prefix}/bin:${gnu_bin}:${cmake_prefix}/bin:${ninja_prefix}/bin:${qt_prefix}/bin:${PATH}"
export PYTHONDONTWRITEBYTECODE=1
hash -r

damaged=()
for tool in "${brew_bash}" "${gnu_bin}/stat" "${cmake_bin}" "${ctest_bin}" "${ninja_bin}"; do
    [[ -x "${tool}" ]] || damaged+=("${tool}")
done
if [[ ! -f "${qt_prefix}/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
    damaged+=("${qt_prefix}/lib/cmake/Qt6/Qt6Config.cmake")
fi
if (( ${#damaged[@]} )); then
    printf 'Installed Homebrew formulae are missing required files:\n' >&2
    printf '  %s\n' "${damaged[@]}" >&2
    printf '%s\n' 'Repair them with brew reinstall cmake ninja qt bash coreutils.' >&2
    exit 2
fi
if (( BASH_VERSINFO[0] < 5 )); then
    printf 'Homebrew Bash 5 or newer is required; running %s.\n' "${BASH_VERSION}" >&2
    exit 2
fi

configure_and_build() {
    "${cmake_bin}" \
        -S "${source_dir}" \
        -B "${build_dir}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Debug \
        -DBUILD_TESTING=ON \
        -DCMAKE_MAKE_PROGRAM="${ninja_bin}" \
        -DCMAKE_PREFIX_PATH="${qt_prefix}"
    "${cmake_bin}" --build "${build_dir}" --parallel
}

run_python_suite() {
    local label="$1"
    local python_path="$2"
    local start_dir="$3"

    printf 'Running %s...\n' "${label}"
    if ! PYTHONPATH="${python_path}" python3 -m unittest discover -v -s "${start_dir}" -p 'test_*.py'; then
        printf '%s\n' \
            "${label} failed on macOS. Linux-only assumptions must be made portable; this harness does not skip the suite." >&2
        return 1
    fi
}

verify() {
    local ctest_listing
    local expected_tests=(bridge-native media-native qml-components qml-qt6-offscreen-smoke offscreen-startup)
    local missing_tests=()

    if ! command -v python3 >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        printf '%s\n' 'Full verification requires python3 and node on PATH.' >&2
        return 2
    fi

    for qt_tool in qmllint qmltestrunner qmlscene; do
        if ! command -v "${qt_tool}" >/dev/null 2>&1; then
            printf 'The Homebrew qt formula is missing required tool: %s\n' "${qt_tool}" >&2
            return 3
        fi
    done

    "${cmake_bin}" --build "${build_dir}" --target qml-lint

    ctest_listing="$("${ctest_bin}" --test-dir "${build_dir}" -N)"
    for test_name in "${expected_tests[@]}"; do
        if [[ "${ctest_listing}" != *": ${test_name}"* ]]; then
            missing_tests+=("${test_name}")
        fi
    done
    if (( ${#missing_tests[@]} )); then
        printf 'Expected Qt CTest tests were not registered: %s\n' "${missing_tests[*]}" >&2
        printf '%s\n' \
            'The Homebrew qt formula must provide Qt Test, qmllint, qmltestrunner, and qmlscene.' >&2
        return 3
    fi

    QT_QPA_PLATFORM=offscreen \
    QT_QUICK_BACKEND=software \
        "${ctest_bin}" --test-dir "${build_dir}" --output-on-failure

    QT_QPA_PLATFORM=offscreen \
    QT_QUICK_BACKEND=software \
    QT_MEDIA_BACKEND=mock \
        "${build_dir}/bc250-cracktro" --mock --smoke-test

    cd -- "${repo_root}"
    run_python_suite \
        'backend tests' \
        "${repo_root}/backend:${repo_root}/backend/vendor" \
        "${repo_root}/backend/tests"
    run_python_suite \
        'desktop service tests' \
        "${repo_root}/desktop-control/service:${repo_root}/desktop-control/vendor:${repo_root}/backend:${repo_root}/backend/vendor" \
        "${repo_root}/desktop-control/service/tests"
    run_python_suite 'root tests' '' "${repo_root}/tests"
    if ! node tests/test_qml_utils.cjs; then
        printf '%s\n' 'QML utility tests failed on macOS; they are required and were not skipped.' >&2
        return 1
    fi
}

configure_and_build

case "${mode}" in
    all|test) verify ;;
    build) ;;
    run) exec "${build_dir}/bc250-cracktro" --mock ;;
esac
