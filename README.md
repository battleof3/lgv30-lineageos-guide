# LG V30 (joan): LineageOS 22.2 with VoLTE, root, stereo speakers and no unlock warning

This guide is also available as a [Claude Doc](https://claude.ai/artifact/WCqH8ecH6rMNPfsgcaRX4L).

This guide takes an LG V30 with an unlocked bootloader, TWRP, a custom ROM and Android 9 (Pie) firmware to official LineageOS 22.2, then adds the modifications below. It was done on a US998 (a Verizon VS996 cross-flashed to US998) on Mint Mobile, a T-Mobile MVNO, in October 2026.

What you end up with:

- **Official LineageOS 22.2** (Android 15) nightly for joan, installed with Lineage Recovery. It updates through the built-in Updater.
- **VoLTE and Wi-Fi calling** through the AOSP IMS stack from the joan-volte-lineage project. This matters because 2G/3G is gone on many US carriers.
- **Root with RKSU** (a KernelSU fork), built into a recompiled copy of the official kernel. On a 4.4 kernel there's no way to root without rebuilding it.
- **Root that comes back after LineageOS updates**, through an addon.d hook that re-applies the rooted kernel once the updater writes the new boot image. It works as long as the update's kernel is built from the same source (each nightly rebuilds it, and the hook accepts that). If LineageOS changes the kernel source, a PC script rebuilds first.
- **True stereo speakers**: the earpiece plays one channel and the bottom speaker the other, and the channels swap when you turn the phone the other way. Low frequencies the small earpiece can't reproduce are filtered out of its channel, and its overall volume is raised to better match the bottom speaker. Both are fixed settings in the module's config file, applied at the next reboot.
- **No unlocked-bootloader warning**: the orange "Your device software cannot be checked" screen shows black for the same few seconds instead.

The whole process wipes the phone. Commands assume a Linux PC and bash (see [Known Issues](#known-issues-and-gotchas) for use with WSL2). Run the scripts with bash, not zsh or fish: their word-splitting differs, and a mistake in a root shell on the phone can do real damage.

The scripts, kernel patches and KernelSU modules referenced below are in this repository; see [Repository layout](#repository-layout).

## Contents

1. [Requirements and starting point](#requirements-and-starting-point)
2. [Other V30 models](#other-v30-models)
3. [Back up first](#back-up-first)
4. [Download and verify](#download-and-verify)
5. [Install Lineage Recovery](#install-lineage-recovery)
6. [Install LineageOS 22.2](#install-lineageos-222)
7. [VoLTE and Wi-Fi calling](#volte-and-wi-fi-calling)
8. [Root with RKSU (custom kernel)](#root-with-rksu-custom-kernel)
9. [Keep root across updates](#keep-root-across-updates)
10. [Stereo speakers](#stereo-speakers)
11. [Hide the unlocked-bootloader warning](#hide-the-unlocked-bootloader-warning)
12. [Optional modules](#optional-modules)
13. [Considered but not done](#considered-but-not-done)
14. [Known issues and gotchas](#known-issues-and-gotchas)
15. [Rollback and recovery](#rollback-and-recovery)
16. [Repository layout](#repository-layout)
17. [Sources](#sources)

## Requirements and starting point

You need a supported model, an unlocked bootloader and Android 9 firmware. The LineageOS wiki requires that firmware, and being on a custom ROM doesn't prove you have it.

| Requirement | How to check |
|---|---|
| A V30 model LineageOS supports (done here on US998 firmware; see [Other V30 models](#other-v30-models)) | `adb shell getprop ro.boot.vendor.lge.model.name`, or Settings → About |
| Unlocked bootloader | `fastboot getvar unlocked` → `unlocked: yes` |
| Android 9 firmware (US998: US99830b) | read it from the `laf` partition, below |
| TWRP installed (3.7 used here) | reached with `adb reboot recovery` |
| Linux PC with [adb and fastboot](https://developer.android.com/tools/releases/platform-tools), python3, git, curl, bc | `adb version` |
| About 10 GB free, if you'll build the root kernel | `df -h ~` |

**Not covered here.** This guide starts from an unlocked phone with TWRP. For the steps before that:

- **Unlocking the bootloader:** LG's official unlock program is gone, and the LineageOS wiki lists no official method for joan. The usual route is the XDA [bootloader unlock and root method](https://xdaforums.com/t/lg-v30-v30-v30s-bootloader-unlock-root-method-with-clear-instructions.3790500/) thread. The LineageOS wiki's pages for [variant 1](https://wiki.lineageos.org/devices/joan/variant1/), [variant 2](https://wiki.lineageos.org/devices/joan/variant2/) and [variant 3](https://wiki.lineageos.org/devices/joan/variant3/) describe each model group.
- **TWRP:** [TWRP 3.7.0 for LG V30 (joan)](https://xdaforums.com/t/recovery-unofficial-twrp-3-7-0-for-lg-v30-joan.4558185/) on XDA, which supports all V30 models.
- **Android 9 firmware:** for the US998, the [US99830b KDZ thread](https://xdaforums.com/t/us998-stock-pie-lg-v30-us998-us99830b_00_0902-kdz.3952256/) has the KDZ and a patched LGUP (LGUP's Upgrade mode can't be used while TWRP is installed), and there's a [TWRP-flashable 30b firmware](https://xdaforums.com/t/rom-fw-stock-pie-lg-v30-joan-us998-30b-twrp-flashable-firmware-rom.3973811/). Other models have equivalent threads in XDA's LG V30 forums.

**Checking the firmware.** The `laf` partition (Download Mode) is a small LG boot image that carries the firmware's version. From TWRP's root shell, copy it to the PC, unpack it and read its properties:

```bash
adb exec-out "dd if=/dev/block/bootdevice/by-name/laf bs=4096 2>/dev/null" > laf.img
git clone https://android.googlesource.com/platform/system/tools/mkbootimg
python3 mkbootimg/unpack_bootimg.py --boot_img laf.img --out laf
zcat laf/ramdisk | strings | grep -E 'ro.vendor.lge.swversion|ro.build.version.release='
```

You want `ro.build.version.release=9`. On a US998 the version is US99830b. The 30b bootloader images (`xbl`, `rpm`) are also dated Sep 2 2019, matching the KDZ name `US99830b_00_0902`. If the firmware is older, update it with LG's tools (LGUP on Windows) before going further.

## Other V30 models

This guide was done on one phone: a VS996 running US998 firmware. LineageOS ships one joan build for every V30 model. Its three "variants" differ only in how you unlock the bootloader and install recovery; after that, the steps here are the same.

| LineageOS group | Models | Unlock and install |
|---|---|---|
| Variant 1, "Unlocked" | H930, H930DS, US998 | LG's official fastboot unlock |
| Variant 2, "T-Mobile" | H932 | unlock by exploit, then `dd` from TWRP; follow the wiki's H932 steps |
| Variant 3, "Other" | H931, H933, LS998, VS996, V300L, V300K, V300S | unlock by exploit, then `dd` from TWRP |

Every model needs its own Android 9 firmware first, so the version string you check in [Requirements](#requirements-and-starting-point) differs per model.

What carries over, and where it's uncharted:

| Part of this guide | Variant 1 | Variant 2 (H932) | Variant 3 |
|---|---|---|---|
| LineageOS install, recovery via `dd` | tested (US998 firmware) | expected; same `dd` method | tested on VS996 hardware; expected on the rest |
| Rooted kernel, kernel patches, re-root hook | tested | expected | tested on VS996; expected on the rest |
| Stereo speakers (module + kernel patch) | tested | expected | tested on VS996; expected on the rest |
| Optional modules | tested | expected | tested on VS996; expected on the rest |
| Hide the unlocked-bootloader warning | listed by the AIX zip for H930, H930DS, US998; tested on US998 | **reported not to work; don't try it** | listed for LS998 and VS996; **uncharted on H931, H933 and V300** |

**Tested** means done on this phone. **Expected** means the same code and hardware: every model runs the same joan kernel and vendor files, with the same Snapdragon 835, WCD934x codec and TFA9872 speaker amp, so it should behave the same, but nobody has confirmed it here. If a model's audio files ever differ, the stereo module fails safe to stock audio and logs why.

**VoLTE and Wi-Fi calling depend on your carrier, not the model.** They're tested on T-Mobile's network (Mint here), which is what the joan-volte-lineage project targets. Other carriers are uncharted.

**The unlock-warning trick is the riskiest to extend.** It relies on that model's bootloader accepting Verizon's signed screen-image container and drawing nothing when the orange image is missing. On an untested model, a bootloader that rejects or chokes on it could leave a text warning or something worse. There's no dry run for this partition, so only try it with the partition backup in hand and an understanding of the 9008 brick reports.

## Back up first

Before changing anything, copy every partition except `system`, `cache` and `userdata` to your PC, and check each copy against the phone. It's about 730 MB, and it includes the partitions that hold your IMEI and calibration data:

| Partition | Holds |
|---|---|
| `modemst1`, `modemst2`, `fsg`, `fsc` | modem EFS, including the IMEI |
| `persist`, `drm` (LG's persist-lg), `sns` | sensor and secure calibration, LG data |
| `ftm`, `misc`, `factory` | LG factory and boot data |
| `laf`, `recovery`, `boot` | Download Mode, recovery and kernel images; useful for rollback |
| `raw_resources`, `raw_resourcesbak` | the bootloader's screen images (see [Hide the unlocked-bootloader warning](#hide-the-unlocked-bootloader-warning)) |

Boot TWRP (it gives a root adb shell), then run this with bash. It only reads:

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p v30-partitions && cd v30-partitions
mapfile -t NAMES < <(adb shell 'ls /dev/block/bootdevice/by-name' | tr -d '\r')
for n in "${NAMES[@]}"; do
  [[ $n =~ ^(system|cache|userdata)$ ]] && continue
  [[ $n =~ ^[A-Za-z0-9_]+$ ]] || { echo "odd name $n"; exit 1; }
  adb exec-out "dd if=/dev/block/bootdevice/by-name/$n bs=4096 2>/dev/null" > "$n.img"
  phone=$(adb shell "sha256sum /dev/block/bootdevice/by-name/$n" | cut -d' ' -f1)
  [[ $phone == "$(sha256sum "$n.img" | cut -d' ' -f1)" ]] && echo "OK $n" || echo "MISMATCH $n"
done
```

Keep this folder for as long as you own the phone. Also copy off anything personal from internal storage, because formatting data in the install step erases it.

Make a habit of backing up again before every later flash or partition write: `/data/adb` (KernelSU and modules), `/cache/rksu` (the re-root payload), the partition you're about to write, and your apps and their data.

## Download and verify

Get the LineageOS build and its matching recovery from [download.lineageos.org/devices/joan](https://download.lineageos.org/devices/joan), and check them against the published SHA-256 values. Also keep that build's `boot.img`: you'll need it for rooting and for rollback.

| File | Used for |
|---|---|
| `lineage-22.2-<date>-nightly-joan-signed.zip` | the OS (about 1 GB) |
| `recovery.img` | Lineage Recovery (about 34 MB) |
| `boot.img` | base for the rooted kernel, and for un-rooting |
| `build-manifest.xml` | the exact kernel commit and toolchain behind that build |

The checksums are in the builds API:

```bash
curl -s https://download.lineageos.org/api/v2/devices/joan/builds | python3 -c '
import json,sys
b=json.load(sys.stdin)[0]; print(b["date"])
for f in b["files"]: print(f["sha256"], f["filename"])'
sha256sum lineage-22.2-*.zip recovery.img boot.img
```

The download page also lists `super_empty.img`. The joan install doesn't use it.

## Install Lineage Recovery

LineageOS 22.2 has to be installed from Lineage Recovery; TWRP can't write to it. The ROM keeps `system`, `system_ext`, `product`, `vendor` and `odm` as dynamic partitions inside the physical `system` partition (`BOARD_SUPER_PARTITION_METADATA_DEVICE := system`), and only Lineage Recovery maps that layout.

The official method, `fastboot flash recovery recovery.img` from the bootloader, failed on this phone. It reported `Requested download size is more than max allowed` for a 33 MB image, even though `max-download-size` says 512 MB. So write it from TWRP instead, and check it by reading it back:

```bash
#!/usr/bin/env bash
set -euo pipefail
IMG=recovery.img
PART=/dev/block/bootdevice/by-name/recovery
WANT=$(sha256sum "$IMG" | cut -d' ' -f1)
SIZE=$(stat -c %s "$IMG")
[[ $(adb get-state) == recovery ]] || { echo "boot TWRP first"; exit 1; }
adb push "$IMG" /tmp/lineage-recovery.img
[[ $(adb shell sha256sum /tmp/lineage-recovery.img | cut -d' ' -f1) == "$WANT" ]] || { echo "push corrupt"; exit 1; }
adb shell "dd if=/tmp/lineage-recovery.img of=$PART bs=4096 && sync"
[[ $(adb shell "head -c $SIZE $PART | sha256sum" | cut -d' ' -f1) == "$WANT" ]] && echo "recovery verified"
```

Then run `adb reboot recovery`. In Lineage Recovery, adb shows the phone as `unauthorized`, because recovery can't read your saved key from encrypted data. That's harmless: sideloading doesn't need it.

From then on, flash boot images through Lineage Recovery's own fastboot mode: `adb reboot fastboot`, then check that `fastboot getvar is-userspace` shows `yes`. That mode handles large transfers fine. `tools/flash-boot.sh <boot.img>` does this end to end.

## Install LineageOS 22.2

In Lineage Recovery, format data, sideload the zip and reboot. These are the official steps, and they took a few minutes here.

1. **Factory reset → Format data / factory reset**, then confirm. This erases everything on the phone.
2. **Apply update → Apply from ADB.**
3. On the PC: `adb sideload lineage-22.2-<date>-nightly-joan-signed.zip`. The progress stopping around 47% with `Total xfer: 1.00x` is normal.
4. The phone should say `Install completed with status 0`. There's no signature warning, since it's officially signed.
5. Want Google apps? Sideload them now, before the first boot. This setup used none.
6. **Reboot system now.** The first boot can take up to 15 minutes.

After setup, go to Settings → About phone and tap Build number 7 times, then turn on USB debugging in Developer options. Accept the prompt from your PC and tick "Always allow".

To check from the PC: `adb shell getprop ro.lineage.display.version` should name the nightly you installed. Calls won't work yet on carriers that have shut down 2G/3G, though data and texts will. The next section fixes calls.

## VoLTE and Wi-Fi calling

Install the AOSP IMS `-fresh` zip from the [joan-volte-lineage](https://github.com/ShapeShifter499/joan-volte-lineage) project on top of the official build. It brings Android 17's IMS stack to LineageOS 22.2, and here it registered VoLTE over LTE and Wi-Fi calling within seconds. The release used was the prerelease `aosp-ims-17.0.0_r1-a15-alpha1`; check the project's releases for a newer one.

Which file to use:

- **`aosp-ims-...-fresh.zip`**: for a phone that never had the project's older "joan IMS" zip. Use this one.
- **The repacked UNOFFICIAL ROM**: skip it. It works, but the Updater then won't offer official nightlies.
- **`aosp-ims-...-uninstall.zip`**: keep it as your way back.

Check the downloads against the release's checksums: `sha256sum -c SHA256SUMS --ignore-missing`.

1. `adb reboot recovery`, then **Apply update → Apply from ADB**.
2. `adb sideload aosp-ims-17.0.0_r1-a15-alpha1-fresh.zip`. Tap **Yes** at the signature warning on the phone; the transfer waits until you do. It should end with status 0.
3. Reboot. Open **Calling permissions** from the app drawer and allow everything, especially the microphone. (If you flash the zip in the same recovery session as a ROM install or update, this is granted automatically.)
4. For Wi-Fi calling, run the release's `grant-permissions.sh` from the PC once (`bash grant-permissions.sh`), then reboot. It should report 11 permissions granted.
5. Check Settings → Network & internet → SIMs → your carrier for VoLTE and Wi-Fi calling. They were already on here. US Wi-Fi calling also needs an E911 address on your carrier account.

To confirm it registered:

```bash
adb shell dumpsys activity service com.android.imsstack/.imsservice.ImsService | grep N2J_NOTIFY_REGISTERED
```

Look for `net=LTE`, and `net=IWLAN` when on Wi-Fi.

**Caveats.** This is alpha software, tested by its author on T-Mobile US, and here on Mint (same network). Emergency calls over IMS are untested; the project says not to test them by dialling, and not to rely on the phone as your only one. It survives LineageOS updates through its own addon.d script.

## Root with RKSU (custom kernel)

Root means rebuilding the official kernel with [RKSU](https://github.com/rsuntk/KernelSU) built in. The V30 runs a 4.4 kernel, which can't use KernelSU's loadable-module mode, and the official kernel has kprobes off, so RKSU needs manual hooks compiled into the kernel. Build the exact source and toolchain behind your LineageOS build, so the only differences are the ones you add on purpose.

**The quick path.** The scripts do steps 1 to 6 for you. They keep sources, toolchains and build output in `work/` inside the repository (ignored by git); set `WORK=/some/path` to put it elsewhere. With the official `boot.img` and `build-manifest.xml` of the build you installed:

```bash
bash tools/fetch-sources.sh build-manifest.xml boot.img    # exact kernel commit + toolchains, RKSU, mkbootimg, config
bash kernel/prepare-rksu.sh                                 # RKSU, hooks and the three patches (steps 2-3)
bash kernel/build-kernel.sh                                 # step 4
bash kernel/repack-boot.sh                                  # step 5, writes work/rksu-boot.img
bash tools/flash-boot.sh work/rksu-boot.img                 # step 6, through Lineage Recovery's fastboot mode
```

`fetch-sources.sh` also saves the manifest as `work/build-manifest.xml` and writes `work/official.config`, taken from the config the official kernel carries inside itself (the same file the phone shows as `/proc/config.gz`). To keep root across updates, then build the installer with `tools/make-reroot-zip.sh` (see [Keep root across updates](#keep-root-across-updates)). It also needs the official `boot.img` (its kernel becomes the reference for later nightlies), and it builds `tools/kcmp.c` with `tools/build-kcmp.sh`. Like `actl.c`, that needs clang with the AArch64 target and `ld.lld`: a distribution clang works, or the kernel's own in `work/toolchains/clang`.

The steps below explain what each script does. Everything was tested with the 2026-09-20 nightly. The rooted kernel built from it also runs on later nightlies built from the same kernel commit (2026-09-20 to 2026-10-25 all use `c022ed57`). For a later nightly, `tools/prepare-ota.sh` tells you whether it is one of those or needs a rebuild (see [Before you update](#before-you-update)). A newer kernel commit should build the same way with its own manifest and `boot.img`, but if LineageOS changes the kernel files the patches touch, `prepare-rksu.sh` stops with a patch error and the patch needs adjusting.

### 1. Gather the exact sources

Read them from that build's `build-manifest.xml` (`tools/fetch-sources.sh` does this). For the 2026-09-20 nightly:

| Piece | Where | Pin |
|---|---|---|
| Kernel | [LineageOS/android_kernel_lge_msm8998](https://github.com/LineageOS/android_kernel_lge_msm8998) | commit from the manifest (`c022ed57`) |
| Compiler | AOSP [prebuilts/clang/host/linux-x86](https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/), `clang-r536225` | revision from the manifest (tag `android-15.0.0_r32`) |
| Binutils | LineageOS [aarch64-linux-android-4.9](https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9) and [arm-linux-androideabi-4.9](https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9) | revisions from the manifest |
| Config | the official kernel's built-in config (the phone's `/proc/config.gz`; `fetch-sources.sh` extracts it from `boot.img`) | plus `CONFIG_KSU=y`, `CONFIG_KSU_MANUAL_HOOK=y` |
| RKSU | [rsuntk/KernelSU](https://github.com/rsuntk/KernelSU) `main` | `648e5988` (kernel 32473) |
| Boot tools | [platform/system/tools/mkbootimg](https://android.googlesource.com/platform/system/tools/mkbootimg) | any |

The build also needs `bc`. Leave `CONFIG_KPROBES` off; RKSU's manual-hook mode expects that.

### 2. Add RKSU and the hooks

Copy RKSU's `kernel/` directory into the tree as `KernelSU/`, link it in as `drivers/kernelsu`, and add `obj-$(CONFIG_KSU) += kernelsu/` to `drivers/Makefile` and `source "drivers/kernelsu/Kconfig"` to `drivers/Kconfig`. Then insert these calls, each wrapped in `#ifdef CONFIG_KSU` with a matching `extern` declaration. [TosteRino/joan-kernelsu](https://github.com/TosteRino/joan-kernelsu) shows the same spots for KernelSU-Next.

| File | Function | Call |
|---|---|---|
| `fs/exec.c` | `do_execveat_common`, after the `IS_ERR(filename)` check | `ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat(&dfd, &filename, &mode, NULL);` |
| `fs/stat.c` | `vfs_fstatat` | `ksu_handle_stat(&dfd, &filename, &flag);` |
| `fs/stat.c` | `vfs_fstat`, after `vfs_getattr` | `if (!error) ksu_handle_vfs_fstat(fd, &stat->size);` |
| `fs/read_write.c` | `vfs_read`, at entry | `if (unlikely(ksu_vfs_read_hook)) ksu_handle_vfs_read(&file, &buf, &count, &pos);` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)`, before the capability check | `ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);` |
| `security/selinux/hooks.c` | `check_nnp_nosuid`, after the "no change" check | `if (is_ksu_transition(old_tsec, new_tsec)) return 0;` |

Two things to get right:

- **Ignore the reboot hook's return value.** RKSU returns `-EINVAL` for every non-KernelSU request, so `if (ret) return ret;` (as some guides for other forks show) breaks every normal reboot.
- **No setresuid hook is needed.** RKSU handles setuid through its own LSM hook.

### 3. Apply the local patches

| Patch | Why |
|---|---|
| `kernel/rksu-local-fixes.diff` (applied to RKSU) | Two fixes for 4.4 with encrypted storage, reported upstream. Without them, root grants don't survive a reboot and module boot scripts never run. **Allowlist saving fails with -126 (ENOKEY)**: RKSU writes it using credentials made before init existed, so they lack the encryption keys; when `current_cred() == ksu_cred` and it has no session keyring, attach init's. **ksud services and boot-completed exit 127**: `/data` is mounted nosuid, so init → ksu needs a bounded transition, and RKSU's `is_ksu_transition()` for 4.x is an empty stub; make it return true exactly when `old_tsec->sid == cached_init_sid && new_tsec->sid == cached_su_sid`. |
| `kernel/dp-max-pclk.diff` | Caps the DisplayPort pixel clock at 165 MHz. USB-C video doesn't work on the V30 anyway (see [Known issues](#known-issues-and-gotchas)), but without this cap, plugging in a dock can freeze the screen until Android's watchdog restarts the phone. |
| `kernel/lgv30-dual-speaker.diff` | Kernel side of [Stereo speakers](#stereo-speakers): bottom speaker channel selection, rotation swap, and a codec driver fix. It does nothing unless the stereo module turns it on. |

### 4. Build with the official toolchain

Write the phone's config to `out/.config` with the two KernelSU lines appended, then:

```bash
export PATH=$TC/clang-r536225/bin:$TC/aarch64-4.9/bin:$TC/arm-4.9/bin:$PATH
M="make O=out ARCH=arm64 CC=clang HOSTCC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi-"
$M olddefconfig && $M -j$(nproc) Image.gz-dtb
```

Check that a diff against the phone's config shows only the KernelSU lines, and that `llvm-nm out/vmlinux` lists `ksu_handle_sys_reboot`.

### 5. Repack the official boot.img with the new kernel

Change nothing else. It's a header v0 image, with `Image.gz-dtb` as its kernel:

```bash
python3 mkbootimg/unpack_bootimg.py --boot_img boot.img --out stock --format mkbootimg -0 > args
# remove the "--kernel <path>" pair from args, then:
xargs -0 python3 mkbootimg/mkbootimg.py --kernel out/arch/arm64/boot/Image.gz-dtb --output rksu-boot.img < args
```

Unpack the result again and confirm the ramdisk is byte-identical to the original's.

### 6. Flash and check

Flash through Lineage Recovery's fastboot mode: `adb reboot fastboot`, then `fastboot flash boot rksu-boot.img`, then `fastboot reboot`. If it doesn't boot, use the same mode to flash the official `boot.img`.

Install the manager from the [RKSU releases](https://github.com/rsuntk/KernelSU/releases). v3.2.2-10-legacy (32490) was used here; its package name is randomised on purpose. It should show **Working**. Grant Shell in Superuser, then check:

```bash
adb shell su -c id                  # uid=0(root) ... context=u:r:ksu:s0
adb shell su -c getenforce          # Enforcing
adb shell su -c 'logcat -b kernel -d' | grep -E 'ksud (post-fs-data|services|boot-completed)\).*exited'
```

All three ksud stages should exit with status 0. Reboot once to confirm the Shell grant persists.

## Keep root across updates

Every LineageOS update writes a fresh `boot.img`, which removes root. A small hook can put the rooted kernel back automatically, as long as the update's kernel is built from the same source as the rooted one.

**Why the obvious approach fails.** The updater script runs `backuptool.sh restore`, which runs the addon.d scripts, *before* `package_extract_file("boot.img", …)` writes the new boot image. So an addon.d script that patches the boot image is overwritten right after. The updater's last step, `/tmp/install/bin/device_check.sh`, runs after the boot image is written, and it's already unpacked by the time addon.d runs.

**Why it can't compare hashes.** Every nightly rebuilds the kernel, even when its source hasn't changed. The build date and host name in the version banner, the build ID, the module-signing certificate (a new key is generated for every build) and the timestamps in the small built-in initramfs all change, and the appended device trees come out in a different order. The first version of this hook re-rooted only the exact official kernel the rooted one was built from, so it declined every real nightly and root was lost on the 2026-10-25 update. The hook now compares what the two kernels contain.

The hook therefore has two parts (both in `reroot/`):

- **`/system/addon.d/99-rksu.sh`**: in its post-restore stage it renames `device_check.sh` and puts a wrapper in its place. The wrapper runs the original, keeps its exit status, then runs `/cache/rksu/reroot.sh`, logging to `/cache/rksu/reroot.log`. If it can't install the wrapper, it says so in the same log. LineageOS carries addon.d scripts forward through every update.
- **`/cache/rksu/`**: holds `reroot.sh`, a copy of `99-rksu.sh`, the rooted `Image.gz-dtb` and its SHA-256, the official kernel it was built from (`base-Image.gz-dtb`, the official `boot.img`'s kernel, and `base-kernel.sha256`), `kernel-source.txt` (the manifest revisions behind that kernel, for `prepare-ota.sh`), `kcmp`, a `magiskboot` binary (the RKSU manager ships one), and `payload.sha256`, the hash of every file. It takes about 38 MB. `/cache` is a separate partition that updates don't touch.

What `reroot.sh` does:

1. Stops if `/cache/rksu/DISABLE` exists. Checks every payload file against `payload.sha256`.
2. Reads the boot partition and unpacks it with `magiskboot unpack -n`, which leaves the kernel and ramdisk as stored. (magiskboot splits the appended DTBs into `kernel_dtb`; join them back before comparing.)
3. Decides whether the new kernel was built from the same source as the rooted one. If it's the rooted kernel already, there's nothing to do. If it's byte for byte the official kernel the rooted one was built from, yes. Otherwise it runs `kcmp`, which splits off the DTBs, decompresses both kernels with `magiskboot decompress`, and checks them. They count as the same source only if the decompressed kernels have the same size, every byte that differs lies in one of the build stamps above (the version banner and UTS version string, up to four references to the banner when its length changes, the build ID, the signing certificate, the built-in initramfs), and the DTBs are identical, in any order. Everything else must match, including the kernel config embedded in the kernel. If the source differs, it leaves the boot image alone, writes `/cache/rksu/NEEDS_REBUILD`, and stops. You end up unrooted but working until you rebuild. If the comparison itself fails (not enough memory in `/tmp`, a decompression error), it also leaves the boot image alone.
4. Otherwise it swaps in the rooted kernel, keeping the new ramdisk and boot image header, runs `magiskboot repack -n`, and checks that the result has the rooted kernel and the new ramdisk.
5. Writes it, reads it back, and if the read-back doesn't match, writes the original back.

`kcmp` is a small libc-free static binary (`tools/kcmp.c`); `tests/run-host-tests.sh` checks it on the PC against official builds and deliberately altered kernels (one changed instruction, one changed DTB byte and so on are all rejected).

Install both parts with a small flashable zip sideloaded from Lineage Recovery. `bash tools/make-reroot-zip.sh <RKSU manager .apk> [Image.gz-dtb] [official boot.img] [output.zip]` builds it. By default it takes your rooted kernel from the build output and `work/boot.img` and `work/build-manifest.xml` from `fetch-sources.sh`, and writes `work/rksu-reroot-installer.zip`. The zip holds `reroot/update-binary` as the installer, plus a `payload/` folder with the files above (`magiskboot` comes from the manager APK, where it's `lib/arm64-v8a/libmagiskboot.so`). The script also writes `work/rksu-reroot-disable.zip` and a copy of the payload in `work/payload/`. The zip is unsigned, so tap **Yes** at the warning. The installer checks every file, keeps the previous payload until the new one is verified, and dry-runs `reroot.sh` on a copy of the boot partition; it never writes the boot partition itself. It mounts `/system` the way the VoLTE zip does: it reuses recovery's own read-only mount and remounts it read-write, rather than mounting it a second time.

**To test it**, sideloading the same official zip you're already on isn't enough: its kernel is the exact one the rooted kernel was built from, so the source comparison never runs. (That's how the first version's flaw went unnoticed.) Instead, sideload a later nightly built from the same kernel commit (`prepare-ota.sh` tells you, see below) without wiping. The phone should boot rooted, and `reroot.log` should end with `RESULT: REROOTED same source as base (kcmp)`. Here, the VoLTE stack's own addon.d script ran in the same pass. To check without updating, dry-run it against a nightly's official `boot.img` copied to the phone; it writes nothing:

```bash
adb push boot.img /data/local/tmp/
adb shell su -c 'RKSU_WORK=/data/local/tmp/rksu-work sh /cache/rksu/reroot.sh --test /data/local/tmp/boot.img /data/local/tmp/out.img'
```

**Reading the log.** Each run of `reroot.sh` logs its decision and ends with one `RESULT:` line. The log is only readable with root: `adb shell su -c 'grep RESULT: /cache/rksu/reroot.log | tail -n 3'`. It is trimmed to `reroot.log.old` once it passes 256 KB.

| `RESULT:` | Meaning |
|---|---|
| `REROOTED exact base kernel` or `REROOTED same source as base (kcmp)` | the boot partition now has the rooted kernel; the line includes the new boot image's SHA-256 |
| `ALREADY` | the boot partition already had the rooted kernel |
| `NEEDS_REBUILD` | the update's kernel was built from different source; boot left official, rebuild with `prepare-ota.sh` |
| `FAILED <reason>` | something went wrong (for example `FAILED kcmp path: ...` if the comparison couldn't run, or `FAILED hook not installed` from `99-rksu.sh`); boot left as the updater wrote it |
| `DISABLED` | `/cache/rksu/DISABLE` exists; nothing was done |

**Turning the hook off.** Create `/cache/rksu/DISABLE` (`adb shell su -c touch /cache/rksu/DISABLE`), and delete it to turn the hook back on. If the phone doesn't boot, sideload `work/rksu-reroot-disable.zip` from Lineage Recovery instead (unsigned, tap **Yes**); it only creates that file.

**When you rebuild the kernel** (for example after `NEEDS_REBUILD`, or to add a patch), build the payload again with `make-reroot-zip.sh`, then install it with `bash tools/update-payload.sh <rksu-boot.img> <official boot.img> [payload dir]` (the payload folder defaults to `work/payload`). It needs root over adb. It copies every payload file into `/cache/rksu` and checks it, then dry-runs `reroot.sh` against the official `boot.img` and checks that it reproduces `rksu-boot.img` byte for byte. If anything fails it restores the previous payload; otherwise it keeps the previous one in `/data/local/tmp/rksu-stage.prev`. It doesn't update `/system/addon.d/99-rksu.sh`; the zip does.

### Before you update

Run `bash tools/prepare-ota.sh <YYYYMMDD>` on the PC with the date of the nightly you're about to install. It downloads that nightly's `boot.img` and `build-manifest.xml` and checks their SHA-256 against the LineageOS builds API. It also reads the update zip's `updater-script` (only a few KB of the zip, through HTTP range requests) to confirm the order the hook relies on: addon.d restore, then `boot.img`, then `device_check.sh`. It compares the kernel and toolchain revisions with the payload's `kernel-source.txt` (from `work/payload`, or `PAYLOAD_DIR`), and runs `kcmp` on the new kernel against the payload's reference kernel, the same way the phone will.

- `same source: the hook will re-root this update` (exit 0): install the update from the Updater app or by sideloading; both run the hook.
- `kernel source changed: rebuild` (exit 3): it fetches that build's sources into `work/ota-<date>`, rebuilds and repacks the kernel, and builds a new payload (set `RKSU_APK` to the manager APK first). It then prints the `update-payload.sh` command to run with the phone connected, and how to make the new payload the one it compares against next time. Run it before you install the update. `--check` stops after the verdict.
- `updater-script changed` (exit 4): the hook would no longer run after `boot.img` is written, so the update would leave you unrooted. Exit 1 means something failed, such as a download or checksum.

It keeps the nightly's official `boot.img` in `work/ota-<date>/official/`, your rollback image if the re-rooted boot misbehaves.

## Stereo speakers

The V30 has two loudspeakers: the bottom speaker and the earpiece. LineageOS only plays media through the bottom one. This makes the earpiece a second speaker with true stereo that follows rotation.

### Background: the old Magisk mod

The well-known V30 mod is Mrxyzl's "[Magisk] AOSP dual speaker mod" from 2019 (also reposted with tweaks by mrdefcon as `Unknown_ SoundMod_AOSP_V30.zip`). It replaces the whole `/vendor/etc/mixer_paths_tavil.xml` with a 2019 Pie copy. Don't use it on LineageOS 22: that old file drops audio paths LineageOS now uses (unprocessed and stereo recording, in-call music), and its earpiece only plays a mono left+right mix.

### How the phone's audio is wired

| Speaker | Hardware | Path |
|---|---|---|
| Bottom | NXP TFA9872 smart amp on I2C 7-0034 | DSP backend `TERT_MI2S_RX`, 2-channel TDM; the amp plays one slot (slot 0 = left by default) |
| Earpiece | WCD934x (Tavil) codec, EAR PA | DSP backend `SLIMBUS_0_RX` → codec `SLIM RX0/RX1` → interpolator INT0 → EAR PA |

### The module (`modules/v30-soundmod`)

At boot (post-fs-data, before the audio HAL starts), the module builds a patched copy of the ROM's **own** `mixer_paths_tavil.xml` with `patch.awk`, then bind-mounts it over the original from `/dev`. It never ships a copy of the file, so ROM updates to it carry over. It checks that every edit landed exactly the expected number of times. If the ROM's file ever changes so the edits don't fit, it mounts nothing, leaves stock audio, and writes the reason to `/data/adb/v30_soundmod.log`.

The edits:

- A new path, `dual-speaker-ear`, feeds both slimbus channels into the codec's spare IIR filter (IIR1). Input 0 is left and input 1 is right, with one of them muted. Then comes a **4th-order Butterworth high-pass** (two biquads, default 300 Hz, computed at boot), then INT0 and the EAR PA at +6 dB.
- The `speaker` device path includes `dual-speaker-ear` and sets the earpiece's digital gain (`RX0 Digital Volume`, 84 = 0 dB) to 84 + boost.
- Six media front-end paths (`deep-buffer`, `low-latency`, `compress-offload` and `compress-offload2`, `audio-ull`, `mmap`) also route to `SLIMBUS_0_RX`, so media reaches the earpiece.

Things learned the hard way:

- **The unused slimbus channel must still be connected.** If only one of the two channels goes anywhere, the codec logs `overflow error on RX port 0` and the earpiece goes silent. That's why both channels feed IIR1, one at −84 dB (muted).
- **IIR coefficients** are Q28 fixed point (unity = 2^28), stored as 30-bit two's complement, in the standard biquad form `b0 b1 b2 a1 a2` (a0 normalised to 1, negative a1 for low-frequency poles), as documented by the biQuads project. `patch.awk` computes them with the RBJ cookbook formulas.
- **The `IIR1 INPx Volume` controls read back values below 84 as value + 256** (−1 dB reads as 339, muted as 256). Writing works normally.
- **Never restart the audio HAL live** (`setprop ctl.restart vendor.audio-hal`). The sound-trigger HAL lives in the same process, and system_server can crash reconnecting to it (`NullPointerException` in `SoundTriggerModule.binderDied`), which soft-reboots the phone. Settings changes therefore apply at the next reboot.

### The kernel patch (`kernel/lgv30-dual-speaker.diff`)

- **Bottom speaker channel.** The amp's input slot (TFA9872 register 0x26, `TDMSPKS`) is reset to slot 0 every time audio starts, because the driver resets the amp over I2C. The patch adds `/sys/module/snd_soc_tfa98xx/parameters/lgv30_spk_slot` (default −1 = stock) and re-applies it at the end of every amp start. The amp's DC-DC input (`TDMDCS`) must move to the other slot at the same time; otherwise the amp flags a TDM LUT error (status register 0x11 = `0x2604`) and the bottom speaker drops out.
- **Rotation.** With `ro.audio.monitorRotation=true`, Android reports the display rotation to the audio HAL, which sets the `Swap channel` mixer control at 270°. On this phone the DSP's own channel swap has no audible effect, so the patch makes that control flip the amp's slot and exchange the earpiece's two IIR1 input levels instead. It only acts when exactly one IIR1 input is muted, which only happens with the stereo path active, so calls and stock audio are never touched.
- **Codec driver fix.** `wcd934x-regmap.c` marked the whole range from IIR0 `COEF_B1` to IIR1 `COEF_B2` as uncached. That range also swallowed IIR1's input gains and band enables, so they were lost when the filter powered up. The patch marks only the four coefficient registers uncached, and makes the IIR power-up handler restore the band enables as well.

### Settings and use

With the patched kernel, the module sets the amp to the right channel and the earpiece to the left, and sets `ro.audio.monitorRotation=true`. Without it, the module falls back to a fixed layout (earpiece on the right, no rotation).

`/data/adb/v30_soundmod.conf` (reboot to apply):

| Setting | Default | Meaning |
|---|---|---|
| `DUAL_SPEAKER` | 1 | 0 = stock audio |
| `EAR_BOOST_DB` | 12 | extra earpiece gain, 0–16 dB. Higher can clip loud music at high volume. |
| `EAR_HPF_HZ` | 300 | earpiece high-pass in Hz; 0 = off. Keeps bass the earpiece can't reproduce out of it. |
| `EAR_CHANNEL` | R | earpiece channel when rotation isn't available: `L`, `R` or `MIX` (the old mod's mono mix) |
| `ROTATION` | 1 | follow rotation (needs the patched kernel) |
| `SIDETONE` | 0 | 1 = hear your own voice during calls (the old mod's sidetone level) |

The module's **Action** button in the KernelSU manager cycles the earpiece volume boost from +12 dB to +6 dB, then turns dual speaker off; another press starts again at +12 dB. Each choice applies at the next reboot.

**Result:** true stereo that swaps correctly in both landscape directions, no distortion, and calls unaffected. The earpiece is about half as loud as the bottom speaker, which is roughly the limit of its smaller driver.

**Testing tips.** Two test files are provided in `test-audio/`. Copy them to the phone and play them in any player:

- `lr-tones.ogg` (24 s): 2 s each of a low tone on the left only (440 Hz), a high tone on the right only (660 Hz) and a middle tone on both channels (550 Hz), looped 4 times. Use it to check which speaker plays which channel. With the patched kernel, upright or with the earpiece end on your left, the low tone comes from the earpiece; with the earpiece end on your right, it comes from the bottom speaker.
- `lr-1khz.ogg` (27 s): one 1 kHz tone on the left only, the right only, then both, with short gaps, looped 4 times. Use it to compare loudness. Don't judge balance with `lr-tones.ogg`: a tiny earpiece sounds quieter on lower pitches, so different tones mislead.

`test-audio/make-test-tones.py` regenerates both (it needs ffmpeg). A swap only happens when the screen actually rotates: the home screen and floating mini-players stay portrait, so test in an app that rotates, such as a full-screen player or Settings. `tools/actl.c` is a tiny libc-free ALSA mixer-control reader/writer (`actl r "<control>"`, `actl w "<control>" <values>`). Build it with the kernel's clang:

```bash
K=path/to/kernel-src
clang --target=aarch64-linux-gnu -O2 -nostdinc -isystem stub -isystem $(clang -print-resource-dir)/include \
  -D__EXPORTED_HEADERS__ -ffreestanding -fno-stack-protector -fno-builtin -nostdlib -static -fuse-ld=lld \
  -I$K/include/uapi -I$K/arch/arm64/include/uapi -I$K/include -o actl actl.c
# stub/stdlib.h contains: typedef unsigned long size_t;
# stub/asm/{types,ioctl,posix_types}.h each contain: #include <asm-generic/<name>.h>
```

## Hide the unlocked-bootloader warning

With an unlocked bootloader, every boot starts with an orange "Your device software cannot be checked for corruption" screen for about 5 seconds. This replaces it with a black screen for the same time. It's the same method the AIX ROM's "Unlocked Bootloader Disabler" used. It's tested on US998 firmware only; for other models, see [Other V30 models](#other-v30-models) first.

### How the warning works

The bootloader (`abl`) draws its screens from the `raw_resources` partition, an LG container:

| Part | Layout |
|---|---|
| Header | `BOOT_IMAGE_RLE` magic, image count (u32 at 0x10), version 0x1003, device name (`joan_nao_us`, `joan_vzw`, …) at 0x18, signed length (u32 at 0x28) |
| Image table | at 0x1000, 64 bytes per image: name[40], then offset, size, width, height, x, y (u32 each) |
| Image data | 4-byte runs `[count, B, G, R]` |
| Signature | 256 bytes (RSA-2048 size) right after the signed length |

The unlock warning is `verifiedboot_orange_01` (with "PRESS THE POWER KEY TO PAUSE BOOT") and `verifiedboot_orange_02` (the paused screen). `abl` verifies the container's signature (it contains `RawResource:: RawResource Verify fail`), so **editing the images or the table breaks the signature**. Reports of hand-edited containers describe only getting a plain-text warning instead, or a method that worked only on old firmware.

**The trick.** Verizon's own LG-signed `raw_resources` (from the VS996) has no `verifiedboot_orange_*` images at all. In the orange state, `abl` asks for `verifiedboot_orange_01`, then waits 5 seconds regardless of whether drawing worked, so the screen stays black. (Pressing power during that wait pauses boot, also on a black screen; press power again, or wait up to 30 seconds.) The Verizon container's other screens work on a US998: same LG logo, slightly smaller.

### Doing it

1. Get the Verizon `raw_resources`. If your phone started life as a VS996, it's probably still in your `raw_resourcesbak` partition; check the device name at offset 0x18 is `joan_vzw`. Otherwise, extract it from a VS996 KDZ, or take it from the AIX disabler zip. The one used here was byte-identical to the AIX file (`079a3509…` for the 3,649,536-byte image).
2. Write it with checks: `bash tools/write-raw-resources.sh <Verizon raw_resources image> <your backed-up raw_resources.img>`. It confirms the image is an LG container and the live partition matches your backup, pads the image to the partition size, pushes it and checks the push, writes with `dd`, then reads the partition back and compares hashes.
3. Reboot and watch: a black screen for a few seconds, then the LG V30 ThinQ logo, then LineageOS.

**Only ever write a genuine, signed container here.** Zeroing or garbling `raw_resources` has reportedly hard-bricked V30s into 9008 (EDL) mode. Updates don't touch this partition, so the change stays. To undo it, write back your backed-up `raw_resources.img` the same way.

## Optional modules

These are small KernelSU modules (a `module.prop` plus a boot script, zipped, installed with `ksud module install` or from the manager), in `modules/`. Add them only if you need them.

**One rule for every module: never keep anything on `/data` busy.** A script that runs forever from `/data/adb/modules/...`, or a bind mount sourced from `/data`, stops `/data` unmounting cleanly at shutdown. Copy what's needed to `/dev` (memory) at boot, and run or mount it from there.

| Module | When you need it | How it works |
|---|---|---|
| `no-fingerprint` (hide the fingerprint sensor) | the LG fingerprint service crash-loops every 5 s (`fpc_tac ... send_cmd failed -11`, `fpc_hal_open failed`), flooding the logs | at post-fs-data, copy an empty `<permissions/>` file to `/dev`, give it the `vendor_configs_file` label, bind-mount it over `/vendor/etc/permissions/android.hardware.fingerprint.xml`, then stop the service, so Android stops calling it. Keep it installed but disabled if the sensor works. |
| `hid-generic-fix` (ShanWan 2.4 GHz gamepads whose dongle switches to `20bc:5500`) | the pad works on newer phones but shows nothing on the V30 | the 4.4 kernel reserves `20bc:5500` for `hid-betopff`, which isn't built, so nothing binds. A watcher run from `/dev` re-adds the dongle's usbhid interfaces with `/sys/module/hid/parameters/ignore_special_drivers` set to 1, then back to 0, and `hid-generic` binds. |
| `adb-wifi` (network adb) | controlling the phone from your PC over Wi-Fi | at post-fs-data, `setprop service.adb.tcp.port 5555`, so it's always on. Only computers you've already approved can connect. Then `adb connect <phone-ip>:5555` and `scrcpy -s <phone-ip>:5555 --no-audio --max-size 1440`. |

Apps used here: [Termux](https://f-droid.org/packages/com.termux/) and [Droid-ify](https://github.com/Droid-ify/client) from F-Droid (Termux add-ons must come from the same source as Termux), and [Obtainium](https://github.com/ImranR98/Obtainium) for apps published only on GitHub.

If you use [Key Mapper](https://github.com/keymapperorg/KeyMapper), it may turn on Android's separate "Wireless debugging" feature, which prompts at every boot. Network adb above doesn't need it.

## Considered but not done

| Idea | Status | If you want it |
|---|---|---|
| **CRT screen-off animation** (as in crDroid) | LineageOS only has Android's plain fade; crDroid's CRT effect is crDroid's own change to `services.jar` | the AURA CTRL LSPosed module (Android 14–16) has "Classic CRT" and more. It needs Zygisk Next or [ReZygisk](https://github.com/PerformanC/ReZygisk) plus [LSPosed (JingMatrix fork)](https://github.com/JingMatrix/LSPosed) on KernelSU, which runs Zygisk inside every app and gives root-detecting apps more to see. Patching `services.jar` directly would have to be redone after every update. |
| **Double-tap to sleep anywhere** | built in for the status bar and empty lock-screen space (Settings → System → Status bar); the home screen (Trebuchet) has no sleep gesture | a launcher that has one, such as [Lawnchair](https://github.com/LawnchairLauncher/lawnchair) (double-tap → "Lock screen", through its accessibility service) |
| **App sandboxing** (GrapheneOS-style profiles) | built in. **Private space** (Settings → Security & privacy): a separate locked profile whose apps fully stop while locked; good for occasional apps. Secondary users (up to 4). Work profiles via **Insular** (F-Droid; the de-Googled fork of Island), Island, or Shelter (maintenance mode). | GrapheneOS's extras (more users, ending a user's session, notification forwarding, hardened memory allocator) aren't available. Profiles share the clipboard, keyboard, network and device identity. |
| **Dhizuku** (Shizuku with Device Owner) | incompatible with any work profile or Private space: Android won't set a Device Owner while a profile owner exists, and won't create a work profile on a Device Owner phone | on a rooted V30, run Shizuku in root mode instead; root covers most Device Owner uses (freezing, hiding, uninstall blocking) |

## Known issues and gotchas

The biggest one: **USB-C video out (HDMI adapters and docks) doesn't work on the V30**, so don't plan around it.

| Issue | What happens | What to do |
|---|---|---|
| USB-C video out | the phone detects the adapter, reads the monitor's EDID and picks a mode, but DisplayPort link training fails at every speed, in both plug orientations, on 2 or 4 lanes. LineageOS uses LG's exact display configuration, and stock-firmware owners reported the same drop-outs. | treat it as unsupported. Without the pixel-clock cap, accepting "Mirror display?" can freeze the screen until the watchdog restarts the phone. Rebooting with a dock attached can hang at shutdown. |
| After a failed USB-C video attempt | the USB-C controller won't negotiate video mode again | reboot with the adapter unplugged |
| Bootloader fastboot | `fastboot flash` in the bootloader refused a 33 MB image | use Lineage Recovery's fastboot mode (`adb reboot fastboot`), or `dd` from a root shell |
| Fingerprint | the LG fingerprint service crash-loops: the secure-world app rejects every command, the HAL fails to open and the service crashes. It has happened twice, each time right after a new LineageOS build was installed (the second time right after the 2026-10-25 update). It happens on the official kernel too, so root isn't the cause, and its files are unchanged since the backup. The first episode cleared by itself after about two days, probably after a full power-off; the second survived a full power-off. The cause is unknown. | enable the `no-fingerprint` module to silence it (fingerprint unlock is unavailable while it's on). To try fingerprint again later, disable the module and reboot; if the crash loop is back, enable it again. |
| Root lost on every nightly (older hook) | the first version of the re-root hook only accepted the exact official kernel the rooted one was built from. Every nightly rebuilds the kernel, so it declined every real update. | install the current payload: the installer zip from `make-reroot-zip.sh`, or `update-payload.sh` |
| The hook depends on the updater script | re-rooting works only because `device_check.sh` runs after `boot.img` is written. If LineageOS changes that, root is lost after updates (never a brick), and `reroot.log` has no new `RESULT:` line or says `FAILED hook not installed`. | `prepare-ota.sh` checks the order before each update |
| Updating when the kernel source changed | the hook declines (`RESULT: NEEDS_REBUILD`) and the phone boots the official kernel unrooted, so the modules are off (stereo speakers, adb over Wi-Fi, the gamepad fix) until you rebuild | run `prepare-ota.sh` before updating; it rebuilds when needed |
| Restarting the audio HAL | `setprop ctl.restart vendor.audio-hal` can crash system_server (sound-trigger reconnect) and soft-reboot the phone | apply audio changes with a reboot |
| `tfa_start failed! (err 78)` in the kernel log | the speaker amp's first start attempt fails and the driver retries | harmless; the retry succeeds within milliseconds |
| `raw_resources` | the bootloader needs a valid, signed container there | never zero or hand-edit it; only write a genuine signed image, and keep the backup |
| Unclean `/data` shutdowns | the next boot logs `userdata was not cleanly shutdown`, and the ext4 journal replays | keep module scripts and mounts off `/data`. One holder remained even then (kernel-level, likely APEX loop images); low risk. |

<details>
<summary><b>Using Windows (WSL2)</b></summary>

The guide's commands should also run in WSL2 (e.g. Ubuntu), with these workarounds. They come from how WSL2 works; this guide wasn't run on Windows. LGUP, which updates the firmware, is Windows-only, so Windows users can run it natively.

| Issue | What happens | What to do |
|---|---|---|
| No USB access | `adb` and `fastboot` inside WSL2 don't see the phone at all | install [usbipd-win](https://github.com/dorssel/usbipd-win) on Windows and run `usbipd attach --wsl --busid <id> --auto-attach`, then use Linux `adb` and `fastboot` inside WSL. The phone shows up as a new USB device in each mode (Android, TWRP, Lineage Recovery, fastbootd), so `--auto-attach` re-attaches it after every reboot. |
| Using `adb.exe` / `fastboot.exe` from WSL | Windows tools end lines with a carriage return, so script checks such as `adb get-state` don't match and the scripts stop (safely). Fastboot mode also needs the Google USB driver. | prefer usbipd-win with the Linux tools |
| Kernel source under `/mnt/c` | the Windows drive is case-insensitive, and kernel source has files whose names differ only by case; builds there are also much slower | keep the kernel source and toolchains in WSL's own Linux file system (`~/...`) |
| Scripts with Windows line endings | a script saved with Windows (CRLF) line endings fails in bash with confusing errors | clone with `git config core.autocrlf false`, and edit in WSL or an editor set to LF line endings |

</details>

## Rollback and recovery

Every step here can be undone, as long as you keep the partition backup, the official `boot.img` of your build, and the uninstall zips.

| To undo | Do this |
|---|---|
| A kernel that won't boot | hold Volume Down + Power; at the LG logo release Power briefly, then hold it again; accept the factory-reset prompt (with Lineage Recovery installed it opens recovery and wipes nothing); Advanced → Enter fastboot; `fastboot flash boot boot.img` |
| Root | create `/cache/rksu/DISABLE` (or delete `/system/addon.d/99-rksu.sh` and `/cache/rksu`), then flash the official `boot.img` through recovery's fastboot mode. Re-sideloading the official zip alone isn't enough: the hook would re-root it. |
| The stereo kernel patch | flash a rooted kernel built without `lgv30-dual-speaker.diff` (or the official `boot.img`), and update `/cache/rksu` to match (`make-reroot-zip.sh`, then `update-payload.sh`) |
| VoLTE stack | sideload `aosp-ims-...-uninstall.zip` from Lineage Recovery |
| A KernelSU module | disable or uninstall it in the manager's Modules tab, then reboot. If a module stops the phone booting, press Volume Down several times (3 or more) during boot to start KernelSU in safe mode with modules disabled. |
| The black boot-warning screen | write the backed-up `raw_resources.img` back with `dd` (same checks as `tools/write-raw-resources.sh`) |
| Root lost after an update | run `tools/prepare-ota.sh <date>` for the build you installed. If it says `kernel source changed`, it rebuilds; flash `work/ota-<date>/rksu-boot.img` and run the `update-payload.sh` command it prints. If it says `same source`, flash your rooted kernel repacked into that build's `boot.img` (`kernel/repack-boot.sh`), then read the last `RESULT:` line in `reroot.log`. If it's `FAILED hook not installed` or missing, flash the installer zip again. |
| Boot loop after an update re-rooted the phone | flash that nightly's official `boot.img` (kept in `work/ota-<date>/official/`) through recovery's fastboot mode; that doesn't run the hook. Don't re-sideload the same update until the hook is off (sideload `rksu-reroot-disable.zip`, create `/cache/rksu/DISABLE`, or delete `/system/addon.d/99-rksu.sh`), or it writes the same kernel again. |
| IMEI or calibration damage | from TWRP or a root shell, `dd` the backed-up `modemst1`, `modemst2`, `fsg`, `persist` or `drm` image back to its partition |
| Back to TWRP | `dd` the backed-up `recovery.img` from the original setup into the recovery partition (TWRP can't install LineageOS 22.2, though) |

## Repository layout

```
README.md                      this guide
kernel/
  prepare-rksu.sh              adds RKSU, the manual hooks and the patches to a clean kernel tree
  build-kernel.sh              builds Image.gz-dtb with the official toolchain and config
  repack-boot.sh               puts the new kernel into the official boot.img, nothing else
  rksu-local-fixes.diff        RKSU fixes for 4.4 + encrypted storage
  dp-max-pclk.diff             DisplayPort pixel-clock cap (prevents dock freezes)
  lgv30-dual-speaker.diff      speaker amp slot, rotation swap, wcd934x IIR caching fix
reroot/
  99-rksu.sh                   addon.d hook: wraps device_check.sh so reroot.sh runs after boot.img is written
  reroot.sh                    re-roots the boot image after an update (exact match or kcmp, then verified write)
  update-binary                installer for the flashable zip (payload/ folder alongside)
  disable-update-binary        installer for rksu-reroot-disable.zip (creates /cache/rksu/DISABLE)
modules/
  v30-soundmod/                stereo speakers (mixer-path patcher, settings, Action button)
  no-fingerprint/              hides a crash-looping fingerprint sensor
  hid-generic-fix/             ShanWan 20bc:5500 gamepad binding
  adb-wifi/                    adb over Wi-Fi on port 5555
tests/
  run-host-tests.sh            PC tests for kcmp, reroot.sh, the hook and the payload tools (no phone)
  magiskboot-stub.py           stands in for magiskboot in those tests
test-audio/
  lr-tones.ogg                 left / right / both at different pitches: which speaker plays which channel
  lr-1khz.ogg                  left / right / both at the same pitch: loudness balance
  make-test-tones.py           regenerates both (needs ffmpeg)
tools/
  fetch-sources.sh             fetches the kernel source and toolchains a build's manifest names, plus RKSU;
                               saves the manifest and the official kernel config
  flash-boot.sh                flashes a boot image through Lineage Recovery's fastboot mode
  kcmp.c                       libc-free tool that decides whether two kernels were built from the same source
  build-kcmp.sh                builds kcmp: static aarch64 for the phone, or --host for the tests
  kernel-source.sh             writes kernel-source.txt (a build's kernel and toolchain revisions)
  make-reroot-zip.sh           builds the re-root installer zip, the disable zip and work/payload/
  update-payload.sh            installs a new payload into /cache/rksu over adb and dry-runs the re-root
  update-payload-device.sh     the part of update-payload.sh that runs on the phone
  prepare-ota.sh               before an update: will the hook re-root it, or rebuild first
  write-raw-resources.sh       writes a raw_resources image with before/after checks
  actl.c                       libc-free ALSA mixer-control tool for testing on the phone
```

The scripts keep sources, toolchains and build output in `work/` (ignored by git); set `WORK=/some/path` to use another folder. Zip a module's folder contents (not the folder) to install it.

## Sources

- [LineageOS wiki: joan](https://wiki.lineageos.org/devices/joan/) and [lineage_wiki device data](https://github.com/LineageOS/lineage_wiki/tree/main/_data/devices)
- [LineageOS downloads for joan](https://download.lineageos.org/devices/joan) and its [builds API](https://download.lineageos.org/api/v2/devices/joan/builds) (file checksums, used by `tools/prepare-ota.sh`)
- [LineageOS/android_kernel_lge_msm8998](https://github.com/LineageOS/android_kernel_lge_msm8998) and [android_device_lge_joan-common](https://github.com/LineageOS/android_device_lge_joan-common)
- [ShapeShifter499/joan-volte-lineage](https://github.com/ShapeShifter499/joan-volte-lineage)
- [rsuntk/KernelSU (RKSU)](https://github.com/rsuntk/KernelSU)
- [TosteRino/joan-kernelsu](https://github.com/TosteRino/joan-kernelsu) (manual hook placement for joan)
- [AOSP mkbootimg tools](https://android.googlesource.com/platform/system/tools/mkbootimg)
- XDA: [LG V30 bootloader unlock and root method](https://xdaforums.com/t/lg-v30-v30-v30s-bootloader-unlock-root-method-with-clear-instructions.3790500/), [TWRP 3.7.0 for joan](https://xdaforums.com/t/recovery-unofficial-twrp-3-7-0-for-lg-v30-joan.4558185/), [US998 30b KDZ](https://xdaforums.com/t/us998-stock-pie-lg-v30-us998-us99830b_00_0902-kdz.3952256/)
- [AnandTech: DisplayPort Alternate Mode (LG V30)](https://forums.anandtech.com/threads/displayport-alternate-mode-lg-v30.2556545/)
- [XDA: [Magisk] AOSP dual speaker mod (Mrxyzl)](https://xdaforums.com/t/magisk-aosp-dual-speaker-mod-enable-24-bit-output-for-poweramp-on-pie.3900863/)
- [XDA: biQuads, Qualcomm codec IIR filters](https://xdaforums.com/t/mod-audio-biquads-utilizing-qualcomms-audio-codec-for-headphone-compensation.3093000/) (coefficient format)
- [XDA: LG V30 Unlocked Bootloader Warning Disabler](https://xdaforums.com/t/lg-v30-unlocked-bootloader-warning-disabler.4161743/), [AIX disabler zip (archived)](https://web.archive.org/web/20201227094114if_/https://forum.xda-developers.com/attachments/lgv30_unlocked_bootloader_disabler_h930_h930ds_us998_ls998_vs996-zip.5096149/) and [XDA: LG bootloader warning screen](https://xdaforums.com/t/lg-bootloader-warning-screen.3768590/)
- [XDA: AURA CTRL screen-off animations (LSPosed)](https://xdaforums.com/t/lsposed-android-14-16-aura-ctrl-screen-off-animations-notification-styles-status-bar-list-animations-boot-animations-video-wallpaper.4774220/)
- [Insular on F-Droid](https://f-droid.org/packages/com.oasisfeng.island.fdroid/), [Island](https://github.com/oasisfeng/island), [Shelter](https://gitea.angry.im/PeterCxy/Shelter)
- [Dhizuku issue #34: set-device-owner with an existing profile owner](https://github.com/iamr0s/Dhizuku/issues/34)
