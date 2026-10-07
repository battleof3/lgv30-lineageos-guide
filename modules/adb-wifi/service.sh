#!/system/bin/sh
# Fallback: if adbd came up before the property was set, restart it once TCP is missing.
sleep 20
if ! grep -qi ':15B3 ' /proc/net/tcp6 /proc/net/tcp 2>/dev/null; then
  setprop service.adb.tcp.port 5555
  stop adbd; start adbd
fi
