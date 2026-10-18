#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# check_sdcard.sh - look at an SD card that shows no partitions. READ-ONLY.
#
# Usage (DEVICE = the whole card, e.g. /dev/sdb or /dev/mmcblk0 - not a
# partition; lsblk shows it):
#     sudo bash ~/p25t-backup/p25t-sway/tools/check_sdcard.sh DEVICE
#
# Nothing is written: it reports what the kernel sees, the partition-table
# signatures at the start and end of the card, any filesystem signatures
# (wipefs -n = no action), and reads 64 MiB at the start, middle and end
# to catch read errors and a fake capacity that cannot even be read.
# A card with no partition table but clean reads is just empty/erased:
# writing the image creates the table. Read errors or a "middle/end"
# that returns only zeros/ones where the start has data point to a
# failing or counterfeit card.
set -u

DEV="${1:-}"
die() { echo "STOPPED: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$DEV" ] || die "usage: sudo bash $0 DEVICE   (whole card, e.g. /dev/sdb)"
[ -b "$DEV" ] || die "$DEV is not a block device"
NAME=$(basename "$DEV")
[ -e "/sys/block/$NAME" ] || die "$DEV is a partition or unknown - give the whole card"
# never look at the PC's own disks
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
[ "$NAME" != "$ROOTDEV" ] || die "$DEV holds the PC's root filesystem"
case "$NAME" in sd*|mmcblk*) ;; *) die "$DEV is not an sd*/mmcblk* device" ;; esac
RM=$(cat "/sys/block/$NAME/removable" 2>/dev/null || echo ?)

say() { echo; echo "=== $*"; }

say "1. What the kernel sees"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
SECT=$(cat "/sys/block/$NAME/size")
echo "size: $SECT sectors = $((SECT / 2048)) MiB; removable: $RM; read-only: $(cat "/sys/block/$NAME/ro")"
udevadm info --query=property --name="$DEV" 2>/dev/null | grep -E '^ID_(VENDOR|MODEL|SERIAL_SHORT|BUS)=' | sed 's/^/  /'
for f in name manfid oemid date serial; do      # SD card registers (mmcblk on a built-in reader)
    [ -r "/sys/block/$NAME/device/$f" ] && echo "  card $f: $(cat "/sys/block/$NAME/device/$f")"
done
[ "$SECT" -gt 0 ] || die "size 0: the reader sees no medium (card not detected or dead)"

say "2. Partition-table signatures"
MBR=$(dd if="$DEV" bs=512 count=1 2>/dev/null | od -An -tx1 -j510 -N2 | tr -d ' ')
echo "MBR boot signature (bytes 510-511): ${MBR:-unreadable} (55aa = an MBR/protective MBR is present)"
GPT=$(dd if="$DEV" bs=512 skip=1 count=1 2>/dev/null | head -c 8 | tr -d '\000')
echo "GPT header at sector 1: $([ "$GPT" = "EFI PART" ] && echo present || echo absent)"
GPT2=$(dd if="$DEV" bs=512 skip=$((SECT - 1)) count=1 2>/dev/null | head -c 8 | tr -d '\000')
echo "backup GPT header at the last sector: $([ "$GPT2" = "EFI PART" ] && echo present || echo absent)"
NZ=$(dd if="$DEV" bs=1M count=1 2>/dev/null | tr -d '\000' | wc -c)
echo "first MiB: $NZ non-zero bytes (0 = erased/blank)"
if command -v fdisk > /dev/null; then echo "fdisk:"; fdisk -l "$DEV" 2>&1 | sed 's/^/  /'; fi
if command -v wipefs > /dev/null; then
    echo "signatures (wipefs -n, nothing erased):"
    wipefs -n "$DEV" 2>&1 | sed 's/^/  /'
fi

say "3. Read test: 64 MiB at start, middle and end"
ERR=0
for pos in 0 $((SECT / 2)) $((SECT - 131072)); do
    [ "$pos" -ge 0 ] || pos=0
    T0=$(date +%s.%N)
    OUT=$(dd if="$DEV" of=/dev/null bs=1M count=64 skip=$((pos / 2048)) iflag=direct 2>&1) || ERR=1
    T1=$(date +%s.%N)
    SUM=$(dd if="$DEV" bs=1M count=1 skip=$((pos / 2048)) iflag=direct 2>/dev/null | md5sum | cut -c1-12)
    printf "  at %6d MiB: %s, %s s, first MiB md5 %s\n" $((pos / 2048)) \
        "$(echo "$OUT" | tail -1 | grep -o '[0-9.,]* [MG]B/s' || echo 'READ ERROR')" \
        "$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f", b-a}')" "$SUM"
done
echo "(md5 b6d81b360a56 = that MiB is all zeros)"
dmesg | tail -15 | grep -iE "I/O error|blk_update|reset|timeout|offline" && ERR=1

say "Verdict"
if [ "$ERR" -ne 0 ]; then
    echo "READ ERRORS - the card (or reader) is failing: replace it."
elif [ "$MBR" != "55aa" ] && [ "$NZ" -eq 0 ]; then
    echo "Blank card (no partition table, start erased), reads are clean."
    echo "Usable: writing the sway image creates the partitions. A full capacity"
    echo "test (f3probe, destructive) before trusting it with data is optional."
else
    echo "Reads are clean; see the signatures above for what is on the card."
fi
