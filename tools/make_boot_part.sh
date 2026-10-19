#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# make_boot_part.sh - the boot part of a new P25T card, made from this
# repository: the partition table, U-Boot three times and an empty P25TBOOT.
# It replaces copying card 1's first GiB with clone_boot_part.sh.
#
# Usage:
#   bash ~/p25t-backup/p25t-sway/tools/make_boot_part.sh image
#       PC, normal user. Makes build/boot-part/boot-part.img (289 MiB) from
#       build/u-boot/uboot.itb (tools/build_uboot.sh). If
#       build/card1-first-1GiB.img exists, compares the partition table with
#       card 1's.
#   bash ~/p25t-backup/p25t-sway/tools/make_boot_part.sh write <DEVICE>
#       Asks for sudo. Writes that image to a card, e.g. /dev/sdb, compares
#       it read back, moves the backup GPT to the card's end and gives the
#       card its own GUIDs. ERASES THE CARD (asks YES first). Refuses a card
#       that carries a P25T system (a partition labelled p25troot): for
#       those, install_debian.sh is the tool.
# Then:  bash debian/install_debian.sh sway   (or console): root partition,
#        kernel, initramfs, CARD-SHA256SUMS.
#
# Layout (512-byte sectors; the stock SPL looks for the partition names):
#   16384-24575   uboot     FIT at +0 and +4096 (the SPL tries both copies)
#   24576-32767   uboot_a   the same
#   32768-40959   uboot_b   the same
#   65536-589823  P25TBOOT  FAT32, 256 MiB, empty; type 0700 (basic data),
#                           as on card 1 (partitions 1-3: 8300)
#   1331200       U-Boot's status note, written at every boot, outside
#                 every partition
#   2097152-end   P25TROOT, made later by install_debian.sh
# The same layout as u-boot/build_sd_image.sh, which made card 1. Linux
# finds P25TBOOT and p25troot by label (fstab), not by UUID.
#
# Host packages: gdisk dosfstools (image); util-linux parted (write)
set -euo pipefail
umask 022

REPO="$HOME/p25t-backup/p25t-sway"
FIT="$REPO/build/u-boot/uboot.itb"
OUT="$REPO/build/boot-part"
IMG="$OUT/boot-part.img"
CARD1="$REPO/build/card1-first-1GiB.img"
MODE=${1:-}

say() { echo; echo "=== $*"; }
die() { echo "STOPPED: $*" >&2; exit 1; }
usage() { sed -n '3,34p' "$0"; exit 1; }

# partitions 1-4 as "number start end code name", from sgdisk -p
part_table() {
    sgdisk -p "$1" 2> /dev/null | awk '$1 ~ /^[1-4]$/ && NF >= 7 {print $1, $2, $3, $(NF-1), $NF}'
}

make_image() {
    [ "$(id -u)" -ne 0 ] || die "run 'image' as your normal user, not with sudo"
    say "1/3 Checks"
    for t in sgdisk mkfs.vfat dd truncate; do
        command -v "$t" > /dev/null || die "missing $t (sudo apt install gdisk dosfstools)"
    done
    [ -f "$FIT" ] || die "$FIT missing - run tools/build_uboot.sh first"
    ( cd "$(dirname "$FIT")" && sha256sum -c --quiet uboot.itb.sha256 ) \
        || die "$FIT does not match its uboot.itb.sha256 - run tools/build_uboot.sh again"
    [ "$(stat -c %s "$FIT")" -lt 2097152 ] || die "FIT larger than 2 MiB"
    echo "FIT: $FIT ($(stat -c %s "$FIT") bytes, sha256 $(cut -c1-16 "$FIT.sha256")...)"

    say "2/3 Image"
    mkdir -p "$OUT"
    rm -f "$IMG" "$OUT/fat.img"
    truncate -s 289M "$IMG"
    sgdisk -a 1 -n 1:16384:24575 -c 1:uboot -n 2:24576:32767 -c 2:uboot_a \
           -n 3:32768:40959 -c 3:uboot_b -n 4:65536:589823 -c 4:P25TBOOT -t 4:0700 "$IMG" > /dev/null
    for start in 16384 24576 32768; do
        dd if="$FIT" of="$IMG" bs=512 seek=$start conv=notrunc status=none
        dd if="$FIT" of="$IMG" bs=512 seek=$((start + 4096)) conv=notrunc status=none
    done
    truncate -s 256M "$OUT/fat.img"
    mkfs.vfat -F 32 -n P25TBOOT "$OUT/fat.img" > /dev/null
    dd if="$OUT/fat.img" of="$IMG" bs=512 seek=65536 conv=notrunc status=none
    rm -f "$OUT/fat.img"
    ( cd "$OUT" && sha256sum boot-part.img > boot-part.img.sha256 )
    part_table "$IMG" | sed 's/^/  /'
    echo "$IMG: $(stat -c %s "$IMG") bytes, sha256 $(cut -c1-16 "$IMG.sha256")..."

    say "3/3 Partition table against card 1"
    if [ -f "$CARD1" ]; then
        if diff <(part_table "$CARD1") <(part_table "$IMG") > "$OUT/card1-table.diff"; then
            echo "partitions 1-4: the same start, end, type and name as card 1"
        else
            echo "partitions 1-4 DIFFER from card 1 (< card 1, > new):"
            sed 's/^/  /' "$OUT/card1-table.diff"
            die "the layout is not card 1's"
        fi
    else
        echo "no $CARD1 - not compared"
    fi
    echo
    echo "Next: bash $REPO/tools/make_boot_part.sh write <DEVICE>"
}

write_card() {
    DEV=${1:-}
    [ -n "$DEV" ] || usage
    if [ "$(id -u)" -ne 0 ]; then exec sudo --preserve-env=HOME bash "$0" write "$DEV"; fi
    say "1/5 Checks"
    for t in sgdisk partprobe wipefs blkid lsblk cmp; do
        command -v "$t" > /dev/null || die "missing $t (sudo apt install gdisk parted util-linux)"
    done
    [ -f "$IMG" ] || die "$IMG missing - run 'make_boot_part.sh image' first"
    ( cd "$OUT" && sha256sum -c --quiet boot-part.img.sha256 ) || die "$IMG damaged"
    [ -b "$DEV" ] || die "$DEV is not a block device"
    NAME=$(basename "$DEV")
    [ "$(lsblk -dno TYPE "$DEV")" = disk ] || [ "$(lsblk -dno TYPE "$DEV")" = loop ] \
        || die "$DEV is a $(lsblk -dno TYPE "$DEV"), not a whole disk (use /dev/sdb, not /dev/sdb1)"
    RM=$(lsblk -dno RM "$DEV" | tr -d ' ')
    TRAN=$(lsblk -dno TRAN "$DEV" | tr -d ' ')
    case "$NAME" in
        loop*) [ "${P25T_TEST_LOOP:-}" = 1 ] || die "$DEV is a loop device (tests only: P25T_TEST_LOOP=1)" ;;
        mmcblk*) ;;
        *) [ "$RM" = 1 ] || [ "$TRAN" = usb ] || die "$DEV is not removable/USB/SD (RM=$RM TRAN=$TRAN)" ;;
    esac
    SIZE_GB=$(( $(lsblk -dbno SIZE "$DEV" | tr -d ' ') / 1000000000 ))
    [ "$SIZE_GB" -ge 4 ] && [ "$SIZE_GB" -lt 256 ] || die "$DEV is $SIZE_GB GB - not a plausible microSD card"
    if findmnt -no SOURCE / | grep -q "^$DEV"; then die "$DEV holds the PC's own system"; fi
    # A card with a P25T system must never be erased here. Read the card
    # itself (partition table, and the file system at 1 GiB), not only the
    # partitions the system happens to list for it.
    partprobe "$DEV" 2> /dev/null || true
    if sgdisk -p "$DEV" 2> /dev/null | awk '$1 ~ /^[0-9]+$/ {print $NF}' | grep -qx P25TROOT; then
        die "$DEV has a partition named P25TROOT: this card carries a P25T system - not erasing it"
    fi
    if [ "$(blkid -p -o value -s LABEL -O $((2097152 * 512)) "$DEV" 2> /dev/null || true)" = p25troot ]; then
        die "$DEV has the file system p25troot at 1 GiB: this card carries a P25T system - not erasing it"
    fi
    for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
        [ "$(blkid -p -o value -s LABEL "$p" 2> /dev/null || true)" = p25troot ] \
            && die "$p is labelled p25troot: this card carries a P25T system - not erasing it"
    done
    OTHER=$(blkid -t LABEL=P25TBOOT -o device 2> /dev/null | grep -v "^$DEV" || true)
    [ -z "$OTHER" ] || die "another P25T card is in the PC ($OTHER) - take it out first"
    echo "card: $DEV, $SIZE_GB GB, transport ${TRAN:-?}, removable ${RM:-?}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINTS "$DEV"
    echo
    echo "ALL DATA ON $DEV ($SIZE_GB GB) WILL BE ERASED."
    read -r -p "Type YES to continue: " ANSWER
    [ "$ANSWER" = YES ] || die "not confirmed"

    say "2/5 Writing $(basename "$IMG")"
    for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do umount "$p" 2> /dev/null || true; done
    wipefs -a "$DEV" > /dev/null
    dd if="$IMG" of="$DEV" bs=1M conv=fsync status=progress
    sync

    say "3/5 Reading it back"
    cmp -n "$(stat -c %s "$IMG")" "$IMG" "$DEV" || die "the card differs from the image"
    echo "the card's first $(( $(stat -c %s "$IMG") / 1048576 )) MiB match the image"

    say "4/5 Backup GPT at the card's end, the card's own GUIDs"
    SG=$(mktemp)
    sgdisk -e "$DEV" > "$SG" 2>&1 || { cat "$SG"; rm -f "$SG"; die "sgdisk -e failed"; }
    sgdisk -G "$DEV" > "$SG" 2>&1 || { cat "$SG"; rm -f "$SG"; die "sgdisk -G failed"; }
    rm -f "$SG"
    sgdisk -v "$DEV" | grep -q 'No problems found' || { sgdisk -v "$DEV"; die "the GPT has problems"; }
    partprobe "$DEV" 2> /dev/null || partx -u "$DEV" 2> /dev/null || true
    case "$DEV" in *[0-9]) P4="${DEV}p4" ;; *) P4="${DEV}4" ;; esac
    for i in $(seq 1 10); do [ -b "$P4" ] && break; sleep 1; done
    [ -b "$P4" ] || die "$P4 did not appear"

    say "5/5 Check"
    diff <(part_table "$IMG") <(part_table "$DEV") > /dev/null || die "partition table differs from the image"
    [ "$(blkid -s LABEL -o value "$P4")" = P25TBOOT ] || die "$P4 is not labelled P25TBOOT"
    if command -v fsck.vfat > /dev/null; then fsck.vfat -n "$P4" > /dev/null || die "fsck.vfat found errors on $P4"; fi
    part_table "$DEV" | sed 's/^/  /'
    echo
    echo "ALL OK: $DEV has U-Boot and an empty P25TBOOT."
    echo "Next: bash $REPO/debian/install_debian.sh sway   (or console)"
}

case "$MODE" in
    image) make_image ;;
    write) write_card "${2:-}" ;;
    *) usage ;;
esac
