#!/usr/bin/env python3
"""Host stand-in for magiskboot (tests only): the subset reroot.sh uses, for Android boot image header v0.
  unpack -n <boot.img>          -> kernel [kernel_dtb] ramdisk.cpio [second] in the current directory
  repack -n <orig.img> <out>    -> orig's header with the current kernel (+kernel_dtb) / ramdisk.cpio / second
  decompress <in> <out>         -> gunzip
STUB_DTB_SPLIT=1 splits appended DTBs off the kernel into kernel_dtb the way magiskboot's find_dtb_offset() does
(first FDT magic with a sane header); 0 keeps them in kernel. repack lays the image out like AOSP mkbootimg
(page-aligned sections, SHA-1 id over kernel/ramdisk/second), which real magiskboot matches for these images.
STUB_FAIL=unpack|repack|decompress makes that command fail; STUB_DECOMPRESS_TRUNCATE=N truncates its output."""
import hashlib, os, struct, sys, zlib

def die(msg):
    print("magiskboot-stub: " + msg, file=sys.stderr)
    sys.exit(1)

def pad(n, page):
    return (page - n % page) % page

def dtb_offset(k):
    i = 0
    while True:
        i = k.find(b"\xd0\x0d\xfe\xed", i)
        if i < 0:
            return -1
        rest = len(k) - i
        if i + 12 <= len(k):
            total, off_struct = struct.unpack_from(">II", k, i + 4)
            if total <= rest and off_struct + 4 <= rest and struct.unpack_from(">I", k, i + off_struct)[0] == 1:
                return i
        i += 4

def parse(path):
    b = open(path, "rb").read()
    if b[:8] != b"ANDROID!":
        die("not a boot image: " + path)
    ksize, kaddr, rsize, raddr, ssize, saddr, tags, page = struct.unpack_from("<8I", b, 8)
    if struct.unpack_from("<I", b, 40)[0] != 0:
        die("stub supports header v0 only")
    o = page
    k = b[o:o + ksize]; o += ksize + pad(ksize, page)
    r = b[o:o + rsize]; o += rsize + pad(rsize, page)
    s = b[o:o + ssize]
    return b, page, k, r, s

cmd = sys.argv[1:]
if os.environ.get("STUB_FAIL") and cmd and cmd[0] == os.environ["STUB_FAIL"]:
    die("forced failure of " + cmd[0])
if cmd[:2] == ["unpack", "-n"] and len(cmd) == 3:
    b, page, k, r, s = parse(cmd[2])
    if os.environ.get("STUB_DTB_SPLIT", "1") == "1" and (d := dtb_offset(k)) > 0:
        open("kernel_dtb", "wb").write(k[d:])
        k = k[:d]
    open("kernel", "wb").write(k)
    open("ramdisk.cpio", "wb").write(r)
    if s:
        open("second", "wb").write(s)
    print(f"KERNEL_SZ [{len(k)}]", file=sys.stderr)
elif cmd[:2] == ["repack", "-n"] and len(cmd) == 4:
    b, page, _, _, _ = parse(cmd[2])
    k = open("kernel", "rb").read() + (open("kernel_dtb", "rb").read() if os.path.exists("kernel_dtb") else b"")
    r = open("ramdisk.cpio", "rb").read() if os.path.exists("ramdisk.cpio") else b""
    s = open("second", "rb").read() if os.path.exists("second") else b""
    sha = hashlib.sha1()
    for part in (k, r, s):
        sha.update(part); sha.update(struct.pack("<I", len(part)))
    hdr = bytearray(b[:page])
    struct.pack_into("<I", hdr, 8, len(k))
    struct.pack_into("<I", hdr, 16, len(r))
    struct.pack_into("<I", hdr, 24, len(s))
    hdr[576:608] = sha.digest().ljust(32, b"\0")
    out = bytes(hdr)
    for part in (k, r, s):
        out += part + b"\0" * pad(len(part), page)
    open(cmd[3], "wb").write(out)
elif cmd[:1] == ["decompress"] and len(cmd) == 3:
    data = open(cmd[1], "rb").read()
    if data[:2] != b"\x1f\x8b":
        die("unsupported format")
    try:
        raw = zlib.decompressobj(31).decompress(data)
    except zlib.error as e:
        die(str(e))
    if os.environ.get("STUB_DECOMPRESS_TRUNCATE"):
        raw = raw[:int(os.environ["STUB_DECOMPRESS_TRUNCATE"])]
    open(cmd[2], "wb").write(raw)
else:
    die("unsupported: " + " ".join(cmd))
