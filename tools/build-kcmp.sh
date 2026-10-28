#!/usr/bin/env bash
# Build tools/kcmp.c: a static, libc-free aarch64 binary for the phone (default) or a host binary for tests.
# Usage: bash tools/build-kcmp.sh [output]          aarch64, default $WORK/kcmp
#        bash tools/build-kcmp.sh --host [output]   host,    default $WORK/kcmp-host
# The aarch64 build needs clang with the AArch64 target and ld.lld: the system clang, or the kernel's
# ($WORK/toolchains/clang/bin, from tools/fetch-sources.sh). No kernel headers or sysroot are used.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
SRC=$REPO/tools/kcmp.c
mkdir -p "$WORK"
if [[ ${1:-} == --host ]]; then
  OUT=${2:-$WORK/kcmp-host}
  "${CC:-cc}" -O2 -Wall -Wextra -o "$OUT" "$SRC"
  echo "built $OUT (host)"; exit 0
fi
OUT=${1:-$WORK/kcmp}
CLANG=${CLANG:-$(command -v clang || echo "$WORK/toolchains/clang/bin/clang")}
"$CLANG" --target=aarch64-linux-gnu -O2 -DKCMP_NOLIBC -nostdinc -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-pic -fno-pie -fno-asynchronous-unwind-tables -nostdlib -static -fuse-ld=lld -Wl,--build-id=none \
  -Wall -Wextra -o "$OUT" "$SRC"
# must be a static aarch64 executable with no interpreter and no dynamic section
python3 - "$OUT" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"\x7fELF" and b[4] == 2 and b[5] == 1, "not a 64-bit little-endian ELF"
etype, machine = struct.unpack_from("<HH", b, 16)
assert etype == 2 and machine == 183, f"not an aarch64 executable (type {etype}, machine {machine})"
phoff, = struct.unpack_from("<Q", b, 32); phentsize, phnum = struct.unpack_from("<HH", b, 54)
types = [struct.unpack_from("<I", b, phoff + i * phentsize)[0] for i in range(phnum)]
assert 3 not in types and 2 not in types, "has PT_INTERP or PT_DYNAMIC"
PY
echo "built $OUT (static aarch64, no libc, $(stat -c %s "$OUT") bytes, sha256 $(sha256sum "$OUT" | cut -c1-16)...)"
