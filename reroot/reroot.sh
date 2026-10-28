#!/sbin/sh
# RKSU re-root for LG V30 (joan) on official LineageOS.
#
# Runs at the end of a LineageOS update (via the device_check.sh wrapper installed by
# /system/addon.d/99-rksu.sh), after the updater has written the new boot.img. Decision:
#   1. boot already carries our RKSU kernel                         -> nothing to do        RESULT: ALREADY
#   2. its kernel is exactly the official one RKSU was built on     -> swap in RKSU kernel  RESULT: REROOTED
#   3. else kcmp says it was built from the same source (same Image -> swap in RKSU kernel  RESULT: REROOTED
#      apart from build stamps, same DTBs; see tools/kcmp.c)
#   4. kcmp says the source differs                                 -> boot untouched       RESULT: NEEDS_REBUILD
#   5. the comparison itself failed (space, decompress, kcmp crash) -> boot untouched       RESULT: FAILED kcmp path
# Every nightly rebuilds the kernel (new timestamps, build-id, signing key), so 2 only matches the exact
# build RKSU was made from; 3 is what re-roots later nightlies. The swap keeps everything else of the
# new image: ramdisk, cmdline, os version and patch level.
#
#   sh reroot.sh                  re-root the boot partition
#   sh reroot.sh --test IN OUT    build OUT from boot image IN; never touches partitions or /cache/rksu
#
# Must never make a boot partition worse: it only writes after verifying the repacked image, and
# restores the original if the read-back does not match. /cache/rksu/DISABLE stops it from writing.
# Every run ends with one "RESULT: ALREADY|REROOTED|NEEDS_REBUILD|DISABLED|FAILED <reason>" line.

DIR=${RKSU_DIR:-/cache/rksu}
BOOT=${RKSU_BOOT:-/dev/block/bootdevice/by-name/boot}   # override only for host tests
W=${RKSU_WORK:-/tmp/rksu-work}
MB=$DIR/magiskboot
KCMP=$DIR/kcmp
BASEK=$DIR/base-Image.gz-dtb
LOG=$DIR/reroot.log
NEED_KB=${RKSU_NEED_KB:-180000}   # (override for host tests only) free space for the kcmp path: 2 split kernels (2 x 18 MB) + 2 raw Images (2 x 43 MB) + margin
PAYLOAD="magiskboot kcmp reroot.sh Image.gz-dtb Image.gz-dtb.sha256 base-Image.gz-dtb base-kernel.sha256"

START=$(date +%s 2>/dev/null)
log() { echo "[rksu $(date '+%F %T' 2>/dev/null)] $*"; }
result() {
  T=""; [ -n "$START" ] && T=" ($(( $(date +%s) - START ))s)"
  log "RESULT: $*$T"
}
fail() { log "FAILED: $*"; result "FAILED $*"; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

TEST=0
if [ "${1:-}" = "--test" ]; then
  TEST=1; IN=$2; OUT=$3
  [ -f "$IN" ] && [ -n "$OUT" ] || fail "usage: reroot.sh --test IN OUT"
  case $IN in /*) ;; *) IN=$PWD/$IN ;; esac
  case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
fi

# keep reroot.log bounded (the hook appends to it with O_APPEND, so truncating in place is safe)
if [ $TEST = 0 ] && [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
  cp -f "$LOG" "$LOG.old" && : > "$LOG"
fi

log "start (test=$TEST)"
if [ -f "$DIR/DISABLE" ]; then
  if [ $TEST = 0 ]; then
    log "$DIR/DISABLE present; not touching boot"
    result "DISABLED $DIR/DISABLE present"
    exit 0
  fi
  log "$DIR/DISABLE present (ignored in --test)"
fi

# payload integrity: every file listed in payload.sha256 must match, and the v2 set must be listed
[ -f "$DIR/payload.sha256" ] || fail "missing $DIR/payload.sha256"
for f in $PAYLOAD; do
  grep -q "  $f\$" "$DIR/payload.sha256" || fail "payload.sha256 does not list $f"
done
while read -r h f; do
  [ -n "$f" ] || continue
  [ -f "$DIR/$f" ] || fail "missing $DIR/$f"
  [ "$(sha "$DIR/$f")" = "$h" ] || fail "$f does not match payload.sha256"
done < "$DIR/payload.sha256"
for f in "$MB" "$KCMP"; do [ -x "$f" ] || chmod 755 "$f" || fail "cannot chmod $f"; done
OURS=$(cat "$DIR/Image.gz-dtb.sha256")
BASE=$(cat "$DIR/base-kernel.sha256")
[ "$(sha "$DIR/Image.gz-dtb")" = "$OURS" ] || fail "stored RKSU kernel is corrupt"
[ "$(sha "$BASEK")" = "$BASE" ] || fail "stored base kernel does not match base-kernel.sha256"
[ "$OURS" != "$BASE" ] || fail "payload's RKSU kernel equals its base official kernel"
log "payload ok: RKSU kernel $OURS, base official kernel $BASE"

rm -rf "$W"; mkdir -p "$W" && cd "$W" || fail "cannot use work dir $W"
trap 'cd /; rm -rf "$W"' EXIT

if [ $TEST = 1 ]; then
  cp "$IN" boot.img || fail "cannot read $IN"
else
  dd if="$BOOT" of=boot.img bs=4096 2>/dev/null || fail "cannot read boot partition"
fi
log "boot image sha256: $(sha boot.img)"

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
  [ $TEST = 1 ] || rm -f "$DIR/NEEDS_REBUILD"
  result "ALREADY boot carries the RKSU kernel"
  exit 0
fi

# kcmp path. Returns 0: same source; 1: different source (kcmp cmp exit 1); 2: the check itself failed ($WHY)
same_source() {
  K=$W/kc; WHY=""
  set -- $(df -k "$W" 2>/dev/null | tail -n 1)
  case ${4:-x} in
    *[!0-9]*) log "cannot read free space in $W (df); trying anyway" ;;
    *) [ "$4" -ge "$NEED_KB" ] || { WHY="only ${4} KB free in $W, need $NEED_KB"; return 2; } ;;
  esac
  mkdir "$K" || { WHY="cannot create $K"; return 2; }
  for k in new base; do
    if [ $k = new ]; then SRC=$W/kernel.blob; else SRC=$BASEK; fi
    R=$("$KCMP" split "$SRC" "$K/$k.gz" "$K/$k.dtb" 2>&1); RC=$?
    log "  $k: $R"
    [ "$RC" = 0 ] || { WHY="kcmp split ($k) exit $RC"; return 2; }
    "$MB" decompress "$K/$k.gz" "$K/$k.img" > "$K/mb.log" 2>&1 || { cat "$K/mb.log"; WHY="magiskboot decompress ($k) failed"; return 2; }
    R=$("$KCMP" check "$K/$k.gz" "$K/$k.img" 2>&1); RC=$?
    log "  $k: $R"
    [ "$RC" = 0 ] || { WHY="decompressed $k kernel failed kcmp check (exit $RC)"; return 2; }
    rm -f "$K/$k.gz"
  done
  R=$("$KCMP" cmp "$K/base.img" "$K/base.dtb" "$K/new.img" "$K/new.dtb" 2>&1); RC=$?
  log "  base vs new: $R"
  log "kcmp exit $RC"
  rm -rf "$K"
  case $RC in
    0) return 0 ;;
    1) return 1 ;;
    *) WHY="kcmp cmp exit $RC"; return 2 ;;
  esac
}

if [ "$CUR" = "$BASE" ]; then
  log "decision: exact match with the official kernel RKSU was built on (fast path)"
  HOW="exact base kernel"
else
  log "not the base official kernel ($BASE); checking source equivalence with kcmp"
  same_source; SS=$?
  if [ $SS = 0 ]; then
    log "decision: same source as the base official kernel; installing the RKSU kernel with the new ramdisk"
    HOW="same source as base (kcmp)"
  elif [ $SS = 1 ]; then
    log "decision: kernel not built from the source RKSU was built on; leaving boot untouched"
    [ $TEST = 1 ] || echo "$(date '+%F %T' 2>/dev/null) new official kernel $CUR, RKSU kernel needs a rebuild" > "$DIR/NEEDS_REBUILD"
    result "NEEDS_REBUILD new official kernel $CUR differs in source from base $BASE"
    exit 0
  else
    log "decision: could not compare the kernels ($WHY); leaving boot untouched"
    fail "kcmp path: $WHY"
  fi
fi
rm -f kernel.blob

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
  cp new-boot.img "$OUT" || fail "cannot write $OUT"
  log "test output written to $OUT"
  result "REROOTED (test, nothing written) $HOW; image sha256 $NEW_SHA"
  exit 0
fi

if [ -b "$BOOT" ]; then PART_SIZE=$(blockdev --getsize64 "$BOOT" 2>/dev/null); else PART_SIZE=$(wc -c < "$BOOT"); fi
[ -n "$PART_SIZE" ] && [ "$NEW_SIZE" -le "$PART_SIZE" ] || fail "image ($NEW_SIZE) larger than boot partition ($PART_SIZE)"

dd if=new-boot.img of="$BOOT" bs=4096 2>/dev/null; sync
BACK=$(head -c "$NEW_SIZE" "$BOOT" | sha256sum | cut -d' ' -f1)
if [ "$BACK" != "$NEW_SHA" ]; then
  log "read-back mismatch ($BACK); restoring the original boot image"
  dd if=boot.img of="$BOOT" bs=4096 2>/dev/null; sync
  fail "write verification"
fi
rm -f "$DIR/NEEDS_REBUILD"
log "boot partition re-rooted with RKSU kernel"
result "REROOTED $HOW; boot sha256 $NEW_SHA ($NEW_SIZE bytes)"
exit 0
