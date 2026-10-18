#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Put a built root filesystem and its kernel onto a P25T SD card and switch
# the card to boot it.
#
# Usage (SD card in the PC; it asks for sudo itself):
#     bash ~/p25t-backup/p25t-sway/debian/install_debian.sh sway
#     bash ~/p25t-backup/p25t-sway/debian/install_debian.sh console
#
# Needs: build/rootfs-<profile> (build_debian.sh), the packed kernel
# build/kernel-<profile>/p25t-kernel-<profile>/ (pack_kernel.sh), and a card
# with U-Boot + P25TBOOT (for a new card: tools/clone_boot_part.sh).
# Only one P25T card in the PC (both carry the labels P25TBOOT / p25troot).
#
# What it does to the card (and nothing else):
#   - moves the GPT's backup header to the real end of the card
#   - partition 5 "P25TROOT" from 1 GiB to the end (created if missing),
#     formatted ext4 (label p25troot); it starts at 1 GiB because U-Boot
#     writes its status note at sector 1331200 (~650 MB), outside every
#     partition
#   - copies the root filesystem and verifies every file by checksum
#   - P25TBOOT: the profile's Image and DTBs (role normal), initramfs, flag
#     file boot-debian; removes copied kernel backups (*.pre-*-backup) and
#     old boot logs; updates and checks CARD-SHA256SUMS
# It refuses a card whose existing root partition belongs to another
# hostname (protects card 1 when installing the sway profile).
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then exec sudo --preserve-env=HOME bash "$0" "$@"; fi

PROFILE="${1:-}"
case "$PROFILE" in
    console) HOSTNAME_NEW=p25t ;;
    sway)    HOSTNAME_NEW=p25t-sway ;;
    *) echo "usage: $0 console|sway"; exit 1 ;;
esac
REPO="$HOME/p25t-backup/p25t-sway"
R="$REPO/build/rootfs-$PROFILE"
KP="$REPO/build/kernel-$PROFILE/p25t-kernel-$PROFILE"
INITD="$REPO/build/initramfs"
INIT_OLD="$HOME/p25t-backup/debian"          # card 1's build folder: the only copy of the initramfs
INIT_SHA=af94fceef82006ee4813095b0b32a70de5e3a491db7290b8b635010a83ccefd8
TABLET_USER=jose
ROOT_START=2097152          # sector of 1 GiB

say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

say "1/9 Checking the built root filesystem and the kernel"
[ -x "$R/usr/lib/systemd/systemd" ] || die "no Debian in $R - run build_debian.sh $PROFILE first"
[ "$(cat "$R/etc/hostname")" = "$HOSTNAME_NEW" ] || die "$R has hostname $(cat "$R/etc/hostname"), expected $HOSTNAME_NEW"
PWFIELD=$(awk -F: -v u="$TABLET_USER" '$1 == u {print $2}' "$R/etc/shadow")
case "$PWFIELD" in ""|"!"*|"*"*) die "user $TABLET_USER has no password - run build_debian.sh again" ;; esac
( cd "$KP" && sha256sum -c --quiet files.sha256 ) || die "packed kernel in $KP damaged or missing"
REL=$(cat "$KP/release.txt")
[ -f "$R/usr/lib/modules/$REL/extra/aic8800_fdrv.ko" ] || die "the root filesystem has no modules for $REL"
if [ ! -f "$INITD/initramfs.cpio.gz" ]; then
    mkdir -p "$INITD"
    cp "$INIT_OLD/initramfs.cpio.gz" "$INITD/" || die "no initramfs in $INIT_OLD"
fi
echo "$INIT_SHA  initramfs.cpio.gz" > "$INITD/initramfs.cpio.gz.sha256"
( cd "$INITD" && sha256sum -c --quiet initramfs.cpio.gz.sha256 ) || die "initramfs.cpio.gz is not the known one (af94fcee...)"
echo "root filesystem OK ($(du -sh "$R" | cut -f1), hostname $HOSTNAME_NEW), kernel $REL, initramfs OK"

say "2/9 Finding the P25T card"
N=$(blkid -t LABEL=P25TBOOT -o device | wc -l)
[ "$N" -eq 1 ] || die "found $N partitions labelled P25TBOOT - exactly one P25T card must be in the PC"
BOOTPART=$(blkid -L P25TBOOT)
DISK=/dev/$(lsblk -no PKNAME "$BOOTPART" | head -n 1)
[ -b "$DISK" ] || die "cannot find the disk of $BOOTPART"
DNAME=$(basename "$DISK")
SIZE_GB=$(( $(cat /sys/block/"$DNAME"/size) / 2097152 ))
REMOVABLE=$(cat /sys/block/"$DNAME"/removable)
TRAN=$(lsblk -dno TRAN "$DISK" || true)
if findmnt -no SOURCE / | grep -q "^$DISK"; then die "$DISK holds the PC's own system"; fi
[ "$SIZE_GB" -ge 4 ] && [ "$SIZE_GB" -le 256 ] || die "$DISK is $SIZE_GB GB - not a plausible SD card"
[ "$REMOVABLE" = "1" ] || [ "$TRAN" = "usb" ] || die "$DISK is not removable/USB"
case "$DISK" in *[0-9]) P5="${DISK}p5" ;; *) P5="${DISK}5" ;; esac
echo "card: $DISK, $SIZE_GB GB, transport ${TRAN:-?}, removable $REMOVABLE, P25TBOOT = $BOOTPART"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$DISK"
P4_END=$( (sgdisk -i 4 "$DISK" 2>/dev/null || true) | awk '/^Last sector/ {print $3}')
[ -n "$P4_END" ] && [ "$P4_END" -lt 1331200 ] || die "unexpected layout: partition 4 ends at ${P4_END:-?}"
EXISTING=$( (sgdisk -i 5 "$DISK" 2>/dev/null || true) | awk -F"'" '/^Partition name/ {print $2}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "P25TROOT" ]; then
    die "partition 5 exists and is called '$EXISTING' - not touching it"
fi
if [ -n "$EXISTING" ] && [ -b "$P5" ]; then
    MNT=$(mktemp -d)
    if mount -o ro "$P5" "$MNT" 2>/dev/null; then
        OLDHOST=$(cat "$MNT/etc/hostname" 2>/dev/null || echo "?")
        umount "$MNT"
        [ "$OLDHOST" = "$HOSTNAME_NEW" ] || { rmdir "$MNT"; die "the card's root system is '$OLDHOST', not '$HOSTNAME_NEW' - wrong card?"; }
        echo "existing root system on the card: $OLDHOST (will be replaced)"
    fi
    rmdir "$MNT"
fi

echo
echo "This will ERASE partition 5 (P25TROOT) on $DISK, install the '$PROFILE' system there"
echo "and put kernel $REL on P25TBOOT."
read -r -p "Type YES to continue: " ANSWER
[ "$ANSWER" = "YES" ] || die "not confirmed"

say "3/9 Unmounting the card's partitions"
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
    umount "$p" 2>/dev/null && echo "unmounted $p" || true
done

say "4/9 Partition 5 (P25TROOT, from 1 GiB to the end)"
sgdisk -e "$DISK" > /dev/null
if [ -z "$EXISTING" ]; then
    sgdisk -n 5:$ROOT_START:0 -c 5:P25TROOT -t 5:8300 "$DISK"
fi
partprobe "$DISK" || partx -u "$DISK" || true
for i in $(seq 1 10); do [ -b "$P5" ] && break; sleep 1; done
[ -b "$P5" ] || die "$P5 did not appear"
P5_START=$( (sgdisk -i 5 "$DISK" 2>/dev/null || true) | awk '/^First sector/ {print $3}')
[ -n "$P5_START" ] && [ "$P5_START" -ge $ROOT_START ] || die "partition 5 starts at $P5_START, below 1 GiB"
(sgdisk -p "$DISK" || true) | tail -n 7

say "5/9 Formatting ext4 (label p25troot)"
umount "$P5" 2>/dev/null || true
mkfs.ext4 -F -q -L p25troot "$P5"

say "6/9 Copying the root filesystem onto the card (several minutes)"
MNT=$(mktemp -d)
mount "$P5" "$MNT"
rsync -aHAX --numeric-ids "$R"/ "$MNT"/
sync
echo "copied; now verifying every file by checksum ..."
DIFFS=$(rsync -aHAXn --checksum --numeric-ids --itemize-changes "$R"/ "$MNT"/ | wc -l)
umount "$MNT"
[ "$DIFFS" -eq 0 ] || die "$DIFFS files differ between $R and the card"
e2fsck -fn "$P5" > /dev/null || die "file system check of $P5 failed"
echo "ROOT FILE SYSTEM VERIFIED"

say "7/9 P25TBOOT: kernel $REL, DTBs (role normal), initramfs, boot-debian flag"
mount "$BOOTPART" "$MNT"
removed=0
for f in "$MNT"/*.pre-*-backup "$MNT"/*.stage[0-9]; do
    [ -e "$f" ] || continue; rm -f "$f"; removed=$((removed + 1))
done
echo "removed $removed copied kernel backups"
if [ -d "$MNT/logs" ]; then rm -f "$MNT"/logs/*; echo "boot logs cleared"; fi
cp "$KP/Image" "$MNT/Image"
cp "$KP/rk3566-teclast-p25t.dtb" "$MNT/rk3566-teclast-p25t-normal.dtb"
cp "$KP/rk3566-teclast-p25t.dtb" "$MNT/rk3566-teclast-p25t.dtb"
cp "$KP/rk3566-teclast-p25t-usbhost.dtb" "$MNT/rk3566-teclast-p25t-usbhost.dtb"
cp "$INITD/initramfs.cpio.gz" "$MNT/initramfs.cpio.gz"
echo "Delete this file to boot the stage-1 test system instead of Debian." > "$MNT/boot-debian"
rm -f "$MNT/autorun.sh"
sync
for f in Image rk3566-teclast-p25t.dtb rk3566-teclast-p25t-usbhost.dtb; do
    cmp -s "$KP/$f" "$MNT/$f" || die "$f differs on the card after copying"
done
cmp -s "$KP/rk3566-teclast-p25t.dtb" "$MNT/rk3566-teclast-p25t-normal.dtb" || die "normal DTB differs after copying"
cmp -s "$INITD/initramfs.cpio.gz" "$MNT/initramfs.cpio.gz" || die "initramfs differs after copying"

say "8/9 CARD-SHA256SUMS"
python3 - "$MNT" <<'PYEOF'
import sys, os, hashlib
boot = sys.argv[1]
path = os.path.join(boot, "CARD-SHA256SUMS")
lines = open(path).read().splitlines() if os.path.exists(path) else []
changed = ["Image", "rk3566-teclast-p25t.dtb", "rk3566-teclast-p25t-normal.dtb",
           "rk3566-teclast-p25t-usbhost.dtb", "initramfs.cpio.gz"]
out = []
for l in lines:
    p = l.split()
    if len(p) != 2 or p[1] in changed:
        continue
    if not os.path.exists(os.path.join(boot, p[1])):
        print("dropped (file no longer on the card):", p[1])
        continue
    out.append(l)
for name in changed:
    h = hashlib.sha256(open(os.path.join(boot, name), "rb").read()).hexdigest()
    out.append(h + "  " + name)
open(path, "w").write("\n".join(out) + "\n")
print(len(out), "entries")
PYEOF
sync
( cd "$MNT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "P25TBOOT check failed"
echo "CARD-SHA256SUMS: all entries OK"
umount "$MNT"
rmdir "$MNT"
sync

say "9/9 Done"
echo "ALL OK ($PROFILE, kernel $REL) - if the file manager mounted P25TROOT or P25TBOOT"
echo "again, eject them there; then take the card out and boot the tablet from it."
