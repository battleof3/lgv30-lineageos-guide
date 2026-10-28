#!/usr/bin/env bash
# Host tests for the OTA re-root (tools/kcmp.c, reroot/*.sh, payload tools). No phone; magiskboot is replaced
# by tests/magiskboot-stub.py, which reproduces mkbootimg's layout (the real magiskboot does the same).
# Usage: bash tests/run-host-tests.sh
# Inputs (env; LineageOS joan official builds of the SAME kernel source, plus your rooted kernel built from A):
#   OFF_A, MAN_A    official boot.img + build-manifest.xml the rooted kernel was built from (e.g. 2026-09-20)
#   OFF_B, MAN_B    a later official boot.img + manifest of the same kernel source (e.g. 2026-10-25)
#   ROOTED          rooted Image.gz-dtb built from A;  ROOTED_A / ROOTED_B: A / B repacked with it (mkbootimg)
#   SHIFTED         optional: an official boot.img of the same source built on day 1-9 of a month (e.g. 2026-10-04),
#                   whose shorter date moves linux_proc_banner by a byte (banner-ref tests against OFF_A)
#   EXTRA_BOOTS     optional: more official boot.imgs of the same source (space separated)
#   RKSU_APK        optional: RKSU manager APK, for the installer-zip and prepare-ota tests
#   BUSYBOX         optional: a busybox binary; shell scripts then run under busybox sh with only its applets
#   T               scratch folder (default $WORK/host-tests)
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}
T=${T:-$WORK/host-tests}
for v in OFF_A MAN_A OFF_B MAN_B ROOTED ROOTED_A ROOTED_B; do
  [[ -f ${!v:-} ]] || { echo "set $v (see the header of $0)"; exit 1; }
done
rm -rf "$T"; mkdir -p "$T"/{k,bin}
PASS=0; FAILN=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL  $*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- shell for device scripts: busybox sh with only busybox applets (+ python3 for the stub), else sh
if [[ -n ${BUSYBOX:-} ]]; then
  for a in $("$BUSYBOX" --list); do ln -sf "$BUSYBOX" "$T/bin/$a"; done
  ln -sf "$(command -v python3)" "$T/bin/python3"
  DSH=("$BUSYBOX" sh); DPATH=$T/bin; SHEBANG="#!$BUSYBOX sh"
  echo "device scripts run under: busybox sh ($("$BUSYBOX" | head -1))"
else
  DSH=(sh); DPATH=$PATH; SHEBANG="#!/bin/sh"
  echo "device scripts run under: $(readlink -f "$(command -v sh)") (set BUSYBOX for a closer match to recovery)"
fi
dsh() { env PATH="$DPATH" "${DSH[@]}" "$@"; }

bash "$REPO/tools/build-kcmp.sh" --host "$T/kcmp" >/dev/null || { echo "host kcmp build failed"; exit 1; }
KC=$T/kcmp
H=$T/k

echo "== H13 syntax"
for f in "$REPO"/reroot/{reroot.sh,99-rksu.sh,update-binary,disable-update-binary} "$REPO/tools/update-payload-device.sh"; do
  if dsh -n "$f"; then ok "sh -n $(basename "$f")"; else bad "sh -n $(basename "$f")"; fi
done

echo "== H9 aarch64 build (static, libc-free; cannot run here: no aarch64 emulator)"
if out=$(WORK=$T bash "$REPO/tools/build-kcmp.sh" "$T/kcmp-aarch64" 2>&1); then ok "$out"; else bad "aarch64 build: $out"; fi

# --- kernels: blob (kernel section) -> head.gz + dtb tail -> raw Image
blob() { python3 -I - "$1" "$2" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
if b[:8] == b"ANDROID!":
    k, p = struct.unpack_from("<I", b, 8)[0], struct.unpack_from("<I", b, 36)[0]; b = b[p:p + k]
open(sys.argv[2], "wb").write(b)
PY
}
prep() {  # name source
  blob "$2" "$H/$1.blob"
  "$KC" split "$H/$1.blob" "$H/$1.gz" "$H/$1.dtb" >/dev/null && gzip -dc < "$H/$1.gz" > "$H/$1.img"
}
prep A "$OFF_A"; prep B "$OFF_B"; prep R "$ROOTED"
EXTRA=()
[[ -n ${SHIFTED:-} ]] && prep S "$SHIFTED"
i=0; for e in ${EXTRA_BOOTS:-}; do i=$((i + 1)); prep "X$i" "$e"; EXTRA+=("X$i"); done

expect() {  # 0|1|2|!0  description  kcmp-args...
  local want=$1 desc=$2; shift 2
  local out rc; out=$("$KC" "$@" 2>&1); rc=$?
  if [[ $want == "!0" && $rc != 0 ]] || [[ $want == "$rc" ]]; then ok "$desc: exit $rc"; else bad "$desc: exit $rc, want $want"; fi
  echo "        $out" | tail -n 1
}

echo "== H1/H2 positive controls (same source)"
expect 0 "H1 A vs B" cmp "$H/A.img" "$H/A.dtb" "$H/B.img" "$H/B.dtb"
expect 0 "H1 B vs A" cmp "$H/B.img" "$H/B.dtb" "$H/A.img" "$H/A.dtb"
for x in "${EXTRA[@]}"; do
  expect 0 "H1 A vs $x" cmp "$H/A.img" "$H/A.dtb" "$H/$x.img" "$H/$x.dtb"
  expect 0 "H1 B vs $x" cmp "$H/B.img" "$H/B.dtb" "$H/$x.img" "$H/$x.dtb"
done
expect 0 "H2 B vs B" cmp "$H/B.img" "$H/B.dtb" "$H/B.img" "$H/B.dtb"
expect 0 "check A gzip/Image" check "$H/A.gz" "$H/A.img"

echo "== H3 rooted kernel vs official (different source)"
expect 1 "H3 B vs rooted" cmp "$H/B.img" "$H/B.dtb" "$H/R.img" "$H/R.dtb"

echo "== H4/H5/H6/H7 tampered and degenerate inputs (variants of B)"
python3 -I - "$H" <<'PY'
import os, re, struct, sys
H = sys.argv[1]
img = bytearray(open(f"{H}/B.img", "rb").read())
dtb = open(f"{H}/B.dtb", "rb").read()
def w(name, data): open(f"{H}/{name}", "wb").write(data)
def var(name, edits):
    b = bytearray(img)
    for off, new in edits:
        b[off:off + len(new)] = new
    w(name + ".img", b)
# a real instruction in .text: first 'ret' (d65f03c0) after 1 MiB; change the instruction before it (4 bytes)
ret = img.find(bytes.fromhex("c0035fd6"), 1 << 20)
ins = struct.unpack_from("<I", img, ret - 4)[0]
var("code4", [(ret - 4, struct.pack("<I", 0xd503201f))])                            # instruction -> nop (4 bytes)
var("codebit", [(ret - 4, struct.pack("<I", ins ^ (1 << 10)))])                     # one immediate bit
var("code1", [(ret - 4, bytes([img[ret - 4] ^ 1]))])
var("code4k", [(1 << 21, bytes(x ^ 0x55 for x in img[1 << 21:(1 << 21) + 4096]))])  # 4 KiB of code
p = img.find(b"Kernel panic - not syncing")
var("rodata4", [(p, b"KERN")])                                                       # a string, same length
c = img.find(b"IKCFG_ST") + 8 + 200
var("ikconfig1", [(c, bytes([img[c] ^ 1]))])                                         # the embedded config
cert = img.find(b"Build time autogenerated kernel key")
cs = max(m.start() for m in re.finditer(rb"\x30\x82..\x30\x82..\xa0\x03\x02\x01\x02", bytes(img[cert - 4096:cert]), re.S)) + cert - 4096
var("precert4", [(cs - 4, bytes(x ^ 0xff for x in img[cs - 4:cs]))])                # just outside the cert
# variable regions only (must still be SAME)
lv = img.find(b"Linux version ")
host = img.find(b"(root@", lv) + 6
bid = img.find(bytes([4, 0, 0, 0, 20, 0, 0, 0, 3, 0, 0, 0]) + b"GNU\0") + 16
var("stamps", [(host, b"ffffffffffff"), (bid, bytes(20)), (cs + 200, bytes(300))])
# DTB variants
blobs, o = [], 0
while o < len(dtb):
    n = struct.unpack_from(">I", dtb, o + 4)[0]; blobs.append(dtb[o:o + n]); o += n
w("reorder.dtb", b"".join(reversed(blobs)))
m = bytearray(blobs[3]); m[len(m) // 2] ^= 1
w("dtbbyte.dtb", b"".join(blobs[:3] + [bytes(m)] + blobs[4:]))
w("dtbdrop.dtb", b"".join(blobs[:-1]))
w("dtbdup.dtb", b"".join(blobs + [blobs[0]]))
same = [i for i in range(1, len(blobs)) if len(blobs[i]) == len(blobs[0])][0]
w("dtbswap.dtb", b"".join([blobs[0]] + [blobs[0] if i == same else blobs[i] for i in range(1, len(blobs))]))
w("dtbjunk.dtb", dtb + b"\0" * 16)
w("empty", b"")
w("garbage.img", os.urandom(1 << 12) * (len(img) >> 12))
small = bytearray(img[:8 << 20]); w("small.img", small)
w("trunc.gz", open(f"{H}/B.gz", "rb").read()[:-4096])
w("trunc.img", img[:-4096])
PY
B=("$H/B.img" "$H/B.dtb")
expect 1 "H4 one instruction (4 bytes, same size)" cmp "${B[@]}" "$H/code4.img" "$H/B.dtb"
expect 1 "H4 one immediate bit of an instruction" cmp "${B[@]}" "$H/codebit.img" "$H/B.dtb"
expect 1 "H4 one byte of code" cmp "${B[@]}" "$H/code1.img" "$H/B.dtb"
expect 1 "H4 4 KiB of code" cmp "${B[@]}" "$H/code4k.img" "$H/B.dtb"
expect 1 "H4 4 bytes of .rodata string" cmp "${B[@]}" "$H/rodata4.img" "$H/B.dtb"
expect 1 "H4 1 byte of embedded config" cmp "${B[@]}" "$H/ikconfig1.img" "$H/B.dtb"
expect 1 "H4 4 bytes just before the cert" cmp "${B[@]}" "$H/precert4.img" "$H/B.dtb"
expect 1 "H5 one DTB byte" cmp "${B[@]}" "$H/B.img" "$H/dtbbyte.dtb"
expect 1 "H5 one DTB dropped" cmp "${B[@]}" "$H/B.img" "$H/dtbdrop.dtb"
expect 1 "H5 one DTB duplicated (extra)" cmp "${B[@]}" "$H/B.img" "$H/dtbdup.dtb"
expect 1 "H5 one DTB replaced by a copy of another" cmp "${B[@]}" "$H/B.img" "$H/dtbswap.dtb"
expect 1 "H5 trailing junk after the DTBs" cmp "${B[@]}" "$H/B.img" "$H/dtbjunk.dtb"
expect 0 "H5 DTBs reordered (positive control)" cmp "${B[@]}" "$H/B.img" "$H/reorder.dtb"
expect 0 "H6 banner host, build-id, cert bytes changed (positive control)" cmp "${B[@]}" "$H/stamps.img" "$H/B.dtb"

if [[ -n ${SHIFTED:-} ]]; then
  echo "== H6b moved linux_proc_banner (A vs SHIFTED): references allowed only to the banner, at most 4"
  expect 0 "H1 A vs SHIFTED (2 real banner references moved)" cmp "$H/A.img" "$H/A.dtb" "$H/S.img" "$H/S.dtb"
  python3 -I - "$H" <<'PY'
import struct, sys
H = sys.argv[1]
a, b = open(f"{H}/A.img", "rb").read(), open(f"{H}/S.img", "rb").read()
pa, pb = a.find(b"%s version %s ("), b.find(b"%s version %s (")
assert pa != pb and (pa >> 12) == (pb >> 12)
base = 0xffffff8008000000 + struct.unpack_from("<Q", a, 8)[0]
def adrp(pc, target, rd=1):
    d = ((target & ~0xfff) - (pc & ~0xfff)) >> 12
    return 0x90000000 | ((d & 3) << 29) | (((d >> 2) & 0x7ffff) << 5) | rd
def add(rd, rn, imm):
    return 0x91000000 | (imm << 10) | (rn << 5) | rd
def var(name, ea, eb):  # same offsets in both Images, different values
    x, y = bytearray(a), bytearray(b)
    for (o, v), (_, w) in zip(ea, eb):
        x[o:o + len(v)] = v; y[o:o + len(w)] = w
    open(f"{H}/{name}-a.img", "wb").write(x); open(f"{H}/{name}-b.img", "wb").write(y)
q = lambda v: struct.pack("<Q", v)
spots = [0x1000000 + 0x100 * k for k in range(4)]   # 8-aligned, identical in both, outside every region
# (a) an unrelated pointer: same in-page offset as the banner, moved by the same shift, but another page
var("ptr-other", [(spots[0], q(base + pa + 0x1000))], [(spots[0], q(base + pb + 0x1000))])
# (a') a pointer to the banner's offset under a different (page-aligned) base
var("ptr-base", [(spots[0], q(base + 0x10000 + pa))], [(spots[0], q(base + 0x10000 + pb))])
# (b) 3 extra genuine pointers -> 5 fixups in total; (c) 2 extra -> 4 (allowed)
var("refs5", [(o, q(base + pa)) for o in spots[:3]], [(o, q(base + pb)) for o in spots[:3]])
var("refs4", [(o, q(base + pa)) for o in spots[:2]], [(o, q(base + pb)) for o in spots[:2]])
# ADD #lo12 with the banner's offsets, register loaded by an ADRP of another page / of the banner's page
o = spots[3]
other = adrp(base + o, base + pa + 0x5000)
var("add-otherpage", [(o, struct.pack("<II", other, add(1, 1, pa & 0xfff)))], [(o, struct.pack("<II", other, add(1, 1, pb & 0xfff)))])
good = adrp(base + o, base + pa)
var("add-bannerpage", [(o, struct.pack("<II", good, add(1, 1, pa & 0xfff)))], [(o, struct.pack("<II", good, add(1, 1, pb & 0xfff)))])
PY
  sv() { expect "$1" "$2" cmp "$H/$3-a.img" "$H/A.dtb" "$H/$3-b.img" "$H/S.dtb"; }
  sv 1 "N1 unrelated pointer moved by the banner shift (other page)" ptr-other
  sv 1 "N1 pointer to the banner offset under another base" ptr-base
  sv 1 "N1 5 banner references moved (cap 4)" refs5
  sv 0 "N1 4 banner references moved (positive control)" refs4
  sv 1 "N1 ADD #lo12 with ADRP of another page" add-otherpage
  sv 0 "N1 ADD #lo12 with ADRP of the banner page (3 refs, positive control)" add-bannerpage
else
  echo "== H6b skipped (set SHIFTED to an official boot.img built on day 1-9)"
fi
expect 1 "H7 both empty" cmp "$H/empty" "$H/empty" "$H/empty" "$H/empty"
expect 1 "H7 both the same garbage" cmp "$H/garbage.img" "$H/B.dtb" "$H/garbage.img" "$H/B.dtb"
expect 1 "H7 Image too small (8 MiB, identical)" cmp "$H/small.img" "$H/B.dtb" "$H/small.img" "$H/B.dtb"
expect 1 "H7 no DTB tails (both empty)" cmp "$H/B.img" "$H/empty" "$H/B.img" "$H/empty"
expect 1 "H7 truncated Image vs full" cmp "${B[@]}" "$H/trunc.img" "$H/B.dtb"
expect 2 "H7 missing file" cmp "${B[@]}" "$H/nonexistent" "$H/B.dtb"
expect 1 "H7 check: truncated gzip" check "$H/trunc.gz" "$H/trunc.img"
expect 1 "H7 check: Image does not match gzip ISIZE" check "$H/B.gz" "$H/trunc.img"
expect 1 "H7 check: not gzip" check "$H/empty" "$H/B.img"
expect 1 "H7 check: garbage Image" check "$H/B.gz" "$H/garbage.img"
expect 0 "split of a blob without DTBs (head = all)" split "$H/B.gz" "$H/s.head" "$H/s.dtb"
[[ ! -s $H/s.dtb ]] && cmp -s "$H/s.head" "$H/B.gz" && ok "  ... empty tail, head unchanged" || bad "split without DTBs"

echo "== H8 genuinely different source at the same size: no such official build available (see DESIGN.md); H4 covers it"

# --- payload for reroot.sh on the host: stub magiskboot, host kcmp
mkpayload() {  # dir rooted-blob base-blob
  local d=$1; rm -rf "$d"; mkdir -p "$d"
  printf '%s\nexec python3 -I %s "$@"\n' "$SHEBANG" "$REPO/tests/magiskboot-stub.py" > "$d/magiskboot"
  cp "$KC" "$d/kcmp"; cp "$REPO/reroot/reroot.sh" "$REPO/reroot/99-rksu.sh" "$d/"; chmod 755 "$d/magiskboot" "$d/kcmp"
  cp "$2" "$d/Image.gz-dtb"; sha "$d/Image.gz-dtb" > "$d/Image.gz-dtb.sha256"
  cp "$3" "$d/base-Image.gz-dtb"; sha "$d/base-Image.gz-dtb" > "$d/base-kernel.sha256"
  bash "$REPO/tools/kernel-source.sh" "$MAN_A" "$OFF_A" > "$d/kernel-source.txt"
  resum "$d"
}
resum() { (cd "$1" && sha256sum reroot.sh 99-rksu.sh magiskboot kcmp Image.gz-dtb Image.gz-dtb.sha256 base-Image.gz-dtb base-kernel.sha256 kernel-source.txt > payload.sha256); }
P0=$T/payload0
mkpayload "$P0" "$ROOTED" "$H/A.blob"
mkboot() {  # out base-boot kernel-blob : base-boot with its kernel section replaced
  local w=$T/mk; rm -rf "$w"; mkdir -p "$w"
  (cd "$w" && python3 -I "$REPO/tests/magiskboot-stub.py" unpack -n "$2" 2>/dev/null && rm -f kernel_dtb && cp "$3" kernel \
    && python3 -I "$REPO/tests/magiskboot-stub.py" repack -n "$2" "$1")
}
# tampered kernels repacked into B's boot image
python3 -I - "$H" <<'PY'
import gzip, sys
H = sys.argv[1]
for v in ("code4",):
    open(f"{H}/{v}.blob", "wb").write(gzip.compress(open(f"{H}/{v}.img", "rb").read(), 9, mtime=0) + open(f"{H}/B.dtb", "rb").read())
open(f"{H}/dtbbyte.blob", "wb").write(open(f"{H}/B.gz", "rb").read() + open(f"{H}/dtbbyte.dtb", "rb").read())
PY
mkboot "$T/boot-code4.img" "$OFF_B" "$H/code4.blob"
mkboot "$T/boot-dtbbyte.img" "$OFF_B" "$H/dtbbyte.blob"

run_reroot() {  # name payload-src want-result want-out-sha|- [env...] -- args...
  local name=$1 src=$2 want=$3 wsha=$4; shift 4
  local envs=(); while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  local d=$T/run/$name; rm -rf "$d"; mkdir -p "$d"; cp -a "$src" "$d/rksu"
  local before; before=$(cd "$d/rksu" && find . -type f -exec sha256sum {} + | sort)
  local args=("$@"); args=("${args[@]//@OUT@/$d/out.img}")
  env PATH="$DPATH" RKSU_DIR="$d/rksu" RKSU_WORK="$d/work" "${envs[@]}" "${DSH[@]}" "$d/rksu/reroot.sh" "${args[@]}" > "$d/log" 2>&1
  local rc=$? res; res=$(grep -o 'RESULT: .*' "$d/log" | tail -n 1)
  local why=""
  [[ $res == "RESULT: $want"* ]] || why+=" result"
  if [[ $wsha == - ]]; then [[ ! -e $d/out.img ]] || why+=" unexpected-output"
  elif [[ $wsha != any ]]; then [[ -f $d/out.img && $(sha "$d/out.img") == "$wsha" ]] || why+=" output-sha"; fi
  if [[ ${args[0]:-} == --test ]]; then
    [[ $(cd "$d/rksu" && find . -type f -exec sha256sum {} + | sort) == "$before" ]] || why+=" payload-changed-in-test-mode"
  fi
  [[ -d $d/work ]] && why+=" work-dir-left"
  if [[ -z $why ]]; then ok "$name: ${res:0:150}"; else bad "$name:$why (exit $rc): $res"; sed 's/^/        /' "$d/log" | tail -n 8; fi
  grep -E 'kcmp: image|decision:' "$d/log" | sed 's/^\[rksu [^]]*\] */        /'
}
WANT_A=$(sha "$ROOTED_A"); WANT_B=$(sha "$ROOTED_B")

echo "== H10 reroot.sh --test (dry runs; magiskboot stub, host kcmp)"
run_reroot exact-A "$P0" "REROOTED" "$WANT_A" -- --test "$OFF_A" @OUT@
run_reroot kcmp-B "$P0" "REROOTED" "$WANT_B" -- --test "$OFF_B" @OUT@
run_reroot kcmp-B-nosplit "$P0" "REROOTED" "$WANT_B" STUB_DTB_SPLIT=0 -- --test "$OFF_B" @OUT@
i=0; for e in ${EXTRA_BOOTS:-}; do i=$((i + 1)); run_reroot "kcmp-X$i" "$P0" "REROOTED" any -- --test "$e" @OUT@; done
run_reroot already "$P0" "ALREADY" "$WANT_B" -- --test "$ROOTED_B" @OUT@
run_reroot tampered-code "$P0" "NEEDS_REBUILD" - -- --test "$T/boot-code4.img" @OUT@
run_reroot tampered-dtb "$P0" "NEEDS_REBUILD" - -- --test "$T/boot-dtbbyte.img" @OUT@
[[ -n ${SHIFTED:-} ]] && run_reroot kcmp-shifted "$P0" "REROOTED" any -- --test "$SHIFTED" @OUT@
run_reroot decompress-fails "$P0" "FAILED kcmp path" - STUB_FAIL=decompress -- --test "$OFF_B" @OUT@
run_reroot decompress-truncated "$P0" "FAILED kcmp path" - STUB_DECOMPRESS_TRUNCATE=30000000 -- --test "$OFF_B" @OUT@
run_reroot low-tmp-space "$P0" "FAILED kcmp path" - RKSU_NEED_KB=999999999999 -- --test "$OFF_B" @OUT@
run_reroot unpack-fails "$P0" "FAILED" - STUB_FAIL=unpack -- --test "$OFF_B" @OUT@
run_reroot repack-fails "$P0" "FAILED" - STUB_FAIL=repack -- --test "$OFF_B" @OUT@
P=$T/p-crash; cp -a "$P0" "$P"; printf '%s\nkill -SEGV $$\n' "$SHEBANG" > "$P/kcmp"; resum "$P"
run_reroot kcmp-crashes "$P" "FAILED kcmp path" - -- --test "$OFF_B" @OUT@
for rc in 1 2 7 139; do   # kcmp whose split/check work but whose cmp exits $rc
  P=$T/p-cmp$rc; cp -a "$P0" "$P"
  printf '%s\ncase $1 in cmp) echo "fake kcmp cmp"; exit %s ;; esac\nexec %s "$@"\n' "$SHEBANG" "$rc" "$KC" > "$P/kcmp"; resum "$P"
  if [[ $rc == 1 ]]; then run_reroot "kcmp-cmp-exit-$rc" "$P" "NEEDS_REBUILD" - -- --test "$OFF_B" @OUT@
  else run_reroot "kcmp-cmp-exit-$rc" "$P" "FAILED kcmp path: kcmp cmp exit $rc" - -- --test "$OFF_B" @OUT@; fi
done
P=$T/p-tamper; cp -a "$P0" "$P"; printf '%s\nexit 0\n' "$SHEBANG" > "$P/kcmp"
run_reroot kcmp-not-in-manifest "$P" "FAILED" - -- --test "$OFF_B" @OUT@
P=$T/p-nokcmp; cp -a "$P0" "$P"; rm "$P/kcmp"
run_reroot kcmp-missing "$P" "FAILED" - -- --test "$OFF_B" @OUT@
P=$T/p-badbase; cp -a "$P0" "$P"; printf 'x' | dd of="$P/base-Image.gz-dtb" bs=1 seek=1000 conv=notrunc 2>/dev/null
run_reroot base-corrupt "$P" "FAILED" - -- --test "$OFF_B" @OUT@
P=$T/p-v1; cp -a "$P0" "$P"; rm "$P/payload.sha256" "$P/kcmp" "$P/base-Image.gz-dtb"
run_reroot v1-payload "$P" "FAILED" - -- --test "$OFF_B" @OUT@
P=$T/p-same; mkpayload "$P" "$H/A.blob" "$H/A.blob"
run_reroot rooted-equals-base "$P" "FAILED" - -- --test "$OFF_B" @OUT@
P=$T/p-dis; cp -a "$P0" "$P"; touch "$P/DISABLE"
run_reroot disable-ignored-in-test "$P" "REROOTED" "$WANT_B" -- --test "$OFF_B" @OUT@

echo "== H10 reroot.sh on a fake boot partition (a 40 MiB file; RKSU_BOOT)"
part() { cp "$1" "$2"; truncate -s 41943040 "$2"; }
partrun() {  # name payload want-result partition-image expect-prefix-sha|unchanged [env...]
  local name=$1 src=$2 want=$3 img=$4 exp=$5; shift 5
  local d=$T/part/$name; rm -rf "$d"; mkdir -p "$d"; cp -a "$src" "$d/rksu"; part "$img" "$d/boot"
  local orig; orig=$(sha "$d/boot")
  echo "old" > "$d/rksu/NEEDS_REBUILD"; head -c 300000 /dev/zero | tr '\0' 'x' > "$d/rksu/reroot.log"
  [[ $name == disabled ]] && touch "$d/rksu/DISABLE"
  env PATH="$DPATH" RKSU_DIR="$d/rksu" RKSU_WORK="$d/work" RKSU_BOOT="$d/boot" "$@" "${DSH[@]}" "$d/rksu/reroot.sh" >> "$d/rksu/reroot.log" 2>&1
  local res; res=$(grep -o 'RESULT: .*' "$d/rksu/reroot.log" | tail -n 1)
  local why=""
  [[ $res == "RESULT: $want"* ]] || why+=" result"
  if [[ $exp == unchanged ]]; then [[ $(sha "$d/boot") == "$orig" ]] || why+=" partition-changed"
  else
    local n; n=$(stat -c %s "$ROOTED_B")
    [[ $(head -c "$n" "$d/boot" | sha256sum | cut -d' ' -f1) == "$exp" ]] || why+=" partition-content"
  fi
  case $want in
    REROOTED|ALREADY) [[ ! -e $d/rksu/NEEDS_REBUILD ]] || why+=" NEEDS_REBUILD-kept" ;;
    NEEDS_REBUILD) grep -q 'needs a rebuild' "$d/rksu/NEEDS_REBUILD" || why+=" NEEDS_REBUILD-not-written" ;;
    FAILED*|DISABLED) [[ $(cat "$d/rksu/NEEDS_REBUILD") == old ]] || why+=" NEEDS_REBUILD-touched" ;;
  esac
  [[ -f $d/rksu/reroot.log.old && $(stat -c %s "$d/rksu/reroot.log") -lt 100000 ]] || why+=" log-not-rotated"
  if [[ -z $why ]]; then ok "$name: ${res:0:150}"; else bad "$name:$why: $res"; tail -n 8 "$d/rksu/reroot.log" | sed 's/^/        /'; fi
}
partrun write-B "$P0" REROOTED "$OFF_B" "$WANT_B"
partrun already "$P0" ALREADY "$ROOTED_B" "$WANT_B"
partrun disabled "$P0" DISABLED "$OFF_B" unchanged
partrun different-source "$P0" NEEDS_REBUILD "$T/boot-code4.img" unchanged
partrun repack-fails "$P0" FAILED "$OFF_B" unchanged STUB_FAIL=repack
partrun decompress-fails "$P0" "FAILED kcmp path" "$OFF_B" unchanged STUB_FAIL=decompress

echo "== H14 99-rksu.sh wrapper (fake /tmp/install/bin)"
hook() {  # name setup
  local d=$T/hook/$1; rm -rf "$d"; mkdir -p "$d/ib" "$d/rksu"
  printf '%s\nexit ${DC_RC:-0}\n' "$SHEBANG" > "$d/ib/device_check.sh"
  printf '%s\necho "stub reroot ran"\n' "$SHEBANG" > "$d/rksu/reroot.sh"
  case $2 in
    nodc) rm "$d/ib/device_check.sh" ;;
    nopayload) rm "$d/rksu/reroot.sh" ;;
  esac
  env PATH="$DPATH" RKSU_INSTALL_BIN="$d/ib" RKSU_DIR="$d/rksu" "${DSH[@]}" "$REPO/reroot/99-rksu.sh" post-restore > "$d/out" 2>&1
  echo "$d"
}
d=$(hook wrap normal)
if grep -q 'device_check.sh wrapped' "$d/rksu/reroot.log" && [[ -f $d/ib/device_check.rksu-orig.sh ]]; then ok "wraps device_check.sh, logs it"; else bad "wrap"; fi
env PATH="$DPATH" DC_RC=0 "$d/ib/device_check.sh"; r0=$?
env PATH="$DPATH" DC_RC=1 "$d/ib/device_check.sh"; r1=$?
[[ $r0 == 0 && $r1 == 1 && $(grep -c 'stub reroot ran' "$d/rksu/reroot.log") == 2 ]] && ok "wrapper keeps exit 0/1 and runs reroot.sh into reroot.log" || bad "wrapper exit $r0/$r1"
env PATH="$DPATH" RKSU_INSTALL_BIN="$d/ib" RKSU_DIR="$d/rksu" "${DSH[@]}" "$REPO/reroot/99-rksu.sh" post-restore >/dev/null 2>&1
grep -q 'already wrapped' "$d/rksu/reroot.log" && [[ $(grep -c 'rksu-orig' "$d/ib/device_check.sh") == 1 ]] && ok "second run: no double wrap, logged" || bad "double wrap"
d=$(hook nodc nodc); grep -q 'RESULT: FAILED hook not installed' "$d/rksu/reroot.log" && ok "device_check.sh missing: logged to reroot.log" || bad "nodc"
d=$(hook nopayload nopayload); grep -q 'payload missing' "$d/rksu/reroot.log" && [[ ! -f $d/ib/device_check.rksu-orig.sh ]] && ok "payload missing: logged, not wrapped" || bad "nopayload"

echo "== update-payload-device.sh (device half of update-payload.sh) against a fake /cache/rksu"
upd() {  # name want-sha expect(PASS|FAIL)
  local d=$T/upd/$1; rm -rf "$d"; mkdir -p "$d"; cp -a "$T/p-v1" "$d/rksu"; echo keep > "$d/rksu/reroot.log"
  local before; before=$(cd "$d/rksu" && find . -type f -exec sha256sum {} + | sort)
  cp -a "$P0" "$d/stage"; cp "$OFF_B" "$d/stage/stock-boot.img"
  env PATH="$DPATH" RKSU_DIR="$d/rksu" "${DSH[@]}" "$REPO/tools/update-payload-device.sh" "$d/stage" "$2" > "$d/out" 2>&1
  local res; res=$(grep -o 'UPDATE-PAYLOAD: .*' "$d/out")
  if [[ $3 == PASS ]]; then
    [[ $res == "UPDATE-PAYLOAD: PASS"* ]] && (cd "$d/rksu" && sha256sum --quiet -c payload.sha256) && grep -q keep "$d/rksu/reroot.log" \
      && ok "$1: $res" || { bad "$1: $res"; tail -n 5 "$d/out"; }
  else
    [[ $res == "UPDATE-PAYLOAD: FAIL"* && $(cd "$d/rksu" && find . -type f -exec sha256sum {} + | sort) == "$before" ]] \
      && ok "$1: ${res:0:120} (old payload byte-identical)" || { bad "$1: $res"; tail -n 5 "$d/out"; }
  fi
}
upd install-ok "$WANT_B" PASS
upd dry-run-mismatch "$(printf '0%.0s' {1..64})" FAIL

if [[ -n ${RKSU_APK:-} && -f ${RKSU_APK:-} ]]; then
  echo "== H11 installer zip (make-reroot-zip.sh)"
  Z=$T/zip; mkdir -p "$Z"
  if WORK=$Z MANIFEST=$MAN_A bash "$REPO/tools/make-reroot-zip.sh" "$RKSU_APK" "$ROOTED" "$OFF_A" "$Z/inst.zip" > "$Z/log" 2>&1; then
    python3 -I - "$Z/inst.zip" "$Z/payload" <<'PY' && ok "zip: all files, modes, payload.sha256 consistent; PC payload copy matches" || bad "zip contents"
import hashlib, os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); names = set(z.namelist())
need = ["reroot.sh", "99-rksu.sh", "magiskboot", "kcmp", "Image.gz-dtb", "Image.gz-dtb.sha256", "base-Image.gz-dtb",
        "base-kernel.sha256", "kernel-source.txt", "payload.sha256"]
assert {"META-INF/com/google/android/update-binary", "payload/99-rksu.sh"} <= names
for n in need:
    assert "payload/" + n in names, n
    assert z.read("payload/" + n) == open(os.path.join(sys.argv[2], n), "rb").read(), "PC copy " + n
listed = [l.split("  ")[1] for l in z.read("payload/payload.sha256").decode().splitlines()]
assert sorted(listed) == sorted(n for n in need if n != "payload.sha256"), listed
for line in z.read("payload/payload.sha256").decode().splitlines():
    h, n = line.split("  ")
    assert hashlib.sha256(z.read("payload/" + n)).hexdigest() == h, n
for n in ("magiskboot", "kcmp", "reroot.sh"):
    assert (z.getinfo("payload/" + n).external_attr >> 16) & 0o111, n
k = z.read("payload/kcmp"); assert k[:4] == b"\x7fELF" and k[18] == 183
print("        " + ", ".join(sorted(n[8:] for n in names if n.startswith("payload/"))))
PY
  else bad "make-reroot-zip failed"; tail -n 5 "$Z/log"; fi
  if WORK=$Z MANIFEST=$MAN_A bash "$REPO/tools/make-reroot-zip.sh" "$RKSU_APK" "$H/A.blob" "$OFF_A" "$Z/bad.zip" > "$Z/log2" 2>&1; then
    bad "zip with rooted == base kernel was accepted"; else ok "refuses rooted kernel == base kernel"; fi

  echo "== H12 prepare-ota.sh --check (local mirror + builds API fixture)"
  M=$T/mirror; mkdir -p "$M/full/joan/29990101"
  cp "$OFF_B" "$M/full/joan/29990101/boot.img"; cp "$MAN_B" "$M/full/joan/29990101/build-manifest.xml"
  # fake update zips: the real 10-25 updater-script order, and one with device_check.sh before boot.img
  python3 -I - "$M/full/joan/29990101" <<'PY'
import sys, zipfile
d = sys.argv[1]
good = [
    'run_program("/tmp/install/bin/backuptool.sh", "restore", map_partition("system"), "ext4");',
    'package_extract_file("boot.img", "/dev/block/bootdevice/by-name/boot");',
    'assert(run_program("/tmp/install/bin/device_check.sh") == 0);']
for name, lines in (("good.zip", good), ("bad.zip", [good[0], good[2], good[1]])):
    with zipfile.ZipFile(f"{d}/{name}", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("system.new.dat.br", b"\0" * 100000)
        z.writestr("META-INF/com/google/android/updater-script", "\n".join(lines) + "\n")
PY
  api() {  # boot-sha zip-name|-  -> builds.json
    python3 -I - "$M" "$1" "${2:-good.zip}" <<'PY'
import hashlib, json, os, sys
m, bsha, zname = sys.argv[1], sys.argv[2], sys.argv[3]
d = f"{m}/full/joan/29990101"
f = lambda n: hashlib.sha256(open(f"{d}/{n}", "rb").read()).hexdigest()
files = [{"filename": "boot.img", "sha256": bsha or f("boot.img")}, {"filename": "build-manifest.xml", "sha256": f("build-manifest.xml")}]
if zname != "-":
    files.insert(0, {"filename": zname, "sha256": f(zname), "size": os.path.getsize(f"{d}/{zname}")})
json.dump([{"date": "2999-01-01", "files": files}], open(f"{m}/builds.json", "w"))
PY
  }
  po() {  # name payload expected-exit grep
    local out rc; out=$(LINEAGE_API="file://$M/builds.json" LINEAGE_MIRROR="file://$M" PAYLOAD_DIR=$2 OTA_WORK=$T/ota-$1 \
      bash "$REPO/tools/prepare-ota.sh" --check 29990101 2>&1); rc=$?
    if [[ $rc == "$3" ]] && grep -q "$4" <<<"$out"; then ok "$1: exit $rc, $(grep -m1 -o 'RESULT: .*\|ABORT: .*' <<<"$out")"
    else bad "$1: exit $rc"; tail -n 6 <<<"$out" | sed 's/^/        /'; fi
    grep -E 'CHANGED|kcmp: image|boot.img written' <<<"$out" | sed 's/^ */        /'
  }
  api ""; po same-source "$Z/payload" 0 "RESULT: same source: the hook will re-root"
  cp -a "$Z/payload" "$T/pl-rev"; sed -i 's/^kernel\/lge\/msm8998 .*/kernel\/lge\/msm8998 0000000000000000000000000000000000000000/' "$T/pl-rev/kernel-source.txt"
  (cd "$T/pl-rev" && grep -v '  payload.sha256$' payload.sha256 | cut -d' ' -f3 | xargs sha256sum > p.new && mv p.new payload.sha256)
  po kernel-commit-changed "$T/pl-rev" 3 "RESULT: kernel source changed: rebuild"
  cp -a "$Z/payload" "$T/pl-tc"; sed -i 's/^prebuilts\/clang\/host\/linux-x86 .*/prebuilts\/clang\/host\/linux-x86 1111111111111111111111111111111111111111/' "$T/pl-tc/kernel-source.txt"
  (cd "$T/pl-tc" && grep -v '  payload.sha256$' payload.sha256 | cut -d' ' -f3 | xargs sha256sum > p.new && mv p.new payload.sha256)
  po toolchain-changed "$T/pl-tc" 3 "CHANGED  prebuilts/clang"
  cp -a "$Z/payload" "$T/pl-k"; cp "$H/code4.blob" "$T/pl-k/base-Image.gz-dtb"; sha "$T/pl-k/base-Image.gz-dtb" > "$T/pl-k/base-kernel.sha256"
  (cd "$T/pl-k" && grep -v '  payload.sha256$' payload.sha256 | cut -d' ' -f3 | xargs sha256sum > p.new && mv p.new payload.sha256)
  po same-revs-kcmp-declines "$T/pl-k" 3 "NOTE: the manifest revisions match, but kcmp declines"
  api "" bad.zip; po updater-order-changed "$Z/payload" 4 "RESULT: updater-script changed"
  api "" -; po no-zip-listed "$Z/payload" 0 "WARNING: could not check the updater-script"
  api "$(printf 'f%.0s' {1..64})"; po bad-sha "$Z/payload" 1 "ABORT: boot.img sha256"
else
  echo "== H11/H12 skipped (set RKSU_APK)"
fi

echo
echo "host tests: $PASS passed, $FAILN failed"
[[ $FAILN == 0 ]]
