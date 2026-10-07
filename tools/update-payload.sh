#!/usr/bin/env bash
set -euo pipefail
# Usage: bash update-payload.sh <Image.gz-dtb> <matching rksu boot.img>
# Installs the kernel into /cache/rksu (auto re-root after OTAs) and verifies that
# reroot.sh rebuilds exactly that boot image from the official boot.img.
[[ $# -eq 2 && -f $1 && -f $2 ]] || { echo "usage: $0 <Image.gz-dtb> <rksu-boot.img>"; exit 1; }
K=$1
WANT=$(sha256sum "$2" | cut -d' ' -f1)
KS=$(sha256sum "$K" | cut -d' ' -f1)
adb -d push -q "$K" /data/local/tmp/Image.gz-dtb.new
adb -d push -q ~/Projects/lgv30-install/boot.img /data/local/tmp/stock-boot.img
adb -d shell "su -c '
set -e
cd /cache/rksu
[ \"\$(sha256sum /data/local/tmp/Image.gz-dtb.new | cut -d\" \" -f1)\" = \"$KS\" ]
cp Image.gz-dtb Image.gz-dtb.build3.bak; cp Image.gz-dtb.sha256 Image.gz-dtb.sha256.build3.bak
cp /data/local/tmp/Image.gz-dtb.new Image.gz-dtb
echo $KS > Image.gz-dtb.sha256
cd /data/local/tmp && RKSU_WORK=/data/local/tmp/rksu-work sh /cache/rksu/reroot.sh --test stock-boot.img out.img
sha256sum out.img
'" | tr -d '\r'
GOT=$(adb -d shell "su -c 'sha256sum /data/local/tmp/out.img'" | tr -d '\r' | cut -d' ' -f1)
adb -d shell "su -c 'rm -rf /data/local/tmp/Image.gz-dtb.new /data/local/tmp/stock-boot.img /data/local/tmp/out.img /data/local/tmp/rksu-work /cache/rksu/Image.gz-dtb.build3.bak /cache/rksu/Image.gz-dtb.sha256.build3.bak'"
[[ $GOT == "$WANT" ]] && echo "PASS: re-root dry run reproduces rksu-boot.img exactly ($WANT)" || { echo "FAIL: dry run $GOT vs $WANT"; exit 1; }
