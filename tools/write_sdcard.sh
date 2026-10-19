#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Write an image to a microSD card, with safety checks and read-back verification.
#
# Usage:  sudo bash write_sdcard.sh IMAGE DEVICE
# e.g.    sudo bash write_sdcard.sh p25t-sdprobe.img /dev/sdb
#
# Refuses to run unless DEVICE is a whole, removable/USB disk smaller than 256 GB.
# Asks you to type YES before writing. Verifies the written data afterwards.

set -euo pipefail

IMG="${1:-}"
DEV="${2:-}"

if [ -z "$IMG" ] || [ -z "$DEV" ]; then
    echo "Usage: sudo bash write_sdcard.sh IMAGE DEVICE   (e.g. /dev/sdb)"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi
if [ ! -f "$IMG" ]; then
    echo "Image not found: $IMG"
    exit 1
fi
if [ ! -b "$DEV" ]; then
    echo "Not a block device: $DEV"
    exit 1
fi

NAME="$(basename "$DEV")"
TYPE="$(lsblk -dno TYPE "$DEV")"
RM="$(lsblk -dno RM "$DEV" | tr -d ' ')"
TRAN="$(lsblk -dno TRAN "$DEV" | tr -d ' ')"
SIZE_BYTES="$(lsblk -dbno SIZE "$DEV" | tr -d ' ')"
SIZE_GB=$(( SIZE_BYTES / 1000000000 ))

if [ "$TYPE" != "disk" ]; then
    echo "Refusing: $DEV is a '$TYPE', not a whole disk (use /dev/sdb, not /dev/sdb1)."
    exit 1
fi
if [ "$RM" != "1" ] && [ "$TRAN" != "usb" ] && [[ "$NAME" != mmcblk* ]]; then
    echo "Refusing: $DEV is not removable/USB/SD (RM=$RM TRAN=$TRAN)."
    exit 1
fi
if [ "$SIZE_GB" -ge 256 ]; then
    echo "Refusing: $DEV is ${SIZE_GB} GB, too big to be the microSD card."
    exit 1
fi
ROOTDEV="$(findmnt -no SOURCE / || true)"
case "$ROOTDEV" in
    "$DEV"*) echo "Refusing: $DEV holds the running system."; exit 1 ;;
esac

echo
echo "=== Target device ==="
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS "$DEV"
echo
echo "Image: $IMG ($(stat -c %s "$IMG") bytes)"
echo "ALL DATA ON $DEV (${SIZE_GB} GB) WILL BE DESTROYED."
read -r -p "Type YES to continue: " ANSWER
if [ "$ANSWER" != "YES" ]; then
    echo "Aborted, nothing written."
    exit 1
fi

echo "Unmounting any mounted partitions of $DEV ..."
for p in $(lsblk -lno NAME "$DEV" | tail -n +2); do
    umount "/dev/$p" 2>/dev/null || true
done

echo "Wiping old partition-table signatures ..."
wipefs -a "$DEV" >/dev/null || true

echo "Writing ..."
dd if="$IMG" of="$DEV" bs=1M conv=fsync status=progress
sync

echo "Verifying ..."
IMGSIZE="$(stat -c %s "$IMG")"
SUM_IMG="$(sha256sum "$IMG" | cut -d' ' -f1)"
SUM_DEV="$(head -c "$IMGSIZE" "$DEV" | sha256sum | cut -d' ' -f1)"
if [ "$SUM_IMG" = "$SUM_DEV" ]; then
    echo "VERIFIED OK: card content matches the image."
else
    echo "VERIFY FAILED: card content differs from the image."
    exit 2
fi
partprobe "$DEV" 2>/dev/null || true
echo "Done. You can remove the card."
