# shellcheck shell=bash
# Source this before ANY make invocation in valve-kernel/.
# The build deps (bc, pahole, libelf, openssl) live in deps/, not on the
# system. If pahole is not visible to Kconfig, syncconfig SILENTLY disables
# CONFIG_DEBUG_INFO_BTF and with it CONFIG_SCHED_CLASS_EXT, which shifts
# task_struct offsets — the module then loads (vermagic still matches) and
# silently corrupts memory. This is what black-screened the 2026-07-05 boot.
DEPS="${BC250_BUILD_DEPS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deps}"
export PATH="$DEPS/usr/bin:$PATH"
export LD_LIBRARY_PATH="$DEPS/usr/lib"
export C_INCLUDE_PATH="$DEPS/usr/include"
export LIBRARY_PATH="$DEPS/usr/lib"
export PKG_CONFIG_PATH="$DEPS/usr/lib/pkgconfig"
# Perl embeds absolute system library/module paths. Private packages may use a
# different Perl version, even on the same SteamOS channel after an update.
export PERL5LIB="$DEPS/usr/share/perl5/core_perl:$DEPS/usr/share/perl5/vendor_perl"
for _bc250_perl_dir in "$DEPS"/usr/lib/perl5/*/core_perl; do
    [ -d "$_bc250_perl_dir" ] || continue
    PERL5LIB="$_bc250_perl_dir:$PERL5LIB"
    if [ -f "$_bc250_perl_dir/CORE/libperl.so" ]; then
        LD_LIBRARY_PATH="$_bc250_perl_dir/CORE:$LD_LIBRARY_PATH"
    fi
done
unset _bc250_perl_dir

for tool in make gcc ld ar nm objcopy objdump strip patch perl python3 cpio \
            flex bison msgfmt pkg-config pahole bc zstd modinfo; do
    command -v "$tool" >/dev/null \
        || { echo "FATAL: $tool not on PATH"; return 1; }
    "$tool" --version >/dev/null 2>&1 \
        || { echo "FATAL: $tool cannot run with the build dependencies; run fetch-build-deps.sh to repair the cache" >&2; return 1; }
done

# --version alone misses incompatible Python extension modules (for example,
# main's math module requiring GLIBC_2.44 on SteamOS 3.9's glibc 2.43).
python3 -I -c 'import math, subprocess, sysconfig' \
    || { echo "FATAL: Python build modules are incompatible; run fetch-build-deps.sh to repair the cache" >&2; return 1; }
perl -MConfig -MFile::Spec -e 1 \
    || { echo "FATAL: Perl build modules are incompatible; run fetch-build-deps.sh to repair the cache" >&2; return 1; }
gcc -x c -fsyntax-only - <<'EOF' \
    || { echo "FATAL: host C headers are unusable; run fetch-build-deps.sh to repair the cache" >&2; return 1; }
#include <sys/types.h>
#include <stdio.h>
#include <gelf.h>
#include <openssl/ssl.h>
EOF
