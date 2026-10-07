#!/usr/bin/env bash
# Build the joan kernel with RKSU using the same toolchain as the official LineageOS build
# (fetched by tools/fetch-sources.sh from that build's build-manifest.xml): AOSP clang + LineageOS GCC 4.9 binutils
# (GNU binutils, as TARGET_KERNEL_LLVM_BINUTILS := false).
# Config = the running official kernel's /proc/config.gz + RKSU options.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}   # sources, toolchains and build output (see tools/fetch-sources.sh)
KSRC=$WORK/kernel-src
OUT=$KSRC/out
TC=$WORK/toolchains
CONFIG=$WORK/official.config   # the official kernel's /proc/config.gz
export PATH="$TC/clang/bin:$TC/aarch64-4.9/bin:$TC/arm-4.9/bin:$PATH"

MAKE=(make -C "$KSRC" O="$OUT" ARCH=arm64 SUBARCH=arm64
      CC=clang HOSTCC=clang HOSTCXX=clang++
      CLANG_TRIPLE=aarch64-linux-gnu-
      CROSS_COMPILE=aarch64-linux-android-
      CROSS_COMPILE_ARM32=arm-linux-androideabi-
      KBUILD_BUILD_USER=rksu KBUILD_BUILD_HOST=lgv30)

command -v bc >/dev/null || { echo "bc missing"; exit 1; }

mkdir -p "$OUT"
[[ -f $CONFIG ]] || { echo "missing $CONFIG: adb shell zcat /proc/config.gz > $CONFIG (phone on the official kernel)"; exit 1; }
cp "$CONFIG" "$OUT/.config"
cat >> "$OUT/.config" <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_DEBUG is not set
EOF
"${MAKE[@]}" olddefconfig

echo "[+] Config differences vs official (expect only KernelSU lines):"
diff <(grep -E '^CONFIG_' "$CONFIG" | sort) <(grep -E '^CONFIG_' "$OUT/.config" | sort) || true
grep -q '^CONFIG_KPROBES=y' "$OUT/.config" && { echo "KPROBES got enabled; RKSU manual hooks need it off."; exit 1; }

echo "[+] Building Image.gz-dtb"
"${MAKE[@]}" -j"$(nproc)" Image.gz-dtb 2>&1 | tee "$WORK/build.log" | grep -E 'error|KernelSU|warning: .*kernelsu' || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "BUILD FAILED, see $WORK/build.log"; exit 1; }
ls -la "$OUT/arch/arm64/boot/Image.gz-dtb"
strings "$OUT/vmlinux" | grep -m1 'Linux version'
