#!/usr/bin/env bash
set -euo pipefail
IMG=${1:?usage: flash-boot.sh <boot.img>}
adb -d reboot fastboot
n=0; until fastboot devices 2>/dev/null | grep -q fastbootd || (( n >= 60 )); do n=$((n+1)); sleep 2; done
[[ $(fastboot getvar is-userspace 2>&1 | head -1) == "is-userspace: yes" ]] || { echo "not in fastbootd"; exit 1; }
fastboot flash boot "$IMG"
fastboot reboot
sleep 15
timeout 240 adb -d wait-for-device
n=0; until [[ $(adb -d shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]] || (( n >= 60 )); do n=$((n+1)); sleep 3; done
sleep 20
adb -d shell 'uname -v; su -c "id; getenforce"'
