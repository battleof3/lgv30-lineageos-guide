#!/sbin/sh
# RKSU re-root for LG V30 (joan) on official LineageOS.
#
# Runs at the end of a LineageOS update (via the device_check.sh wrapper installed by
# /system/addon.d/99-rksu.sh), after the updater has written the new boot.img.
# If the new boot image carries the official kernel our RKSU kernel was built from,
# the kernel is swapped for the RKSU one; anything else is left untouched.
#
#   sh reroot.sh                  re-root the boot partition
#   sh reroot.sh --test IN OUT    build OUT from boot image IN; never touches partitions
#
# Must never make a boot partition worse: it only writes after verifying the repacked
# image, and restores the original if the read-back does not match.

DIR=${RKSU_DIR:-/cache/rksu}
BOOT=/dev/block/bootdevice/by-name/boot
W=${RKSU_WORK:-/tmp/rksu-work}
MB=$DIR/magiskboot

log() { echo "[rksu $(date '+%F %T' 2>/dev/null)] $*"; }
fail() { log "FAILED: $*"; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

TEST=0
if [ "${1:-}" = "--test" ]; then
  TEST=1; IN=$2; OUT=$3
  [ -f "$IN" ] && [ -n "$OUT" ] || fail "usage: reroot.sh --test IN OUT"
  case $IN in /*) ;; *) IN=$PWD/$IN ;; esac
  case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
fi

log "start (test=$TEST)"
for f in magiskboot Image.gz-dtb Image.gz-dtb.sha256 base-kernel.sha256; do
  [ -f "$DIR/$f" ] || fail "missing $DIR/$f"
done
chmod 755 "$MB"
OURS=$(cat "$DIR/Image.gz-dtb.sha256")
BASE=$(cat "$DIR/base-kernel.sha256")
[ "$(sha "$DIR/Image.gz-dtb")" = "$OURS" ] || fail "stored RKSU kernel is corrupt"

rm -rf "$W"; mkdir -p "$W" && cd "$W" || fail "cannot use work dir $W"

if [ $TEST = 1 ]; then
  cp "$IN" boot.img || fail "cannot read $IN"
else
  dd if=$BOOT of=boot.img bs=4096 2>/dev/null || fail "cannot read boot partition"
fi

# -n: keep kernel/ramdisk exactly as stored (no decompress/recompress)
"$MB" unpack -n boot.img >unpack.log 2>&1 || { cat unpack.log; fail "magiskboot unpack"; }
[ -f kernel ] || fail "no kernel in boot image"
# magiskboot may split appended DTBs off the kernel; the blob in the image is kernel + kernel_dtb
if [ -f kernel_dtb ]; then cat kernel kernel_dtb > kernel.blob; else cp kernel kernel.blob; fi
CUR=$(sha kernel.blob)
log "boot kernel sha256: $CUR"

if [ "$CUR" = "$OURS" ]; then
  log "already the RKSU kernel; nothing to do"
  [ $TEST = 1 ] && cp boot.img "$OUT"
  rm -f "$DIR/NEEDS_REBUILD"
  exit 0
fi
if [ "$CUR" != "$BASE" ]; then
  log "kernel differs from the one RKSU was built on ($BASE); leaving boot untouched"
  [ $TEST = 1 ] || echo "$(date '+%F %T' 2>/dev/null) new official kernel $CUR, RKSU kernel needs a rebuild" > "$DIR/NEEDS_REBUILD"
  exit 0
fi

cp "$DIR/Image.gz-dtb" kernel || fail "copy kernel"
rm -f kernel_dtb
"$MB" repack -n boot.img new-boot.img >repack.log 2>&1 || { cat repack.log; fail "magiskboot repack"; }

# verify the result: our kernel in, everything else (ramdisk) unchanged
mkdir v && cd v || fail "mkdir v"
"$MB" unpack -n ../new-boot.img >/dev/null 2>&1 || fail "cannot unpack repacked image"
if [ -f kernel_dtb ]; then cat kernel kernel_dtb > kernel.blob; else cp kernel kernel.blob; fi
[ "$(sha kernel.blob)" = "$OURS" ] || fail "repacked kernel mismatch"
for f in ramdisk.cpio second extra recovery_dtbo dtb; do
  if [ -f ../$f ] || [ -f $f ]; then
    [ "$(sha ../$f)" = "$(sha $f)" ] || fail "repacked $f differs from the original"
  fi
done
cd ..

NEW_SHA=$(sha new-boot.img)
NEW_SIZE=$(wc -c < new-boot.img)
log "repacked image ok: $NEW_SIZE bytes, sha256 $NEW_SHA"

if [ $TEST = 1 ]; then
  cp new-boot.img "$OUT" && log "test output written to $OUT"
  exit 0
fi

PART_SIZE=$(blockdev --getsize64 $BOOT 2>/dev/null)
[ -n "$PART_SIZE" ] && [ "$NEW_SIZE" -le "$PART_SIZE" ] || fail "image ($NEW_SIZE) larger than boot partition ($PART_SIZE)"

dd if=new-boot.img of=$BOOT bs=4096 2>/dev/null; sync
BACK=$(head -c "$NEW_SIZE" $BOOT | sha256sum | cut -d' ' -f1)
if [ "$BACK" != "$NEW_SHA" ]; then
  log "read-back mismatch ($BACK); restoring the original boot image"
  dd if=boot.img of=$BOOT bs=4096 2>/dev/null; sync
  fail "write verification"
fi
rm -f "$DIR/NEEDS_REBUILD"
log "boot partition re-rooted with RKSU kernel"
exit 0
