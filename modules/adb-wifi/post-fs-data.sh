#!/system/bin/sh
# Set before adbd starts so it listens on TCP from the first start.
setprop service.adb.tcp.port 5555
