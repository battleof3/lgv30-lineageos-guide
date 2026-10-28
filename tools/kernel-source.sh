#!/usr/bin/env bash
# Print the kernel-source record of an official LineageOS joan build: the manifest revisions that determine
# its kernel (kernel source + toolchains) and the sha256 of its boot.img's kernel section (Image.gz-dtb).
# make-reroot-zip.sh stores it in the payload as kernel-source.txt; prepare-ota.sh compares a new nightly with it.
# Usage: bash tools/kernel-source.sh <build-manifest.xml> <boot.img>   (both from the same LineageOS build)
set -euo pipefail
[[ $# -eq 2 && -f $1 && -f $2 ]] || { echo "usage: kernel-source.sh <build-manifest.xml> <boot.img>" >&2; exit 1; }
python3 - "$1" "$2" <<'PY'
import hashlib, struct, sys, xml.etree.ElementTree as ET
manifest, boot = sys.argv[1:]
PATHS = ["kernel/lge/msm8998",
         "prebuilts/clang/host/linux-x86",
         "prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9",
         "prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"]
revs = {p.get("path"): p.get("revision") for p in ET.parse(manifest).getroot().iter("project")}
b = open(boot, "rb").read()
assert b[:8] == b"ANDROID!", "not an Android boot image"
ksize, page = struct.unpack_from("<I", b, 8)[0], struct.unpack_from("<I", b, 36)[0]
print("# kernel source of the official build the payload's base kernel comes from (tools/kernel-source.sh)")
for p in PATHS:
    if not revs.get(p):
        sys.exit("not in manifest: " + p)
    print(p, revs[p])
print("base-kernel", hashlib.sha256(b[page:page + ksize]).hexdigest())
PY
