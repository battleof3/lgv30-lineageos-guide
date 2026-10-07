#!/system/bin/sh
# Start the watcher from tmpfs and detach, so this script (on /data) exits and nothing keeps /data busy.
MODDIR=${0%/*}
cp "$MODDIR/watch.sh" /dev/hid_generic_fix_watch.sh
chmod 700 /dev/hid_generic_fix_watch.sh
cd /
nohup /system/bin/sh /dev/hid_generic_fix_watch.sh "$MODDIR" </dev/null >/dev/null 2>&1 &
