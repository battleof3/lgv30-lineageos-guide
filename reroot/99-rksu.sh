#!/sbin/sh
#
# ADDOND_VERSION=3
#
# /system/addon.d/99-rksu.sh
#
# Keeps RKSU root across LineageOS updates on the LG V30 (joan).
#
# The updater runs backuptool's restore stages *before* it writes the new boot.img, so
# nothing done here could survive by touching boot directly. The updater's last step,
# /tmp/install/bin/device_check.sh, runs *after* boot.img is written; in post-restore this
# script wraps it so /cache/rksu/reroot.sh runs right after the original. The wrapper
# always exits with the original script's status, so this can never fail an update.
#
# Payload (kernel, magiskboot, reroot.sh) lives in /cache/rksu, which updates don't touch.
# Installed by rksu-reroot-installer.zip.

DC=/tmp/install/bin/device_check.sh
ORIG=/tmp/install/bin/device_check.rksu-orig.sh

case "$1" in
  post-restore)
    grep -q ' /cache ' /proc/mounts || mount /cache 2>/dev/null \
      || mount -t ext4 /dev/block/bootdevice/by-name/cache /cache 2>/dev/null
    if [ ! -f /cache/rksu/reroot.sh ]; then
      echo "99-rksu: /cache/rksu/reroot.sh missing; root will not be restored"
      exit 0
    fi
    if [ -f "$DC" ] && [ ! -f "$ORIG" ]; then
      SHELL_LINE=$(head -n 1 "$DC")
      case "$SHELL_LINE" in '#!'*) ;; *) SHELL_LINE='#!/sbin/sh' ;; esac
      INTERP=${SHELL_LINE#\#!}
      mv "$DC" "$ORIG"
      cat > "$DC" <<EOF
$SHELL_LINE
# Wrapped by /system/addon.d/99-rksu.sh
$INTERP $ORIG "\$@"
rc=\$?
$INTERP /cache/rksu/reroot.sh >> /cache/rksu/reroot.log 2>&1
exit \$rc
EOF
      chmod 755 "$DC"
      echo "99-rksu: device_check.sh wrapped; RKSU will be restored after boot.img is written"
    fi
    ;;
esac
exit 0
