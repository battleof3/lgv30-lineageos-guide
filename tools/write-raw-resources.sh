#!/usr/bin/env bash
# Write the LG-signed Verizon raw_resources (no orange-state images) to raw_resources, with checks.
set -euo pipefail
IMG=~/Projects/lgv30-root/bootwarn/aix/raw_resources-vzw-4m.img
BACKUP=~/Projects/lgv30-backup/partitions-2026-10-03/raw_resources.img
P=/dev/block/bootdevice/by-name/raw_resources
A=(adb -d)
want=$(sha256sum "$IMG" | cut -d' ' -f1)
[[ $(stat -c %s "$IMG") == 4194304 ]] || { echo "image is not 4 MiB"; exit 1; }
[[ $("${A[@]}" shell "su -c 'blockdev --getsize64 $P'" | tr -d '\r') == 4194304 ]] || { echo "partition size mismatch"; exit 1; }
live=$("${A[@]}" shell "su -c 'sha256sum $P'" | cut -d' ' -f1)
[[ $live == $(sha256sum "$BACKUP" | cut -d' ' -f1) ]] || { echo "live raw_resources differs from backup ($live); stopping"; exit 1; }
echo "live partition matches backup"
"${A[@]}" push -q "$IMG" /data/local/tmp/rr.img
[[ $("${A[@]}" shell "sha256sum /data/local/tmp/rr.img" | cut -d' ' -f1) == "$want" ]] || { echo "push corrupted"; exit 1; }
echo "image pushed and verified; writing"
"${A[@]}" shell "su -c 'dd if=/data/local/tmp/rr.img of=$P bs=4096 conv=fsync 2>&1; sync'"
got=$("${A[@]}" shell "su -c 'echo 3 > /proc/sys/vm/drop_caches; sha256sum $P'" | cut -d' ' -f1)
"${A[@]}" shell "rm /data/local/tmp/rr.img"
[[ $got == "$want" ]] && echo "WRITE VERIFIED: raw_resources = $got" || { echo "READBACK MISMATCH: $got (want $want)"; exit 1; }
