#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the P25T SD card image: GPT with three U-Boot FIT partitions (uboot, uboot_a,
# uboot_b) for the stock Rockchip SPL, plus a FAT partition P25TBOOT with kernel,
# device tree and initramfs. Runs as a normal user (uses mtools, no mounting).
#
# Usage:
#   bash build_sd_image.sh UBOOT_DIR BL31_ELF KERNEL_IMAGE DTB INITRAMFS OUT.img
# Example (literal paths from this project):
#   bash build_sd_image.sh ~/src/u-boot rkbin/bin/rk35/rk3568_bl31_v1.46.elf \
#        linux/arch/arm64/boot/Image \
#        linux/arch/arm64/boot/dts/rockchip/rk3566-teclast-p25t.dtb \
#        initramfs.cpio.gz p25t-sd.img
#
# UBOOT_DIR must already be built with u-boot/p25t-u-boot.config
# (it provides u-boot.bin = u-boot-nodtb.bin + dtb, and u-boot.dtb).
#
# Layout (512-byte sectors):
#   16384-24575 uboot    FIT at +0 and +4096 (the SPL tries both copies)
#   24576-32767 uboot_a  same
#   32768-40959 uboot_b  same
#   65536-589823 P25TBOOT FAT32 (256 MiB)
#   1331200 (+32) U-Boot's status note (env export) - keep outside every partition
#   2097152-end  P25TROOT ext4, added later by install_debian.sh
set -euo pipefail
[ $# -eq 6 ] || { sed -n '3,26p' "$0"; exit 1; }
UB=$1; BL31=$2; KIMG=$3; DTB=$4; INITRD=$5; OUT=$6
HERE="$(cd "$(dirname "$0")" && pwd)"
for t in mkimage sgdisk mkfs.vfat mcopy python3; do
    command -v $t >/dev/null || [ -x "$UB/tools/$t" ] || { echo "missing tool: $t"; exit 1; }
done
MKIMAGE=mkimage; [ -x "$UB/tools/mkimage" ] && MKIMAGE="$UB/tools/mkimage"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "1/4 FIT image (U-Boot + BL31 + U-Boot dtb)"
python3 "$HERE/split_bl31.py" "$BL31" "$W" > /dev/null
cp "$UB/u-boot.bin" "$UB/u-boot.dtb" "$HERE/p25t.its" "$W/"
( cd "$W" && "$MKIMAGE" -E -B 0x200 -p 0x1000 -f p25t.its uboot.itb > /dev/null )
[ "$(stat -c %s "$W/uboot.itb")" -lt 2097152 ] || { echo "FIT larger than 2 MiB"; exit 1; }

echo "2/4 FAT partition P25TBOOT"
truncate -s 256M "$W/fat.img"
mkfs.vfat -F 32 -n P25TBOOT "$W/fat.img" > /dev/null
mcopy -i "$W/fat.img" "$KIMG" ::Image
mcopy -i "$W/fat.img" "$DTB" ::rk3566-teclast-p25t.dtb
mcopy -i "$W/fat.img" "$INITRD" ::initramfs.cpio.gz

echo "3/4 Disk image with GPT"
rm -f "$OUT"
truncate -s 289M "$OUT"
sgdisk -a 1 -n 1:16384:24575 -c 1:uboot -n 2:24576:32767 -c 2:uboot_a \
       -n 3:32768:40959 -c 3:uboot_b -n 4:65536:589823 -c 4:P25TBOOT -t 4:0700 "$OUT" > /dev/null
for start in 16384 24576 32768; do
    dd if="$W/uboot.itb" of="$OUT" bs=512 seek=$start conv=notrunc status=none
    dd if="$W/uboot.itb" of="$OUT" bs=512 seek=$((start + 4096)) conv=notrunc status=none
done
dd if="$W/fat.img" of="$OUT" bs=512 seek=65536 conv=notrunc status=none

echo "4/4 Checksum"
sha256sum "$OUT" | tee "$OUT.sha256"
echo "Write it with write_sdcard.sh (checks the target is a removable card)."
