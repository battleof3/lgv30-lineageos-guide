#!/usr/bin/env bash
# Build the flashable re-root installer (addon.d hook + /cache/rksu payload) on the PC, plus a tiny zip that
# disables the hook. Also leaves the payload in $PAYLOAD_DIR, where update-payload.sh and prepare-ota.sh use it.
# Usage: bash tools/make-reroot-zip.sh <RKSU manager .apk> [Image.gz-dtb] [official boot.img] [output.zip]
#   defaults: $WORK/kernel-src/out/arch/arm64/boot/Image.gz-dtb, $WORK/boot.img, $WORK/rksu-reroot-installer.zip
#   env: MANIFEST  build-manifest.xml of the official build (default $WORK/build-manifest.xml)
#        KCMP      prebuilt aarch64 kcmp (default: built now with tools/build-kcmp.sh)
#        PAYLOAD_DIR (default $WORK/payload)
# The official boot.img and manifest must be the build the rooted kernel was made from (tools/fetch-sources.sh).
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
APK=${1:?usage: make-reroot-zip.sh <RKSU manager .apk> [Image.gz-dtb] [official boot.img] [output.zip]}
KERNEL=${2:-$WORK/kernel-src/out/arch/arm64/boot/Image.gz-dtb}
BOOT=${3:-$WORK/boot.img}
OUT=${4:-$WORK/rksu-reroot-installer.zip}
MANIFEST=${MANIFEST:-$WORK/build-manifest.xml}
PAYLOAD_DIR=${PAYLOAD_DIR:-$WORK/payload}
for f in "$APK" "$KERNEL" "$BOOT" "$MANIFEST"; do [[ -f $f ]] || { echo "not found: $f"; exit 1; }; done
if [[ -z ${KCMP:-} ]]; then
  KCMP=$WORK/kcmp
  bash "$REPO/tools/build-kcmp.sh" "$KCMP"
fi
[[ -f $KCMP ]] || { echo "not found: $KCMP"; exit 1; }
SRC=$(mktemp); trap 'rm -f "$SRC"' EXIT
bash "$REPO/tools/kernel-source.sh" "$MANIFEST" "$BOOT" > "$SRC"

python3 - "$APK" "$KERNEL" "$BOOT" "$OUT" "$REPO/reroot" "$KCMP" "$SRC" "$PAYLOAD_DIR" <<'PY'
import hashlib, os, struct, sys, zipfile
apk, kernel, boot, out, rr, kcmp, src, pdir = sys.argv[1:]
sha = lambda b: hashlib.sha256(b).hexdigest()

# magiskboot: the RKSU manager ships it as an arm64 library
with zipfile.ZipFile(apk) as z:
    magiskboot = z.read("lib/arm64-v8a/libmagiskboot.so")

# base kernel: the official boot image's kernel section (header v0), i.e. what reroot.sh gets on the phone
# after "magiskboot unpack -n" and joining kernel + kernel_dtb
b = open(boot, "rb").read()
assert b[:8] == b"ANDROID!", "not an Android boot image"
ksize, _, _, _, _, _, _, page = struct.unpack_from("<8I", b, 8)
assert struct.unpack_from("<I", b, 40)[0] == 0, "expected boot image header v0"
base = b[page:page + ksize]
record = open(src, "rb").read()
assert ("base-kernel " + sha(base)).encode() in record, "kernel-source record does not match the boot image"

img = open(kernel, "rb").read()
assert sha(img) != sha(base), "the kernel equals the official one: pass the rooted Image.gz-dtb"
kc = open(kcmp, "rb").read()
assert kc[:4] == b"\x7fELF" and struct.unpack_from("<H", kc, 18)[0] == 183, "kcmp is not an aarch64 ELF"

payload = {   # -> /cache/rksu
    "reroot.sh": open(rr + "/reroot.sh", "rb").read(),
    "99-rksu.sh": open(rr + "/99-rksu.sh", "rb").read(),   # also installed to /system/addon.d by the installer
    "magiskboot": magiskboot,
    "kcmp": kc,
    "Image.gz-dtb": img,
    "Image.gz-dtb.sha256": (sha(img) + "\n").encode(),
    "base-Image.gz-dtb": base,
    "base-kernel.sha256": (sha(base) + "\n").encode(),
    "kernel-source.txt": record,
}
payload["payload.sha256"] = "".join(f"{sha(d)}  {n}\n" for n, d in payload.items()).encode()
EXEC = ("update-binary", ".sh", "magiskboot", "kcmp")

def write_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.external_attr = (0o755 if name.endswith(EXEC) else 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)

files = {
    "META-INF/com/google/android/update-binary": open(rr + "/update-binary", "rb").read(),
    "META-INF/com/google/android/updater-script": b"#MAGISK\n",
}
files.update({"payload/" + n: d for n, d in payload.items()})
write_zip(out, files)
disable = os.path.join(os.path.dirname(out) or ".", "rksu-reroot-disable.zip")
write_zip(disable, {
    "META-INF/com/google/android/update-binary": open(rr + "/disable-update-binary", "rb").read(),
    "META-INF/com/google/android/updater-script": b"#MAGISK\n",
})

os.makedirs(pdir, exist_ok=True)
for n, d in payload.items():
    with open(os.path.join(pdir, n), "wb") as f:
        f.write(d)
    os.chmod(os.path.join(pdir, n), 0o755 if n.endswith(EXEC) else 0o644)

print("wrote", out)
print("wrote", disable, "(sideload to stop the hook: creates /cache/rksu/DISABLE)")
print("payload copy in", pdir)
print("  rooted kernel  ", sha(img)[:16])
print("  official kernel", sha(base)[:16])
print("  kcmp           ", sha(kc)[:16])
print("  magiskboot     ", sha(magiskboot)[:16])
PY
echo "Sideload it from Lineage Recovery (Apply update -> Apply from ADB): adb sideload $OUT"
