#!/usr/bin/env bash
# Integrate RKSU (rsuntk/KernelSU, pinned) into the LineageOS joan kernel with manual hooks.
# Hook set follows RKSU's own entry points (scope-minimized manual hooks), Linux 4.4 placement
# cross-checked against TosteRino/joan-kernelsu.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/work}   # sources, toolchains and build output (see tools/fetch-sources.sh)
KSRC=$WORK/kernel-src
RKSU=$WORK/rksu
RKSU_REF=${RKSU_REF:-HEAD}   # tools/fetch-sources.sh checks out the pinned commit
PATCHES=$REPO/kernel

cd "$KSRC"
[[ -z $(git status --porcelain) && ! -e KernelSU ]] || { echo "kernel-src is not clean; refusing to patch twice."; exit 1; }

echo "[+] Copying RKSU @ $RKSU_REF into KernelSU/"
mkdir -p KernelSU
git -C "$RKSU" archive "$RKSU_REF" kernel | tar -x -C KernelSU

echo "[+] Applying local RKSU fixes (FBE keyring for ksu_cred, real init->ksu transition check)"
patch -d KernelSU/kernel -p1 < "$PATCHES/rksu-local-fixes.diff"

echo "[+] Wiring drivers/kernelsu"
ln -sfn ../KernelSU/kernel drivers/kernelsu
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
[[ $(grep -c 'drivers/kernelsu/Kconfig' drivers/Kconfig) == 1 ]] || { echo "Kconfig wiring failed"; exit 1; }

echo "[+] Inserting manual hooks"
python3 - <<'PY'
import pathlib, sys

def insert(path, anchor, code, before=False):
    p = pathlib.Path(path)
    s = p.read_text()
    n = s.count(anchor)
    if n != 1:
        sys.exit(f"anchor found {n} times in {path}: {anchor!r}")
    s = s.replace(anchor, code + anchor if before else anchor + code)
    p.write_text(s)
    print(f"    {path}: ok")

# fs/exec.c: execve -> ksud init hooks + su compat
insert("fs/exec.c", "static int do_execveat_common(int fd, struct filename *filename,",
"""#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
			       void *envp, int *flags);
#endif
""", before=True)
insert("fs/exec.c", """	if (IS_ERR(filename))
		return PTR_ERR(filename);
""", """
#ifdef CONFIG_KSU
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif
""")

# fs/open.c: faccessat -> su compat
insert("fs/open.c", "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)",
"""#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
				int *flags);
#endif
""", before=True)
insert("fs/open.c", """	unsigned int lookup_flags = LOOKUP_FOLLOW;

	if (mode & ~S_IRWXO)""", "", before=False)  # sanity: anchor exists once
s = pathlib.Path("fs/open.c").read_text()
s = s.replace("""	unsigned int lookup_flags = LOOKUP_FOLLOW;

	if (mode & ~S_IRWXO)""", """	unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif

	if (mode & ~S_IRWXO)""")
pathlib.Path("fs/open.c").write_text(s)

# fs/stat.c: vfs_fstat (init.rc size fixup) and vfs_fstatat (su compat)
insert("fs/stat.c", "int vfs_fstat(unsigned int fd, struct kstat *stat)\n",
"""#ifdef CONFIG_KSU
extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
""", before=True)
insert("fs/stat.c", """		error = vfs_getattr(&f.file->f_path, stat);
		fdput(f);""", "", before=False)
s = pathlib.Path("fs/stat.c").read_text()
s = s.replace("""		error = vfs_getattr(&f.file->f_path, stat);
		fdput(f);""", """		error = vfs_getattr(&f.file->f_path, stat);
#ifdef CONFIG_KSU
		if (!error)
			ksu_handle_vfs_fstat(fd, &stat->size);
#endif
		fdput(f);""")
pathlib.Path("fs/stat.c").write_text(s)
insert("fs/stat.c", """	unsigned int lookup_flags = 0;

	if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |""", "", before=False)
s = pathlib.Path("fs/stat.c").read_text()
s = s.replace("""	unsigned int lookup_flags = 0;

	if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |""", """	unsigned int lookup_flags = 0;

#ifdef CONFIG_KSU
	ksu_handle_stat(&dfd, &filename, &flag);
#endif

	if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |""")
pathlib.Path("fs/stat.c").write_text(s)

# fs/read_write.c: vfs_read -> init.rc injection (gated, disabled by RKSU after boot)
insert("fs/read_write.c", "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{\n\tssize_t ret;\n",
"""#ifdef CONFIG_KSU
	if (unlikely(ksu_vfs_read_hook))
		ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
""")
insert("fs/read_write.c", "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n",
"""#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
			       size_t *count_ptr, loff_t **pos);
#endif
""", before=True)

# kernel/reboot.c: supercall fd install. RKSU returns -EINVAL for any non-KSU magic,
# so the return value must be ignored or every normal reboot would fail.
insert("kernel/reboot.c", "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
"""#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
""", before=True)
insert("kernel/reboot.c", """	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */""", "", before=False)
s = pathlib.Path("kernel/reboot.c").read_text()
s = s.replace("""	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */""", """	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

	/* We only trust the superuser with rebooting the system. */""")
pathlib.Path("kernel/reboot.c").write_text(s)

# security/selinux/hooks.c: /data is nosuid, so init -> ksu (ksud services/boot-completed)
# must be let through check_nnp_nosuid once RKSU's execve hook has stopped.
insert("security/selinux/hooks.c", "static int check_nnp_nosuid(const struct linux_binprm *bprm,",
"""#ifdef CONFIG_KSU
extern bool is_ksu_transition(const struct task_security_struct *old_tsec,
			      const struct task_security_struct *new_tsec);
#endif
""", before=True)
insert("security/selinux/hooks.c", """	if (new_tsec->sid == old_tsec->sid)
		return 0; /* No change in credentials */
""", """
#ifdef CONFIG_KSU
	if (is_ksu_transition(old_tsec, new_tsec))
		return 0;
#endif
""")
PY

echo "[+] Applying LG V30 DisplayPort pixel-clock cap (dp-max-pclk.diff)"
patch -d "$KSRC" -p1 < "$PATCHES/dp-max-pclk.diff"

echo "[+] Applying LG V30 dual speaker support (lgv30-dual-speaker.diff: amp slot + rotation swap, IIR1 caching fix)"
patch -d "$KSRC" -p1 < "$PATCHES/lgv30-dual-speaker.diff"

echo "[+] Hook diff summary:"
git diff --stat
git diff -- . ":(exclude)sound" ":(exclude)drivers/mfd" > "$WORK/rksu-manual-hooks.diff"
echo "[+] Saved $WORK/rksu-manual-hooks.diff"
