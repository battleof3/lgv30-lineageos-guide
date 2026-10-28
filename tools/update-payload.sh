#!/usr/bin/env bash
# Install a payload built by make-reroot-zip.sh (rooted kernel, base official kernel, kcmp, magiskboot, reroot.sh,
# payload.sha256) into /cache/rksu over adb (root), then dry-run reroot.sh against an official boot.img and check
# it reproduces your rooted boot image byte for byte. The previous payload is restored on any failure (and kept
# in /data/local/tmp/rksu-stage.prev otherwise). Does not install /system/addon.d/99-rksu.sh (the zip does).
# Usage: bash tools/update-payload.sh <rksu-boot.img> <official boot.img> [payload dir]   (default $WORK/payload)
#   rksu-boot.img: the official boot.img with the rooted kernel (kernel/repack-boot.sh), i.e. the expected output
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
[[ $# -ge 2 && -f $1 && -f $2 ]] || { echo "usage: $0 <rksu-boot.img> <official boot.img> [payload dir]"; exit 1; }
WANT=$(sha256sum "$1" | cut -d' ' -f1)
STOCK=$2
P=${3:-${PAYLOAD_DIR:-$WORK/payload}}
[[ -f $P/payload.sha256 ]] || { echo "no payload in $P (run tools/make-reroot-zip.sh)"; exit 1; }
(cd "$P" && sha256sum --quiet -c payload.sha256) || { echo "payload in $P does not match its payload.sha256"; exit 1; }
[[ $(cat "$P/Image.gz-dtb.sha256") != $(cat "$P/base-kernel.sha256") ]] || { echo "rooted kernel == base kernel"; exit 1; }

ST=/data/local/tmp/rksu-stage
adb -d shell "rm -rf $ST; mkdir -p $ST"
while read -r _ f; do adb -d push -q "$P/$f" "$ST/$f"; done < "$P/payload.sha256"
adb -d push -q "$P/payload.sha256" "$ST/payload.sha256"
adb -d push -q "$STOCK" "$ST/stock-boot.img"
adb -d push -q "$REPO/tools/update-payload-device.sh" "$ST/install.sh"
OUT=$(adb -d shell "su -c 'sh $ST/install.sh $ST $WANT'" | tr -d '\r')
echo "$OUT"
adb -d shell "su -c 'rm -rf $ST'" >/dev/null
grep -q '^UPDATE-PAYLOAD: PASS' <<<"$OUT"
