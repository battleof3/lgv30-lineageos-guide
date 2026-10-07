/* actl: minimal ALSA mixer-control reader/writer for the V30 (no libc; raw syscalls).
 *   actl r "<control name>"            print type, count, values (enum: index + text)
 *   actl w "<control name>" v0 [v1..]  write integer / enum-index values
 * Card 0 only (/dev/snd/controlC0). */
struct timespec { long tv_sec; long tv_nsec; };
#include <linux/ioctl.h>
#include <sound/asound.h>

static long sys(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define SYS_openat 56
#define SYS_ioctl 29
#define SYS_write 64
#define SYS_exit 93

static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void out(const char *s) { sys(SYS_write, 1, (long)s, slen(s), 0); }
static void outl(long v) {
	char b[24]; int i = 23; int neg = v < 0; unsigned long u = neg ? -v : v;
	b[i] = 0; do { b[--i] = '0' + u % 10; u /= 10; } while (u);
	if (neg) b[--i] = '-';
	out(b + i);
}
static long atol_(const char *s) { long v = 0; int neg = *s == '-'; if (neg) s++; while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0'; return neg ? -v : v; }
static void *zero(void *p, unsigned long n) { char *c = p; while (n--) *c++ = 0; return p; }
static void die(const char *m) { out(m); out("\n"); sys(SYS_exit, 1, 0, 0, 0); }

/* struct copies compile to these */
void *memcpy(void *d, const void *s, unsigned long n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, unsigned long n) { char *a = d; while (n--) *a++ = (char)c; return d; }

static struct snd_ctl_elem_info info;
static struct snd_ctl_elem_value val;

int cmain(long *sp) {
	long argc = sp[0]; char **argv = (char **)(sp + 1);
	if (argc < 3) die("usage: actl r|w <name> [values]");
	long fd = sys(SYS_openat, -100, (long)"/dev/snd/controlC0", 2 /* O_RDWR */, 0);
	if (fd < 0) die("open /dev/snd/controlC0 failed");
	zero(&info, sizeof info);
	info.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
	unsigned long n = slen(argv[2]); if (n >= sizeof info.id.name) die("name too long");
	for (unsigned long i = 0; i < n; i++) info.id.name[i] = argv[2][i];
	if (sys(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_INFO, (long)&info, 0) < 0) die("no such control");
	zero(&val, sizeof val); val.id = info.id;
	unsigned int cnt = info.count > 128 ? 128 : info.count;
	if (argv[1][0] == 'w') {
		for (unsigned int i = 0; i < cnt && i + 3 < (unsigned long)argc; i++) {
			long v = atol_(argv[3 + i]);
			if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) val.value.enumerated.item[i] = v;
			else val.value.integer.value[i] = v;
		}
		if (sys(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_WRITE, (long)&val, 0) < 0) die("write failed");
		zero(&val, sizeof val); val.id = info.id;
	}
	if (sys(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_READ, (long)&val, 0) < 0) die("read failed");
	out("type="); outl(info.type); out(" count="); outl(info.count); out(" values:");
	for (unsigned int i = 0; i < cnt; i++) {
		out(" ");
		if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
			unsigned int item = val.value.enumerated.item[i];
			outl(item);
			struct snd_ctl_elem_info e = info; e.value.enumerated.item = item;
			if (sys(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_INFO, (long)&e, 0) == 0) { out("("); out(e.value.enumerated.name); out(")"); }
		} else outl(val.value.integer.value[i]);
	}
	out("\n");
	sys(SYS_exit, 0, 0, 0, 0);
	return 0;
}
__asm__(".global _start\n_start:\n\tmov x0, sp\n\tbl cmain\n");
