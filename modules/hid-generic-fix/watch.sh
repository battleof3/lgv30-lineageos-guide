#!/system/bin/sh
# Watcher loop. Runs from a copy in /dev (tmpfs) with cwd / so it never keeps /data busy;
# otherwise /data cannot be unmounted cleanly at shutdown.
#
# The 4.4 kernel lists some HID IDs in hid_have_special_driver for drivers this kernel was not
# built with (20bc:5500 -> hid-betopff), so hid-generic never binds and Android sees no input.
# Fix: re-add such devices with hid.ignore_special_drivers=1 so they get scanned and hid-generic
# binds, then set the parameter back. Polls because the dongle re-enumerates on every plug-in.

IDS="20BC:5500"
PARAM=/sys/module/hid/parameters/ignore_special_drivers
LOG="$1/fix.log"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

fix_unbound() {
  ifaces=""
  for id in $IDS; do
    for h in /sys/bus/hid/devices/*:$id.*; do
      [ -e "$h" ] || continue
      [ -e "$h/driver" ] && continue
      iface=$(basename "$(dirname "$(readlink -f "$h")")")
      case " $ifaces " in *" $iface "*) ;; *) ifaces="$ifaces $iface" ;; esac
    done
  done
  [ -n "$ifaces" ] || return
  echo 1 > $PARAM
  for i in $ifaces; do
    echo -n "$i" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
    echo -n "$i" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
  done
  sleep 1
  echo 0 > $PARAM
  log "rebound$ifaces"
}

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && mv "$LOG" "$LOG.old"
log "started (pid $$, running from $0)"
while true; do
  fix_unbound
  sleep 2
done
