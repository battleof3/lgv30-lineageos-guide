#!/system/bin/sh
# Runs before system_server reads feature files: cover the fingerprint feature with an empty list.
# The empty file is copied to /dev (tmpfs) first: a bind mount sourced from /data would keep /data
# busy and make every shutdown unclean.
MODDIR=${0%/*}
TARGET=/vendor/etc/permissions/android.hardware.fingerprint.xml
SRC=/dev/no_fingerprint_features.xml
cp "$MODDIR/no-fingerprint.xml" "$SRC"
chmod 644 "$SRC"
chcon u:object_r:vendor_configs_file:s0 "$SRC"
[ -f "$TARGET" ] && mount --bind "$SRC" "$TARGET"
