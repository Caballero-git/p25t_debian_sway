#!/bin/bash
# Copy the boot part of card 1 (the first GiB: GPT, U-Boot partitions 1-3,
# P25TBOOT) to a new card. The root partition (partition 5) is not copied;
# install_debian.sh creates a new one that fits the new card.
#
# Two runs, one card in the PC at a time (both cards would carry the same
# labels P25TBOOT / p25troot):
#     bash ~/p25t-backup/p25t-sway/tools/clone_boot_part.sh read
#         card 1 in the PC: saves build/card1-first-1GiB.img (reads only)
#     bash ~/p25t-backup/p25t-sway/tools/clone_boot_part.sh write <DEVICE>
#         new card in the PC, e.g. /dev/sdb: writes the image, then moves the
#         backup GPT to the card's end, drops the copied partition 5 entry and
#         gives the copy new GUIDs. ERASES the new card (asks YES first).
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then exec sudo --preserve-env=HOME bash "$0" "$@"; fi

REPO="$HOME/p25t-backup/p25t-sway"
IMG="$REPO/build/card1-first-1GiB.img"
SECTORS=2097152     # 1 GiB in 512-byte sectors; partition 5 starts here
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

disk_checks() {   # $1 = disk; plausible SD card, not the PC's own disk
    local DISK=$1 DNAME SIZE_GB REMOVABLE TRAN
    [ -b "$DISK" ] || die "$DISK is not a block device"
    DNAME=$(basename "$DISK")
    [ -e "/sys/block/$DNAME" ] || die "$DISK is a partition - give the whole card (e.g. /dev/sdb, not /dev/sdb1)"
    SIZE_GB=$(( $(cat /sys/block/"$DNAME"/size) / 2097152 ))
    REMOVABLE=$(cat /sys/block/"$DNAME"/removable)
    TRAN=$(lsblk -dno TRAN "$DISK" || true)
    if findmnt -no SOURCE / | grep -q "^$DISK"; then die "$DISK holds the PC's own system"; fi
    [ "$SIZE_GB" -ge 4 ] && [ "$SIZE_GB" -le 256 ] || die "$DISK is $SIZE_GB GB - not a plausible SD card"
    [ "$REMOVABLE" = "1" ] || [ "$TRAN" = "usb" ] || die "$DISK is not removable/USB"
    echo "card: $DISK, $SIZE_GB GB, transport ${TRAN:-?}, removable $REMOVABLE"
}

case "${1:-}" in
read)
    say "1/3 Finding card 1"
    N=$(blkid -t LABEL=P25TBOOT -o device | wc -l)
    [ "$N" -eq 1 ] || die "found $N partitions labelled P25TBOOT - exactly one P25T card must be in the PC"
    BOOTPART=$(blkid -L P25TBOOT)
    DISK=/dev/$(lsblk -no PKNAME "$BOOTPART" | head -n 1)
    disk_checks "$DISK"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DISK"
    P4_END=$( (sgdisk -i 4 "$DISK" 2>/dev/null || true) | awk '/^Last sector/ {print $3}')
    [ -n "$P4_END" ] && [ "$P4_END" -lt 1331200 ] || die "unexpected layout: partition 4 ends at ${P4_END:-?}"
    say "2/3 Reading the first GiB (only reads the card)"
    mkdir -p "$REPO/build"
    dd if="$DISK" of="$IMG" bs=1M count=1024 status=progress
    sync
    say "3/3 Check"
    cmp -n $((SECTORS * 512)) "$DISK" "$IMG" || die "the image differs from the card's first GiB"
    echo "image equals the card's first GiB"
    sha256sum "$IMG" | tee "$IMG.sha256"
    echo "READ OK - take card 1 out, put the new card in, then: clone_boot_part.sh write <DEVICE>"
    ;;
write)
    DISK=${2:-}
    [ -n "$DISK" ] || die "usage: clone_boot_part.sh write <DEVICE>   (the whole new card, e.g. /dev/sdb)"
    say "1/4 Checks"
    [ -f "$IMG" ] && [ -f "$IMG.sha256" ] || die "no $IMG - run 'clone_boot_part.sh read' with card 1 first"
    ( cd "$(dirname "$IMG")" && sha256sum -c --quiet "$(basename "$IMG").sha256" ) || die "$IMG damaged"
    disk_checks "$DISK"
    # never overwrite a card that already has a P25T root system on it
    for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
        if [ "$(blkid -s LABEL -o value "$p" 2>/dev/null)" = p25troot ]; then
            die "$p is a P25T root partition (p25troot) - is this card 1? Not touching it."
        fi
    done
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
    echo
    echo "This ERASES $DISK and writes card 1's boot part onto it."
    read -r -p "Type YES to continue: " ANSWER
    [ "$ANSWER" = "YES" ] || die "not confirmed"
    say "2/4 Writing"
    for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do umount "$p" 2>/dev/null || true; done
    dd if="$IMG" of="$DISK" bs=1M conv=fsync status=progress
    sync
    cmp -n $((SECTORS * 512)) "$IMG" "$DISK" || die "the card's first GiB differs from the image after writing"
    echo "written and compared"
    say "3/4 Partition table for the new card"
    # backup GPT to the real end; before this, sgdisk reports the copied
    # table's backup header as an ERROR (it sits at card 1's end) - expected,
    # so its output is kept in a file and shown only if sgdisk fails
    SG=$(mktemp)
    sgdisk -e "$DISK" > "$SG" 2>&1 || { cat "$SG"; rm -f "$SG"; die "sgdisk -e failed"; }
    rm -f "$SG"
    if sgdisk -i 5 "$DISK" 2>/dev/null | grep -q '^Partition name'; then
        sgdisk -d 5 "$DISK" > /dev/null                  # card 1's root entry
    fi
    sgdisk -G "$DISK" > /dev/null                        # new disk and partition GUIDs
    partprobe "$DISK" || partx -u "$DISK" || true
    sleep 2
    sgdisk -p "$DISK" | tail -n 6
    sgdisk -i 5 "$DISK" 2>/dev/null | grep -q '^Partition name' && die "partition 5 is still there"
    say "4/4 Check P25TBOOT"
    BOOTPART=$(blkid -L P25TBOOT || true)
    [ -n "$BOOTPART" ] || die "no P25TBOOT on the new card"
    MNT=$(mktemp -d)
    mount -o ro "$BOOTPART" "$MNT"
    if ( cd "$MNT" && sha256sum -c --quiet CARD-SHA256SUMS ); then OK=1; else OK=0; fi
    umount "$MNT"; rmdir "$MNT"
    [ "$OK" -eq 1 ] || die "CARD-SHA256SUMS check failed on the new card"
    echo "P25TBOOT: CARD-SHA256SUMS all OK"
    echo "WRITE OK - next: bash ~/p25t-backup/p25t-sway/debian/install_debian.sh <PROFILE>"
    ;;
*)
    echo "usage: clone_boot_part.sh read | write <DEVICE>"; exit 1 ;;
esac
