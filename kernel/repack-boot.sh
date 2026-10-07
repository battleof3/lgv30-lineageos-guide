#!/usr/bin/env bash
# Repack an official LineageOS boot.img with the RKSU kernel. Everything but the kernel is kept as-is.
# Usage: bash repack-boot.sh [stock-boot.img] [output.img]
set -euo pipefail

ROOT=~/Projects/lgv30-root
STOCK=${1:-$HOME/Projects/lgv30-install/boot.img}
OUTIMG=${2:-$ROOT/rksu-boot.img}
KERNEL=$ROOT/kernel-src/out/arch/arm64/boot/Image.gz-dtb
MKB=$ROOT/toolchains/mkbootimg
W=$ROOT/work/repack

rm -rf "$W"; mkdir -p "$W"
python3 "$MKB/unpack_bootimg.py" --boot_img "$STOCK" --out "$W/stock" --format mkbootimg -0 > "$W/args"

mapfile -d '' ARGS < "$W/args"
NEW=()
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  if [[ ${ARGS[i]} == --kernel ]]; then ((i++)); continue; fi
  NEW+=("${ARGS[i]}")
done
python3 "$MKB/mkbootimg.py" "${NEW[@]}" --kernel "$KERNEL" --output "$OUTIMG"

# Verify: unpack the result and compare every part with what we intended
python3 "$MKB/unpack_bootimg.py" --boot_img "$OUTIMG" --out "$W/new" --format info > "$W/new.info"
python3 "$MKB/unpack_bootimg.py" --boot_img "$STOCK" --out "$W/stock2" --format info > "$W/stock.info"
cmp "$W/new/kernel" "$KERNEL" && echo "kernel: RKSU kernel OK"
cmp "$W/new/ramdisk" "$W/stock/ramdisk" && echo "ramdisk: identical to stock OK"
echo "header differences (expect only kernel_size):"
diff <(grep -v '^kernel_size' "$W/stock.info") <(grep -v '^kernel_size' "$W/new.info") && echo "  none besides kernel_size"
size=$(stat -c %s "$OUTIMG")
(( size <= 41943040 )) && echo "size $size fits boot partition (41943040)" || { echo "TOO BIG for boot partition"; exit 1; }
sha256sum "$OUTIMG"
