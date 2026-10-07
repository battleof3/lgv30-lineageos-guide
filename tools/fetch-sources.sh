#!/usr/bin/env bash
# Fetch the exact kernel source and toolchains behind a LineageOS joan build, plus RKSU and mkbootimg, into $WORK.
# Usage: bash tools/fetch-sources.sh <build-manifest.xml> <boot.img>   (both from the same LineageOS build)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
MANIFEST=${1:?usage: fetch-sources.sh <build-manifest.xml> <boot.img>}
BOOT=${2:?usage: fetch-sources.sh <build-manifest.xml> <boot.img>}
# The official kernel's /proc/version names its clang ("... based on r536225").
CLANG_VERSION=${CLANG_VERSION:-r536225}
RKSU_URL=https://github.com/rsuntk/KernelSU
RKSU_COMMIT=${RKSU_COMMIT:-648e5988cf421172769f80ce07f86331b548c053}   # tested; the patches target this commit

[[ -f $MANIFEST && -f $BOOT ]] || { echo "manifest or boot.img not found"; exit 1; }
[[ $(head -c 8 "$BOOT") == ANDROID! ]] || { echo "$BOOT is not an Android boot image"; exit 1; }

rev() {  # manifest project path -> pinned revision
  python3 - "$MANIFEST" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    if p.get("path") == sys.argv[2]:
        print(p.get("revision")); break
else:
    sys.exit("not in manifest: " + sys.argv[2])
PY
}
KERNEL_REV=$(rev kernel/lge/msm8998)
GCC64_REV=$(rev prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9)
GCC32_REV=$(rev prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9)
CLANG_REV=$(rev prebuilts/clang/host/linux-x86)
echo "kernel $KERNEL_REV"; echo "gcc64  $GCC64_REV"; echo "gcc32  $GCC32_REV"; echo "clang  $CLANG_REV (clang-$CLANG_VERSION)"

mkdir -p "$WORK/toolchains"
fetch_commit() {  # url commit dir
  if [[ -d $3/.git ]]; then
    [[ $(git -C "$3" rev-parse HEAD) == "$2" ]] && { echo "have $3"; return; }
    echo "$3 exists at another commit; move it away first"; return 1
  fi
  git init -q "$3"; git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"; git -C "$3" checkout -q FETCH_HEAD
  echo "fetched $3 @ $(git -C "$3" rev-parse --short HEAD)"
}
fetch_commit https://github.com/LineageOS/android_kernel_lge_msm8998 "$KERNEL_REV" "$WORK/kernel-src"
fetch_commit https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 "$GCC64_REV" "$WORK/toolchains/aarch64-4.9"
fetch_commit https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9 "$GCC32_REV" "$WORK/toolchains/arm-4.9"
fetch_commit "$RKSU_URL" "$RKSU_COMMIT" "$WORK/rksu"
[[ -d $WORK/toolchains/mkbootimg/.git ]] || git clone -q --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$WORK/toolchains/mkbootimg"

if [[ ! -x $WORK/toolchains/clang/bin/clang ]]; then
  mkdir -p "$WORK/toolchains/clang"
  curl -sSfL "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/$CLANG_REV/clang-$CLANG_VERSION.tar.gz" \
    | tar -xz -C "$WORK/toolchains/clang"
fi
echo "clang: $("$WORK/toolchains/clang/bin/clang" --version | head -1)"

cp "$BOOT" "$WORK/boot.img"
echo "official boot.img copied to $WORK/boot.img (sha256 $(sha256sum "$WORK/boot.img" | cut -c1-16)...)"
echo
echo "Next, with the phone booted on this official build's kernel:"
echo "  adb shell zcat /proc/config.gz > $WORK/official.config"
echo "  adb shell cat /proc/version      # should name clang-$CLANG_VERSION"
