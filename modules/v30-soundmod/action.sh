#!/system/bin/sh
# KernelSU Action button: cycle dual +12 dB -> dual +6 dB -> off. Applies at the next reboot: restarting the
# audio HAL live also kills the sound-trigger HAL inside it, which can crash system_server (soft reboot).
MODDIR=${0%/*}
. "$MODDIR/common.sh"
load_conf
if [ "$DUAL_SPEAKER" = 1 ] && [ "$EAR_BOOST_DB" -gt 6 ]; then EAR_BOOST_DB=6
elif [ "$DUAL_SPEAKER" = 1 ]; then DUAL_SPEAKER=0
else DUAL_SPEAKER=1; EAR_BOOST_DB=12; fi
save_conf
[ "$DUAL_SPEAKER" = 1 ] && echo "Next boot: dual speaker ON, earpiece +$EAR_BOOST_DB dB" || echo "Next boot: dual speaker OFF"
echo "Reboot to apply."
