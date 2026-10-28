#!/usr/bin/env bash
# Before installing a LineageOS nightly: will the update hook re-root it, or does the RKSU kernel need a rebuild?
# Downloads that nightly's boot.img and build-manifest.xml (sha256-checked against the LineageOS builds API),
# compares its kernel source and toolchain revisions with the payload's kernel-source.txt, and runs kcmp (host
# build) on its kernel against the payload's base kernel, exactly as reroot.sh will on the phone.
#   same revisions and kcmp passes -> "same source: the hook will re-root this update"
#   anything else                  -> "kernel source changed: rebuild"; then (unless --check) fetches the sources,
#                                     rebuilds the RKSU kernel, repacks the boot image and builds a new payload.
# Never touches the phone: the last step (update-payload.sh, needs adb + root) is printed, not run.
# Usage: bash tools/prepare-ota.sh [--check] <YYYYMMDD>
#   env: PAYLOAD_DIR  payload now on the phone (default $WORK/payload, written by make-reroot-zip.sh)
#        OTA_WORK     download/rebuild folder (default $WORK/ota-<date>); its official/boot.img is the rollback image
#        RKSU_APK     RKSU manager APK (magiskboot), needed by the rebuild path
# Also checks the update zip's updater-script (read with HTTP range requests, ~1 MB of the ~1 GB zip): the hook only
# works if addon.d's restore runs before boot.img is written and device_check.sh (which 99-rksu.sh wraps) after it.
# Exit: 0 hook will re-root; 3 rebuild needed (--check) or rebuilt; 4 updater-script order changed (hook would not
# run after boot.img is written); 1 any error (download, sha mismatch, payload, kcmp split/decompress/check failure).
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
CHECK=0
[[ ${1:-} == --check ]] && { CHECK=1; shift; }
DATE=${1:-}
[[ $DATE =~ ^[0-9]{8}$ ]] || { echo "usage: prepare-ota.sh [--check] <YYYYMMDD>"; exit 1; }
API=${LINEAGE_API:-https://download.lineageos.org/api/v2/devices/joan/builds}
MIRROR=${LINEAGE_MIRROR:-https://mirrorbits.lineageos.org}
PAYLOAD_DIR=${PAYLOAD_DIR:-$WORK/payload}
OW=${OTA_WORK:-$WORK/ota-$DATE}
OFF=$OW/official
mkdir -p "$OFF"

echo "== LineageOS joan nightly $DATE"
curl -fsSL "$API" -o "$OW/builds.json" || { echo "cannot fetch $API"; exit 1; }
want() {  # file name -> expected sha256 from the builds API
  python3 - "$OW/builds.json" "${DATE:0:4}-${DATE:4:2}-${DATE:6:2}" "$1" <<'PY'
import json, sys
builds, date, name = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
for b in builds:
    if b.get("date") == date:
        for f in b.get("files", []):
            if f.get("filename") == name:
                print(f["sha256"]); sys.exit()
        sys.exit(f"{name} not listed for {date}")
sys.exit(f"no build dated {date} in the builds API (it lists {', '.join(b.get('date', '?') for b in builds)})")
PY
}
for f in boot.img build-manifest.xml; do
  SHA=$(want "$f")
  if [[ -f $OFF/$f && $(sha256sum "$OFF/$f" | cut -d' ' -f1) == "$SHA" ]]; then
    echo "have $OFF/$f"
  else
    curl -fsSL "$MIRROR/full/joan/$DATE/$f" -o "$OFF/$f.part" || { echo "download of $f failed"; exit 1; }
    GOT=$(sha256sum "$OFF/$f.part" | cut -d' ' -f1)
    [[ $GOT == "$SHA" ]] || { rm -f "$OFF/$f.part"; echo "ABORT: $f sha256 $GOT does not match the builds API ($SHA)"; exit 1; }
    mv "$OFF/$f.part" "$OFF/$f"
    echo "downloaded $OFF/$f (sha256 ok)"
  fi
done

echo "== update zip: updater-script order"
ZIPCHECK=$(python3 - "$OW/builds.json" "${DATE:0:4}-${DATE:4:2}-${DATE:6:2}" "$MIRROR/full/joan/$DATE" <<'PY' 2>&1
import json, re, struct, sys, urllib.request, zlib
builds, date, base = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
z = [f for b in builds if b.get("date") == date for f in b.get("files", []) if f.get("filename", "").endswith(".zip")]
if not z:
    sys.exit("no update zip listed for " + date)
url, size = base + "/" + z[0]["filename"], z[0].get("size")
def get(start, end):  # inclusive byte range -> (data, total size)
    if url.startswith("file://"):
        with open(url[7:], "rb") as f:
            f.seek(0, 2); total = f.tell(); f.seek(start); return f.read(end - start + 1), total
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        if r.status != 206:
            sys.exit("server ignored the range request")
        return r.read(), int(r.headers["Content-Range"].rsplit("/", 1)[1])
_, total = get(0, 0)
if size and total != size:
    sys.exit(f"zip size {total} does not match the builds API ({size})")
tail, _ = get(max(0, total - 65536), total - 1)
e = tail.rfind(b"PK\x05\x06")
cd_size, cd_off = struct.unpack_from("<II", tail, e + 12)
cd, _ = get(cd_off, cd_off + cd_size - 1)
o, script = 0, None
while o + 46 <= len(cd):
    method, = struct.unpack_from("<H", cd, o + 10)
    csize, _, nlen, xlen, clen = struct.unpack_from("<IIHHH", cd, o + 20)
    loff, = struct.unpack_from("<I", cd, o + 42)
    if cd[o + 46:o + 46 + nlen] == b"META-INF/com/google/android/updater-script":
        hdr, _ = get(loff, loff + 29)
        n2, x2 = struct.unpack_from("<HH", hdr, 26)
        data, _ = get(loff + 30 + n2 + x2, loff + 30 + n2 + x2 + csize - 1)
        script = (zlib.decompress(data, -15) if method == 8 else data).decode()
    o += 46 + nlen + xlen + clen
if script is None:
    sys.exit("no updater-script in " + url)
lines = script.splitlines()
def where(pat):
    return [i for i, l in enumerate(lines) if re.search(pat, l)]
restore = where(r'backuptool\.sh",\s*"restore"')
boot = where(r'package_extract_file\("boot\.img",')
dc = where(r'run_program\("/tmp/install/bin/device_check\.sh"')
print(f"backuptool restore at line {[i + 1 for i in restore]}, boot.img written at {[i + 1 for i in boot]}, "
      f"device_check.sh at {[i + 1 for i in dc]}")
ok = len(restore) == 1 and len(boot) == 1 and len(dc) == 1 and restore[0] < boot[0] < dc[0]
print("ORDER-OK" if ok else "ORDER-CHANGED")
PY
) && ZRC=0 || ZRC=$?
echo "$ZIPCHECK" | sed 's/^/  /'
if [[ $ZRC != 0 ]]; then ZIP=unknown; echo "  WARNING: could not check the updater-script; the verdict below assumes the usual order"
elif grep -q '^ORDER-OK' <<<"$ZIPCHECK"; then ZIP=ok; echo "  ok: addon.d restore -> boot.img written -> device_check.sh (hook runs after boot is written)"
else ZIP=changed; fi

echo "== payload in $PAYLOAD_DIR"
for f in payload.sha256 kernel-source.txt base-Image.gz-dtb base-kernel.sha256; do
  [[ -f $PAYLOAD_DIR/$f ]] || { echo "missing $PAYLOAD_DIR/$f (build the payload with tools/make-reroot-zip.sh)"; exit 1; }
done
(cd "$PAYLOAD_DIR" && sha256sum --quiet -c payload.sha256) || { echo "payload in $PAYLOAD_DIR does not match its payload.sha256"; exit 1; }

echo "== kernel source and toolchain revisions (manifest)"
bash "$REPO/tools/kernel-source.sh" "$OFF/build-manifest.xml" "$OFF/boot.img" > "$OW/kernel-source.txt"
REVS_SAME=1
while read -r path rev; do
  [[ $path == \#* || $path == base-kernel ]] && continue
  old=$(awk -v p="$path" '$1 == p { print $2 }' "$PAYLOAD_DIR/kernel-source.txt")
  if [[ $old == "$rev" ]]; then echo "  same     $path ${rev:0:12}"
  else echo "  CHANGED  $path ${old:0:12} -> ${rev:0:12}"; REVS_SAME=0; fi
done < "$OW/kernel-source.txt"

echo "== kcmp: payload base kernel vs the $DATE kernel (what reroot.sh will do on the phone)"
K=$OW/kcmp-run; rm -rf "$K"; mkdir -p "$K"
bash "$REPO/tools/build-kcmp.sh" --host "$K/kcmp" >/dev/null
python3 - "$OFF/boot.img" "$K/new.blob" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
ksize, page = struct.unpack_from("<I", b, 8)[0], struct.unpack_from("<I", b, 36)[0]
open(sys.argv[2], "wb").write(b[page:page + ksize])
PY
NEW_SHA=$(sha256sum "$K/new.blob" | cut -d' ' -f1)
BASE_SHA=$(cat "$PAYLOAD_DIR/base-kernel.sha256")
KC=1
if [[ $NEW_SHA == "$BASE_SHA" ]]; then
  echo "  identical to the payload's base kernel (exact-hash fast path)"; KC=0
else
  for k in base new; do
    src=$K/new.blob; [[ $k == base ]] && src=$PAYLOAD_DIR/base-Image.gz-dtb
    out=$("$K/kcmp" split "$src" "$K/$k.gz" "$K/$k.dtb" 2>&1) || { echo "  $out"; echo "ERROR: kcmp split ($k) failed"; exit 1; }
    echo "  $out"
    gzip -dc < "$K/$k.gz" > "$K/$k.img" || { echo "ERROR: cannot decompress the $k kernel"; exit 1; }
    out=$("$K/kcmp" check "$K/$k.gz" "$K/$k.img" 2>&1) || { echo "  $out"; echo "ERROR: kcmp check ($k) failed"; exit 1; }
    echo "  $out"
  done
  set +e; out=$("$K/kcmp" cmp "$K/base.img" "$K/base.dtb" "$K/new.img" "$K/new.dtb" 2>&1); KC=$?; set -e
  echo "  $out"
  [[ $KC == 0 || $KC == 1 ]] || { echo "ERROR: kcmp cmp exit $KC"; exit 1; }
fi
rm -rf "$K"
echo "  kcmp exit $KC"

echo
if [[ $ZIP == changed ]]; then
  echo "RESULT: updater-script changed: the hook would not run after boot.img is written; do not rely on it ($DATE)"
  echo "(the update itself is fine, but you will come back unrooted; fix reroot/99-rksu.sh first)"
  exit 4
fi
if [[ $REVS_SAME == 1 && $KC == 0 ]]; then
  echo "RESULT: same source: the hook will re-root this update ($DATE)"
  echo "Rollback image if anything goes wrong: $OFF/boot.img (flash from fastbootd; do not re-sideload the update)"
  exit 0
fi
if [[ $REVS_SAME == 1 ]]; then
  echo "NOTE: the manifest revisions match, but kcmp declines: the hook would NOT re-root this update."
elif [[ $KC == 0 ]]; then
  echo "NOTE: kcmp passes (compiled kernel identical apart from build stamps), so the hook would still re-root with"
  echo "      the old RKSU kernel; rebuild anyway so the payload matches the new source."
fi
echo "RESULT: kernel source changed: rebuild ($DATE)"
if [[ $CHECK == 1 ]]; then
  echo "(--check: stopping here; run without --check to rebuild in $OW)"
  exit 3
fi

APK=${RKSU_APK:-}
[[ -f $APK ]] || { echo "set RKSU_APK=<RKSU manager .apk> for the rebuild (magiskboot comes from it)"; exit 1; }
echo "== rebuilding in $OW"
export WORK=$OW
bash "$REPO/tools/fetch-sources.sh" "$OFF/build-manifest.xml" "$OFF/boot.img"
bash "$REPO/kernel/prepare-rksu.sh"
bash "$REPO/kernel/build-kernel.sh"
bash "$REPO/kernel/repack-boot.sh" "$OW/boot.img" "$OW/rksu-boot.img"
PAYLOAD_DIR=$OW/payload bash "$REPO/tools/make-reroot-zip.sh" "$APK"
cat <<EOF

Rebuilt. Before installing the $DATE update, put the new payload on the phone (adb, root; restores the old
payload if its dry run fails):
  bash tools/update-payload.sh $OW/rksu-boot.img $OW/boot.img $OW/payload
After it prints PASS, make it the payload this script compares against next time:
  rm -rf $PAYLOAD_DIR && cp -a $OW/payload $PAYLOAD_DIR
Rollback image for the update: $OFF/boot.img (official) or $OW/rksu-boot.img (rooted).
EOF
exit 3
