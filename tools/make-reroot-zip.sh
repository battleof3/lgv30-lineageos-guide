#!/usr/bin/env bash
# Build the flashable re-root installer (addon.d hook + /cache/rksu payload) on the PC.
# Usage: bash tools/make-reroot-zip.sh <RKSU manager .apk> [Image.gz-dtb] [official boot.img] [output.zip]
#   defaults: $WORK/kernel-src/out/arch/arm64/boot/Image.gz-dtb, $WORK/boot.img, $WORK/rksu-reroot-installer.zip
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
APK=${1:?usage: make-reroot-zip.sh <RKSU manager .apk> [Image.gz-dtb] [official boot.img] [output.zip]}
KERNEL=${2:-$WORK/kernel-src/out/arch/arm64/boot/Image.gz-dtb}
BOOT=${3:-$WORK/boot.img}
OUT=${4:-$WORK/rksu-reroot-installer.zip}
for f in "$APK" "$KERNEL" "$BOOT"; do [[ -f $f ]] || { echo "not found: $f"; exit 1; }; done

python3 - "$APK" "$KERNEL" "$BOOT" "$OUT" "$REPO/reroot" <<'PY'
import hashlib, struct, sys, zipfile
apk, kernel, boot, out, rr = sys.argv[1:]
sha = lambda b: hashlib.sha256(b).hexdigest()

# magiskboot: the RKSU manager ships it as an arm64 library
with zipfile.ZipFile(apk) as z:
    magiskboot = z.read("lib/arm64-v8a/libmagiskboot.so")

# base-kernel.sha256: hash of the official boot image's kernel section (header v0), i.e. what
# reroot.sh gets on the phone after "magiskboot unpack -n" and joining kernel + kernel_dtb
b = open(boot, "rb").read()
assert b[:8] == b"ANDROID!", "not an Android boot image"
ksize, _, _, _, _, _, _, page = struct.unpack_from("<8I", b, 8)
assert struct.unpack_from("<I", b, 40)[0] == 0, "expected boot image header v0"
base = sha(b[page:page + ksize])

img = open(kernel, "rb").read()
assert sha(img) != base, "the kernel equals the official one: pass the rooted Image.gz-dtb"

files = {
    "META-INF/com/google/android/update-binary": open(rr + "/update-binary", "rb").read(),
    "META-INF/com/google/android/updater-script": b"#MAGISK\n",
    "payload/99-rksu.sh": open(rr + "/99-rksu.sh", "rb").read(),
    "payload/reroot.sh": open(rr + "/reroot.sh", "rb").read(),
    "payload/magiskboot": magiskboot,
    "payload/Image.gz-dtb": img,
    "payload/Image.gz-dtb.sha256": (sha(img) + "\n").encode(),
    "payload/base-kernel.sha256": (base + "\n").encode(),
}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in files.items():
        info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if name.endswith(("update-binary", ".sh", "magiskboot")) else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, data)
print("wrote", out)
print("  rooted kernel  ", sha(img)[:16])
print("  official kernel", base[:16])
print("  magiskboot     ", sha(magiskboot)[:16])
PY
echo "Sideload it from Lineage Recovery (Apply update -> Apply from ADB): adb sideload $OUT"
