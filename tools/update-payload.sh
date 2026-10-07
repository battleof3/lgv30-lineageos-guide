#!/usr/bin/env bash
# Install a rebuilt kernel into /cache/rksu (auto re-root after updates), then dry-run reroot.sh against the
# official boot.img and check it reproduces your flashed boot image byte for byte. Restores the old payload on failure.
# Usage: bash tools/update-payload.sh <Image.gz-dtb> <rksu-boot.img> [official boot.img]   (default: $WORK/boot.img)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
[[ $# -ge 2 && -f $1 && -f $2 ]] || { echo "usage: $0 <Image.gz-dtb> <rksu-boot.img> [official boot.img]"; exit 1; }
K=$1
STOCK=${3:-$WORK/boot.img}
[[ -f $STOCK ]] || { echo "official boot.img not found: $STOCK"; exit 1; }
WANT=$(sha256sum "$2" | cut -d' ' -f1)
KS=$(sha256sum "$K" | cut -d' ' -f1)
adb -d push -q "$K" /data/local/tmp/Image.gz-dtb.new
adb -d push -q "$STOCK" /data/local/tmp/stock-boot.img
adb -d shell "su -c '
set -e
cd /cache/rksu
[ \"\$(sha256sum /data/local/tmp/Image.gz-dtb.new | cut -d\" \" -f1)\" = \"$KS\" ]
cp Image.gz-dtb Image.gz-dtb.bak; cp Image.gz-dtb.sha256 Image.gz-dtb.sha256.bak
cp /data/local/tmp/Image.gz-dtb.new Image.gz-dtb
echo $KS > Image.gz-dtb.sha256
cd /data/local/tmp && RKSU_WORK=/data/local/tmp/rksu-work sh /cache/rksu/reroot.sh --test stock-boot.img out.img
'" | tr -d '\r'
GOT=$(adb -d shell "su -c 'sha256sum /data/local/tmp/out.img 2>/dev/null'" | tr -d '\r' | cut -d' ' -f1)
if [[ $GOT == "$WANT" ]]; then
  adb -d shell "su -c 'rm -f /cache/rksu/Image.gz-dtb.bak /cache/rksu/Image.gz-dtb.sha256.bak'"
  RESULT="PASS: re-root dry run reproduces rksu-boot.img exactly ($WANT)"; RC=0
else
  adb -d shell "su -c 'cd /cache/rksu && mv -f Image.gz-dtb.bak Image.gz-dtb && mv -f Image.gz-dtb.sha256.bak Image.gz-dtb.sha256'"
  RESULT="FAIL: dry run gave ${GOT:-nothing}, want $WANT; previous payload restored"; RC=1
fi
adb -d shell "su -c 'rm -rf /data/local/tmp/Image.gz-dtb.new /data/local/tmp/stock-boot.img /data/local/tmp/out.img /data/local/tmp/rksu-work'"
echo "$RESULT"; exit $RC
