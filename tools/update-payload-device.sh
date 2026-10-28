#!/system/bin/sh
# Device half of tools/update-payload.sh (runs as root on the phone; also runs on the PC for tests).
# Installs the staged payload in STAGE into /cache/rksu, then dry-runs reroot.sh --test on STAGE/stock-boot.img
# and checks the output's sha256. Restores the previous payload on any failure; keeps it in STAGE.prev otherwise.
# Never touches a partition, reroot.log, NEEDS_REBUILD or DISABLE.
# Usage: sh update-payload-device.sh <STAGE dir> <expected sha256 of the dry-run output>
R=${RKSU_DIR:-/cache/rksu}
S=$1; WANT=$2
BAK=$S.prev
FILES="reroot.sh 99-rksu.sh magiskboot kcmp Image.gz-dtb Image.gz-dtb.sha256 base-Image.gz-dtb base-kernel.sha256 kernel-source.txt payload.sha256"
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
say() { echo "update-payload: $*"; }
fin() { say "$1"; echo "UPDATE-PAYLOAD: $1"; exit "$2"; }

[ -d "$S" ] && [ -n "$WANT" ] || fin "FAIL usage" 2
for f in $FILES; do [ -f "$S/$f" ] || fin "FAIL staged payload lacks $f" 1; done
while read -r h f; do
  [ "$(sha "$S/$f")" = "$h" ] || fin "FAIL staged $f does not match payload.sha256 (push corrupted?)" 1
done < "$S/payload.sha256"

mkdir -p "$R" || fin "FAIL cannot create $R" 1
rm -rf "$BAK"; mkdir -p "$BAK" || fin "FAIL cannot create $BAK" 1
for f in $FILES; do
  if [ -f "$R/$f" ]; then
    cp -f "$R/$f" "$BAK/$f" && [ "$(sha "$R/$f")" = "$(sha "$BAK/$f")" ] || fin "FAIL cannot back up $f; nothing changed" 1
  fi
done
say "previous payload backed up to $BAK"

restore() {
  for f in $FILES; do
    rm -f "$R/$f"
    if [ -f "$BAK/$f" ]; then cp -f "$BAK/$f" "$R/$f" && [ "$(sha "$BAK/$f")" = "$(sha "$R/$f")" ] || say "WARNING: could not restore $f"; fi
  done
  chmod 755 "$R/magiskboot" "$R/reroot.sh" "$R/kcmp" 2>/dev/null
  fin "FAIL $1; previous payload restored" 1
}
for f in $FILES; do
  cp -f "$S/$f" "$R/$f" || restore "copy $f (is /cache full?)"
  [ "$(sha "$S/$f")" = "$(sha "$R/$f")" ] || restore "verify $f"
done
chmod 755 "$R/magiskboot" "$R/reroot.sh" "$R/kcmp" || restore "chmod"
say "new payload installed and verified"

rm -f "$S/out.img"
RKSU_WORK=$S/work sh "$R/reroot.sh" --test "$S/stock-boot.img" "$S/out.img"
GOT=$(sha "$S/out.img")
[ "$GOT" = "$WANT" ] || restore "dry run gave ${GOT:-no image}, want $WANT"
fin "PASS re-root dry run reproduces the expected image ($WANT)" 0
