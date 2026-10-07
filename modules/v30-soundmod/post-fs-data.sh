#!/system/bin/sh
# Runs before the audio HAL starts, so the HAL reads the patched file on its first load.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
load_conf
save_stock
apply
# AudioService only reports rotation to the audio HAL when this is set; read once when system_server starts.
# Set whenever rotation is wanted and supported, so turning dual speaker on later via Action still follows rotation.
[ "$ROTATION" = 1 ] && [ -w "$SLOT" ] && /data/adb/ksu/bin/resetprop ro.audio.monitorRotation true
