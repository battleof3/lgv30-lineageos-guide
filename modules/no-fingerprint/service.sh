#!/system/bin/sh
# Nothing calls the HAL any more; stop the instance init started at boot.
sleep 15
setprop ctl.stop vendor.lge-biometrics-fingerprint-hal-2-1
