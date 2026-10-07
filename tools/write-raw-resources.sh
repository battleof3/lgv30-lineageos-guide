#!/usr/bin/env bash
# Write a raw_resources image to the phone, with checks before and after. Needs root (KernelSU) over adb.
# Usage: bash tools/write-raw-resources.sh <image to write> <your backup of the current raw_resources>
# The image must be a genuine LG-signed container; it is padded with zeros to the partition size.
set -euo pipefail
IMG=${1:?usage: write-raw-resources.sh <image> <backup of current raw_resources>}
BACKUP=${2:?usage: write-raw-resources.sh <image> <backup of current raw_resources>}
P=/dev/block/bootdevice/by-name/raw_resources
A=(adb -d)
[[ $(head -c 14 "$IMG") == BOOT_IMAGE_RLE ]] || { echo "$IMG is not an LG BOOT_IMAGE_RLE container"; exit 1; }
SIZE=$("${A[@]}" shell "su -c 'blockdev --getsize64 $P'" | tr -d '\r')
[[ $SIZE =~ ^[0-9]+$ ]] || { echo "could not read the partition size (root granted to Shell?)"; exit 1; }
(( $(stat -c %s "$IMG") <= SIZE )) || { echo "image is larger than the partition"; exit 1; }
live=$("${A[@]}" shell "su -c 'sha256sum $P'" | cut -d' ' -f1)
[[ $live == $(sha256sum "$BACKUP" | cut -d' ' -f1) ]] || { echo "live raw_resources differs from $BACKUP ($live); stopping"; exit 1; }
echo "live partition matches your backup"
PAD=$(mktemp); trap 'rm -f "$PAD"' EXIT
cp "$IMG" "$PAD"; truncate -s "$SIZE" "$PAD"
want=$(sha256sum "$PAD" | cut -d' ' -f1)
"${A[@]}" push -q "$PAD" /data/local/tmp/rr.img
[[ $("${A[@]}" shell "sha256sum /data/local/tmp/rr.img" | cut -d' ' -f1) == "$want" ]] || { echo "push corrupted"; exit 1; }
echo "image pushed and verified; writing"
"${A[@]}" shell "su -c 'dd if=/data/local/tmp/rr.img of=$P bs=4096 conv=fsync 2>&1; sync'"
got=$("${A[@]}" shell "su -c 'echo 3 > /proc/sys/vm/drop_caches; sha256sum $P'" | cut -d' ' -f1)
"${A[@]}" shell "rm /data/local/tmp/rr.img"
[[ $got == "$want" ]] && echo "WRITE VERIFIED: raw_resources = $got" || { echo "READBACK MISMATCH: $got (want $want)"; exit 1; }
