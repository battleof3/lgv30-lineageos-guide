/* kcmp: decide whether two arm64 kernels (LineageOS joan Image.gz-dtb) were built from the same source.
 *
 *   kcmp split <Image.gz-dtb> <head-out> <dtbs-out>
 *       split a kernel blob into the part before the appended DTBs (the gzip'd Image) and the DTB tail
 *       (concatenated FDT blobs running exactly to the end of the file; empty if there are none)
 *   kcmp check <Image.gz> <Image>
 *       sanity-check a decompression: gzip magic, gzip ISIZE == Image size, plausible arm64 Image
 *   kcmp cmp [-v] <ImageA> <dtbsA> <ImageB> <dtbsB>
 *       compare two raw (decompressed) Images and their DTB tails; one-line report on stdout
 *
 * Exit status: 0 = OK / same source, 1 = different / check failed, 2 = usage or I/O error.
 * Only 0 means "same source"; callers must test for 0 explicitly.
 *
 * "Same source" means: both inputs are plausible arm64 Images (magic, >= MIN_IMAGE bytes) of equal size;
 * every differing byte lies inside a region that a clean rebuild of the same source is known to change
 * (build stamps located by content, see explain()), with zero unexplained bytes; at most LIMIT differing
 * bytes in total; and both DTB tails parse completely into the same non-empty multiset of blobs (byte-exact,
 * order ignored, no masking).
 *
 * Builds two ways (see tools/build-kcmp.sh):
 *   host:    cc -O2 -o kcmp kcmp.c                                     (libc, for tests on the PC)
 *   phone:   clang --target=aarch64-linux-gnu -DKCMP_NOLIBC ... -static -nostdlib   (no libc, raw syscalls)
 */

#define LIMIT 4096           /* max differing bytes; justified in ota-reroot DESIGN.md (observed: 1145) */
#define MIN_IMAGE (16UL << 20) /* the joan Image is ~41 MiB; anything under 16 MiB is not a kernel */
#define MAX_DTBS 64
#define MAX_SCAN 512         /* longest build-stamp string we look at */

typedef unsigned char u8;
typedef unsigned long ul;

#ifdef KCMP_NOLIBC
/* ---- aarch64 Linux, raw syscalls (like actl.c) ---- */
static long sys(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e, x5 __asm__("x5") = f;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}
#define SYS_openat 56
#define SYS_close 57
#define SYS_lseek 62
#define SYS_write 64
#define SYS_exit 93
#define SYS_mmap 222
static long os_open(const char *p, int wr) {
	/* O_RDONLY, or O_WRONLY|O_CREAT|O_TRUNC (01|0100|01000), mode 0644 */
	return sys(SYS_openat, -100, (long)p, wr ? 01101 : 0, 0644, 0, 0);
}
static long os_close(long fd) { return sys(SYS_close, fd, 0, 0, 0, 0, 0); }
static long os_size(long fd) { return sys(SYS_lseek, fd, 0, 2 /* SEEK_END */, 0, 0, 0); }
static long os_write(long fd, const void *b, ul n) { return sys(SYS_write, fd, (long)b, n, 0, 0, 0); }
static void *os_map(long fd, ul n) { return (void *)sys(SYS_mmap, 0, n, 1 /* PROT_READ */, 2 /* MAP_PRIVATE */, fd, 0); }
static void os_exit(int c) { sys(SYS_exit, c, 0, 0, 0, 0, 0); for (;;) {} }
/* the compiler may emit calls to these */
void *memcpy(void *d, const void *s, ul n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, ul n) { char *a = d; while (n--) *a++ = (char)c; return d; }
int memcmp(const void *x, const void *y, ul n) {
	const u8 *a = x, *b = y;
	for (; n; n--, a++, b++) if (*a != *b) return *a - *b;
	return 0;
}
int bcmp(const void *x, const void *y, ul n) { return memcmp(x, y, n); }
#else
/* ---- host build ---- */
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
static long os_open(const char *p, int wr) { return wr ? open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644) : open(p, O_RDONLY); }
static long os_close(long fd) { return close(fd); }
static long os_size(long fd) { return lseek(fd, 0, SEEK_END); }
static long os_write(long fd, const void *b, ul n) { return write(fd, b, n); }
static void *os_map(long fd, ul n) { return mmap(0, n, PROT_READ, MAP_PRIVATE, fd, 0); }
static void os_exit(int c) { exit(c); }
#endif

/* ---- output ---- */
static ul slen(const char *s) { ul n = 0; while (s[n]) n++; return n; }
static void out(const char *s) { os_write(1, s, slen(s)); }
static void outn(ul v) {
	char b[24]; int i = 23; b[i] = 0;
	do { b[--i] = '0' + v % 10; v /= 10; } while (v);
	out(b + i);
}
static void outx(ul v) {
	char b[24]; int i = 23; b[i] = 0;
	do { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
	b[--i] = 'x'; b[--i] = '0';
	out(b + i);
}
static void die(const char *m, const char *arg) {
	out("kcmp: "); out(m); if (arg) { out(" "); out(arg); } out("\n");
	os_exit(2);
}

/* ---- files ---- */
struct buf { const u8 *p; ul n; };

static struct buf map_file(const char *path) {
	struct buf b = { 0, 0 };
	long fd = os_open(path, 0);
	if (fd < 0) die("cannot open", path);
	long n = os_size(fd);
	if (n < 0) die("cannot size", path);
	if (n > 0) {
		void *p = os_map(fd, n);
		if ((ul)p >= (ul)-4095) die("cannot map", path);
		b.p = p;
	}
	b.n = n;
	os_close(fd);
	return b;
}

static void write_file(const char *path, const u8 *p, ul n) {
	long fd = os_open(path, 1);
	if (fd < 0) die("cannot create", path);
	while (n) {
		long w = os_write(fd, p, n > (1UL << 20) ? (1UL << 20) : n);
		if (w <= 0) die("write failed:", path);
		p += w; n -= w;
	}
	if (os_close(fd) < 0) die("close failed:", path);
}

/* ---- helpers ---- */
static int eq(const u8 *a, const u8 *b, ul n) { while (n--) if (*a++ != *b++) return 0; return 1; }
static ul be32(const u8 *p) { return (ul)p[0] << 24 | (ul)p[1] << 16 | (ul)p[2] << 8 | p[3]; }
static ul le64(const u8 *p) { ul v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static int has(const u8 *p, ul n, const char *needle) {
	ul m = slen(needle);
	for (ul i = 0; i + m <= n; i++) if (eq(p + i, (const u8 *)needle, m)) return 1;
	return 0;
}

/* ---- DTB tails ---- */
static const u8 FDT_MAGIC[4] = { 0xd0, 0x0d, 0xfe, 0xed };

/* length of the plausible FDT header at p (n bytes available), or 0 */
static ul fdt_len(const u8 *p, ul n) {
	if (n < 40 || !eq(p, FDT_MAGIC, 4)) return 0;
	ul total = be32(p + 4), off_struct = be32(p + 8), version = be32(p + 20), last_comp = be32(p + 24);
	if (total < 40 || total > n || off_struct >= total || version < 16 || last_comp > 17) return 0;
	return total;
}

/* number of FDT blobs if [p, p+n) is exactly a chain of them, else -1; offsets/lengths stored if wanted */
static long fdt_chain(const u8 *p, ul n, ul *off, ul *len) {
	long k = 0;
	for (ul o = 0; o < n; k++) {
		ul l = fdt_len(p + o, n - o);
		if (!l || k >= MAX_DTBS) return -1;
		if (off) { off[k] = o; len[k] = l; }
		o += l;
	}
	return k;
}

static int do_split(char **argv) {
	struct buf b = map_file(argv[2]);
	ul t = b.n;   /* start of the DTB tail: first FDT header from which a chain of FDTs ends exactly at EOF */
	for (ul i = 0; i + 40 <= b.n; i++)
		if (b.p[i] == 0xd0 && eq(b.p + i, FDT_MAGIC, 4) && fdt_chain(b.p + i, b.n - i, 0, 0) > 0) { t = i; break; }
	write_file(argv[3], b.p, t);
	write_file(argv[4], b.p + t, b.n - t);
	out("kcmp: split "); outn(b.n); out(" bytes: head "); outn(t); out(", ");
	outn(t < b.n ? fdt_chain(b.p + t, b.n - t, 0, 0) : 0); out(" dtbs ("); outn(b.n - t); out(" bytes)\n");
	return 0;
}

static int plausible_image(struct buf X) { return X.n >= MIN_IMAGE && eq(X.p + 0x38, (const u8 *)"ARM\x64", 4); }

static int do_check(char **argv) {
	struct buf G = map_file(argv[2]), I = map_file(argv[3]);
	ul isize = G.n >= 18 ? (ul)G.p[G.n - 4] | (ul)G.p[G.n - 3] << 8 | (ul)G.p[G.n - 2] << 16 | (ul)G.p[G.n - 1] << 24 : 0;
	const char *why = 0;
	if (G.n < 18 || G.p[0] != 0x1f || G.p[1] != 0x8b || G.p[2] != 8) why = "not a gzip file";
	else if (isize != (I.n & 0xffffffffUL)) why = "gzip ISIZE does not match the Image size";
	else if (!plausible_image(I)) why = "not a plausible arm64 Image";
	out("kcmp: check gzip "); outn(G.n); out(" isize "); outn(isize); out(" image "); outn(I.n);
	out(why ? " | FAILED (" : " | OK"); if (why) { out(why); out(")"); } out("\n");
	return why ? 1 : 0;
}

/* ---- known build-stamp regions ----
 * A clean rebuild of the same source changes only these (measured on the 09-20, 10-04, 10-18 and 10-25 official
 * joan kernels, all kernel commit c022ed57). Each is located by content in both Images, never by a fixed offset:
 *   banner      init/version.c: linux_banner "Linux version ... (root@<host>) ... #1 SMP PREEMPT <date>\n"
 *               immediately followed by linux_proc_banner "%s version %s (root@<host>) ...". The date is not
 *               padded ("Oct 4" vs "Sep 20"), so linux_proc_banner can move by a byte or two inside the padding.
 *   banner-ref  at most MAX_BANNER_REFS references to a moved linux_proc_banner: 64-bit pointers equal to the
 *               Image link address (KIMAGE_VADDR + text_offset) + its offset in each Image, and ADD #:lo12: whose
 *               only change is that offset and whose register comes from an identical ADRP of the banner's page.
 *   uts         init_uts_ns.version "#1 SMP PREEMPT <date>" (a fixed 65-byte field)
 *   build-id    the GNU build-id ELF note (20 bytes after its 16-byte header)
 *   cert        certs/: the module-signing X.509 certificate generated at build time ("Build time autogenerated
 *               kernel key": fresh key, serial, dates, signature), located by its DER header and length
 *   initramfs   usr/: the built-in initramfs, a gzip'd cpio of /dev, /dev/console, /root whose mtimes are the
 *               build time, plus the __initramfs_size word after it
 * Everything else, including the embedded kernel config (IKCONFIG), must be byte-identical. */
enum { R_NONE, R_BANNER, R_BANNER_REF, R_UTS, R_BUILDID, R_CERT, R_INITRAMFS, R_KINDS };
static const char *RNAME[] = { "unexplained", "banner", "banner-ref", "uts", "build-id", "cert", "initramfs" };

#define MAX_UTS 4
#define KIMAGE_VADDR 0xffffff8008000000UL   /* arm64 Linux 4.4 with VA_BITS=39 (joan): VA_START + 128 MiB modules */
#define MAX_BANNER_REFS 4                    /* references to linux_proc_banner that may move (observed: 2) */
struct stamps {
	ul lb, pb, pe;                 /* linux_banner, linux_proc_banner, end of it (its NUL); lb == 0: not found */
	int nuts; ul uts[MAX_UTS], utse[MAX_UTS];   /* UTS version strings: start, end (NUL) */
};

static int printable(u8 c) { return (c >= 0x20 && c < 0x7f) || c == '\n'; }
/* end (offset of the NUL) of the printable string starting at s, or 0 */
static ul str_end(const u8 *p, ul n, ul s, ul max) {
	ul e = s;
	while (e < n && e - s < max && printable(p[e])) e++;
	return e < n && p[e] == 0 && e > s ? e : 0;
}
static int starts(const u8 *p, ul n, ul at, const char *lit) { ul m = slen(lit); return at + m <= n && eq(p + at, (const u8 *)lit, m); }

static void find_stamps(struct buf X, struct stamps *st) {
	const u8 *p = X.p; ul n = X.n;
	int nb = 0;
	st->lb = 0; st->nuts = 0;
	for (ul i = 1; i + 16 < n; i++) {
		if (p[i] == 'L' && p[i - 1] == 0 && starts(p, n, i, "Linux version ")) {
			ul e1 = str_end(p, n, i, MAX_SCAN), e2;
			if (e1 && starts(p, n, e1 + 1, "%s version %s (") && (e2 = str_end(p, n, e1 + 1, MAX_SCAN))) {
				st->lb = i; st->pb = e1 + 1; st->pe = e2; nb++;
			}
		} else if (p[i] == '#' && p[i - 1] == 0 && p[i + 1] >= '0' && p[i + 1] <= '9') {
			ul e = str_end(p, n, i, 65);
			if (e && has(p + i, e - i, " SMP")) {
				if (st->nuts == MAX_UTS) { st->nuts = MAX_UTS + 1; continue; }
				if (st->nuts < MAX_UTS) { st->uts[st->nuts] = i; st->utse[st->nuts] = e; st->nuts++; }
			}
		}
	}
	if (nb != 1) st->lb = 0;               /* ambiguous or missing: no banner region at all */
	if (st->nuts > MAX_UTS) st->nuts = 0;
}

static const u8 NOTE_GNU_BUILD_ID[16] = { 4, 0, 0, 0, 20, 0, 0, 0, 3, 0, 0, 0, 'G', 'N', 'U', 0 };
static const u8 CERT_HDR[5] = { 0xa0, 0x03, 0x02, 0x01, 0x02 };   /* TBSCertificate: version [0] v3 */

/* x509 Certificate SEQUENCE starting at p: 30 82 LL LL 30 82 ll ll a0 03 02 01 02; returns total length */
static ul cert_len(const u8 *p, ul avail) {
	if (avail < 13 || p[0] != 0x30 || p[1] != 0x82 || p[4] != 0x30 || p[5] != 0x82 || !eq(p + 8, CERT_HDR, 5)) return 0;
	ul l = 4 + ((ul)p[2] << 8 | p[3]);
	return l <= avail ? l : 0;
}

/* initramfs at p (gzip member, 4-aligned): __initramfs_size (le64, 8-aligned) follows it; returns end of region */
static ul initramfs_end(const u8 *p, ul n, ul at) {
	for (ul sz = 18; sz <= 4096; sz++) {
		ul q = (at + sz + 7) & ~7UL;
		if (q + 8 > n) break;
		if (le64(p + q) == sz) return q + 8;
	}
	return 0;
}
static unsigned le32(const u8 *p) { return (unsigned)p[0] | (unsigned)p[1] << 8 | (unsigned)p[2] << 16 | (unsigned)p[3] << 24; }

static int explain(struct buf A, struct buf B, const struct stamps *sa, const struct stamps *sb, ul i, ul *rs, ul *re) {
	ul n = A.n;
	/* banner block: same start in both; may end at different offsets */
	if (sa->lb && sb->lb && sa->lb == sb->lb) {
		ul e = (sa->pe > sb->pe ? sa->pe : sb->pe) + 1;
		if (i >= sa->lb && i < e) { *rs = sa->lb; *re = e; return R_BANNER; }
	}
	/* UTS version fields at the same offset in both */
	for (int a = 0; a < sa->nuts; a++)
		for (int b = 0; b < sb->nuts; b++)
			if (sa->uts[a] == sb->uts[b]) {
				ul e = (sa->utse[a] > sb->utse[b] ? sa->utse[a] : sb->utse[b]) + 1;
				if (i >= sa->uts[a] && i < e) { *rs = sa->uts[a]; *re = e; return R_UTS; }
			}
	/* references to a moved linux_proc_banner (moved <= 64 bytes, within its 4 KiB page); the caller allows at most
	 * MAX_BANNER_REFS of them in total */
	if (sa->lb && sb->lb && sa->lb == sb->lb && sa->pb != sb->pb) {
		ul pa = sa->pb, pb = sb->pb, d = pa > pb ? pa - pb : pb - pa;
		ul q = i & ~7UL, w = i & ~3UL;
		ul base = KIMAGE_VADDR + le64(A.p + 8);   /* link address of the Image: KIMAGE_VADDR + text_offset */
		if (d > 64 || (pa >> 12) != (pb >> 12) || !eq(A.p + 8, B.p + 8, 8)) return R_NONE;
		/* a 64-bit pointer to linux_proc_banner in each Image */
		if (q + 8 <= n && le64(A.p + q) == base + pa && le64(B.p + q) == base + pb) { *rs = q; *re = q + 8; return R_BANNER_REF; }
		/* ADD Xd, Xn, #:lo12:linux_proc_banner, whose Xn comes from an identical ADRP of the banner's page */
		if (w + 4 <= n) {
			unsigned ia = le32(A.p + w), ib = le32(B.p + w), imm = 0xfffu << 10, rn = (ia >> 5) & 31;
			if ((ia & 0xffc00000u) == 0x91000000u && (ia & ~imm) == (ib & ~imm) &&
			    ((ia & imm) >> 10) == (pa & 0xfff) && ((ib & imm) >> 10) == (pb & 0xfff)) {
				for (ul k = 1; k <= 8 && 4 * k <= w; k++) {
					ul v = w - 4 * k;
					unsigned x = le32(A.p + v);
					if ((x & 0x9f000000u) != 0x90000000u || (x & 31) != rn) continue;   /* ADRP Xrn */
					long off = (long)((((x >> 5) & 0x7ffff) << 2) | ((x >> 29) & 3));
					if (off & (1L << 20)) off -= 1L << 21;
					ul page = ((base + v) & ~0xfffUL) + (ul)(off << 12);
					if (le32(B.p + v) == x && page == ((base + pa) & ~0xfffUL)) { *rs = w; *re = w + 4; return R_BANNER_REF; }
					break;   /* the nearest ADRP to Xrn does not point at the banner's page */
				}
			}
		}
	}
	/* GNU build-id: 16-byte note header then 20 bytes of id */
	for (ul k = 16; k < 36 && k <= i; k++) {
		ul p = i - k;
		if (eq(A.p + p, NOTE_GNU_BUILD_ID, 16) && eq(B.p + p, NOTE_GNU_BUILD_ID, 16)) { *rs = p + 16; *re = p + 36; return R_BUILDID; }
	}
	/* the build-time module-signing certificate (same DER length in both) */
	for (ul k = 0; k <= 8192 && k <= i; k++) {
		ul p = i - k, l = cert_len(A.p + p, n - p);
		if (!l || p + l <= i || !eq(A.p + p, B.p + p, 4) || cert_len(B.p + p, n - p) != l) continue;
		if (has(A.p + p, l, "Build time autogenerated kernel key") && has(B.p + p, l, "Build time autogenerated kernel key")) {
			*rs = p; *re = p + l; return R_CERT;
		}
	}
	/* built-in initramfs: gzip header 1f 8b 08, FLG 0, OS 3 (unix); mtime and compressed data may differ */
	for (ul k = 0; k <= 4096 && k <= i; k++) {
		ul p = i - k;
		if ((p & 3) || p + 10 > n) continue;
		const u8 *a = A.p + p, *b = B.p + p;
		if (a[0] != 0x1f || a[1] != 0x8b || a[2] != 8 || a[3] != 0 || a[9] != 3 || !eq(a, b, 4) || a[8] != b[8] || b[9] != 3) continue;
		ul ea = initramfs_end(A.p, n, p), eb = initramfs_end(B.p, n, p);
		if (!ea || !eb) continue;
		ul e = ea > eb ? ea : eb;
		if (i < e) { *rs = p; *re = e; return R_INITRAMFS; }
	}
	return R_NONE;
}

static int do_cmp(int argc, char **argv) {
	int verbose = 0, a0 = 2;
	if (argc > 2 && argv[2][0] == '-' && argv[2][1] == 'v') { verbose = 1; a0 = 3; }
	if (argc != a0 + 4) die("usage: kcmp cmp [-v] <ImageA> <dtbsA> <ImageB> <dtbsB>", 0);
	struct buf A = map_file(argv[a0]), DA = map_file(argv[a0 + 1]), B = map_file(argv[a0 + 2]), DB = map_file(argv[a0 + 3]);
	int same = 1;
	const char *why = 0;

	if (!plausible_image(A) || !plausible_image(B)) {
		out("kcmp: image "); outn(A.n); out(" "); outn(B.n); out(" | DIFFERENT (not a plausible arm64 Image)\n");
		return 1;
	}

	/* Image */
	ul diff = 0, unexplained = 0, per[R_KINDS] = { 0 };
	int explained_done = 0;
	if (A.n != B.n) { same = 0; why = "Image size differs"; }
	else {
		for (ul i = 0; i < A.n; i++) diff += A.p[i] != B.p[i];
		if (diff > LIMIT) { same = 0; why = "too many differing bytes"; }
		else {
			static struct stamps sa, sb;
			find_stamps(A, &sa); find_stamps(B, &sb);
			ul rs = 0, re = 0, refs = 0;
			int r = R_NONE, toomanyrefs = 0;
			for (ul i = 0; i < A.n; i++) {
				if (A.p[i] == B.p[i]) continue;
				if (i < re) { per[r]++; continue; }
				r = explain(A, B, &sa, &sb, i, &rs, &re);
				if (r == R_BANNER_REF && ++refs > MAX_BANNER_REFS) { r = R_NONE; toomanyrefs = 1; }
				if (verbose) {
					out("  "); outx(r ? rs : i); out(" +"); outn(r ? re - rs : 1); out(" "); out(RNAME[r]); out("\n");
				}
				per[r]++;
				if (!r) { unexplained++; re = 0; }
			}
			explained_done = 1;
			if (unexplained) { same = 0; why = toomanyrefs ? "too many banner references moved" : "differences outside build stamps"; }
		}
	}

	/* DTBs: same multiset of blobs */
	static ul oa[MAX_DTBS], la[MAX_DTBS], ob[MAX_DTBS], lb[MAX_DTBS];
	static u8 used[MAX_DTBS];
	long na = DA.n ? fdt_chain(DA.p, DA.n, oa, la) : 0, nb = DB.n ? fdt_chain(DB.p, DB.n, ob, lb) : 0;
	long matched = 0;
	if (na < 0 || nb < 0) { same = 0; if (!why) why = "malformed DTB tail"; }
	else {
		for (long j = 0; j < nb; j++) used[j] = 0;
		for (long i = 0; i < na; i++)
			for (long j = 0; j < nb; j++)
				if (!used[j] && la[i] == lb[j] && eq(DA.p + oa[i], DB.p + ob[j], la[i])) { used[j] = 1; matched++; break; }
		if (na == 0 || nb == 0) { same = 0; if (!why) why = "no DTBs"; }
		else if (na != nb || matched != na) { same = 0; if (!why) why = "DTBs differ"; }
	}

	out("kcmp: image "); outn(A.n); out(" "); outn(B.n);
	out(" | diff ");
	if (A.n == B.n) {
		outn(diff); out(" bytes (limit "); outn(LIMIT); out(")");
		if (explained_done)
			for (int k = 1; k < R_KINDS; k++) if (per[k]) { out(" "); out(RNAME[k]); out(" "); outn(per[k]); }
		out(" unexplained "); if (explained_done) outn(unexplained); else out("-");
	} else out("-");
	out(" | dtb "); outn(na < 0 ? 0 : na); out(" "); outn(nb < 0 ? 0 : nb); out(" matched "); outn(matched);
	out(" | "); out(same ? "SAME" : "DIFFERENT"); if (why) { out(" ("); out(why); out(")"); }
	out("\n");
	return same ? 0 : 1;
}

static int run(int argc, char **argv) {
	if (argc == 5 && eq((const u8 *)argv[1], (const u8 *)"split", 6)) return do_split(argv);
	if (argc == 4 && eq((const u8 *)argv[1], (const u8 *)"check", 6)) return do_check(argv);
	if (argc >= 6 && eq((const u8 *)argv[1], (const u8 *)"cmp", 4)) return do_cmp(argc, argv);
	die("usage: kcmp split <Image.gz-dtb> <head-out> <dtbs-out> | check <Image.gz> <Image> | cmp [-v] <ImageA> <dtbsA> <ImageB> <dtbsB>", 0);
	return 2;
}

#ifdef KCMP_NOLIBC
int cmain(long *sp) { os_exit(run((int)sp[0], (char **)(sp + 1))); return 0; }
__asm__(".global _start\n_start:\n\tmov x0, sp\n\tbl cmain\n");
#else
int main(int argc, char **argv) { return run(argc, argv); }
#endif
