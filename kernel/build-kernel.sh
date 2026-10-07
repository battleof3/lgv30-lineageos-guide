#!/usr/bin/env bash
# Build the joan kernel with RKSU using the same toolchain as the official lineage-22.2-20260920 build:
# AOSP clang r536225 (android-15.0.0_r32) + LineageOS GCC 4.9 binutils, GNU binutils (TARGET_KERNEL_LLVM_BINUTILS := false).
# Config = the running official kernel's /proc/config.gz + RKSU options.
set -euo pipefail

ROOT=~/Projects/lgv30-root
KSRC=$ROOT/kernel-src
OUT=$KSRC/out
TC=$ROOT/toolchains
export PATH="$TC/clang-r536225/bin:$TC/aarch64-4.9/bin:$TC/arm-4.9/bin:$PATH"

MAKE=(make -C "$KSRC" O="$OUT" ARCH=arm64 SUBARCH=arm64
      CC=clang HOSTCC=clang HOSTCXX=clang++
      CLANG_TRIPLE=aarch64-linux-gnu-
      CROSS_COMPILE=aarch64-linux-android-
      CROSS_COMPILE_ARM32=arm-linux-androideabi-
      KBUILD_BUILD_USER=rksu KBUILD_BUILD_HOST=lgv30-root)

command -v bc >/dev/null || { echo "bc missing"; exit 1; }

mkdir -p "$OUT"
cp "$ROOT/official-20260920.config" "$OUT/.config"
cat >> "$OUT/.config" <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_DEBUG is not set
EOF
"${MAKE[@]}" olddefconfig

echo "[+] Config differences vs official (expect only KernelSU lines):"
diff <(grep -E '^CONFIG_' "$ROOT/official-20260920.config" | sort) <(grep -E '^CONFIG_' "$OUT/.config" | sort) || true
grep -q '^CONFIG_KPROBES=y' "$OUT/.config" && { echo "KPROBES got enabled; RKSU manual hooks need it off."; exit 1; }

echo "[+] Building Image.gz-dtb"
"${MAKE[@]}" -j"$(nproc)" Image.gz-dtb 2>&1 | tee "$ROOT/build.log" | grep -E 'error|KernelSU|warning: .*kernelsu' || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "BUILD FAILED, see $ROOT/build.log"; exit 1; }
ls -la "$OUT/arch/arm64/boot/Image.gz-dtb"
strings "$OUT/vmlinux" | grep -m1 'Linux version'
