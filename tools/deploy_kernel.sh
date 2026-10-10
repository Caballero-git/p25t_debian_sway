#!/bin/bash
# deploy_kernel.sh - put a new kernel Image and both role DTBs on P25TBOOT
# (mounted at /boot/firmware), on the tablet, with backups and checksums.
#
#   sudo bash deploy_kernel.sh <TAG> <DIR>
#
# <TAG>  first patch number the new kernel adds, e.g. 0028; backups are
#        named *.pre-<TAG>-backup (docs/boot.org, "Rescue and rollback").
# <DIR>  folder with the PC build results, named as the build names them:
#          Image
#          rk3566-teclast-p25t.dtb          (normal role)
#          rk3566-teclast-p25t-usbhost.dtb  (host role)
#          new.sha256                       (sha256sum of the three, made on the PC)
#
# What it does:
#  1. checks the three files against new.sha256 (catches a bad copy) and
#     that Image is an arm64 kernel;
#  2. finds the role set for the next boot (normal / host) - stops if the
#     active DTB matches neither role copy;
#  3. checks free space on P25TBOOT;
#  4. backs up the outgoing Image and both role DTBs: on the card as
#     *.pre-<TAG>-backup and in /home/jose/boot-backups/ (ext4);
#  5. copies the new Image and role DTBs, compares each with cmp;
#  6. copies the role DTB of the current role over the active DTB;
#  7. updates the existing CARD-SHA256SUMS lines of the changed files and
#     checks the whole list.
# It never deletes anything. If space is short it stops; then run
# prune_boot_backups.py. After the new kernel has booted and works, run
# prune_boot_backups.py anyway: it brings the card back to the rule
# (running kernel + 2 previous) and moves the rest to boot-backups/old/.
#
# Rollback if the new kernel does not boot (card in the PC, P25TBOOT):
#   Image.pre-<TAG>-backup                         -> Image
#   rk3566-teclast-p25t-normal.dtb.pre-<TAG>-backup -> rk3566-teclast-p25t.dtb

set -u
BOOT=${BOOT:-/boot/firmware}            # overridable only for testing
BK=${BK:-/home/jose/boot-backups}
SUMS=$BOOT/CARD-SHA256SUMS
TAG=${1:-}
DIR=${2:-}

die() { echo "STOP: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
case "$TAG" in [0-9][0-9][0-9][0-9]) ;; *) die "usage: sudo bash deploy_kernel.sh <TAG like 0028> <DIR>" ;; esac
[ -d "$DIR" ] || die "folder $DIR not found"
DIR=$(cd "$DIR" && pwd)
[ -n "${TESTING:-}" ] || mountpoint -q "$BOOT" || die "$BOOT is not mounted"
for f in Image rk3566-teclast-p25t.dtb rk3566-teclast-p25t-usbhost.dtb new.sha256; do
    [ -f "$DIR/$f" ] || die "$DIR/$f missing"
done
for f in Image rk3566-teclast-p25t-normal.dtb rk3566-teclast-p25t-usbhost.dtb rk3566-teclast-p25t.dtb CARD-SHA256SUMS; do
    [ -f "$BOOT/$f" ] || die "$BOOT/$f missing"
done

echo "=== 1. new files ==="
( cd "$DIR" && sha256sum -c new.sha256 ) || die "new files do not match new.sha256"
# arm64 Image header: magic "ARMd" at offset 56
[ "$(dd if="$DIR/Image" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ] || die "$DIR/Image is not an arm64 kernel Image"
strings "$DIR/Image" | grep -m1 "Linux version" || true

echo; echo "=== 2. role for the next boot ==="
ACTIVE=$BOOT/rk3566-teclast-p25t.dtb
if cmp -s "$ACTIVE" "$BOOT/rk3566-teclast-p25t-normal.dtb"; then
    ROLE=normal; ROLESRC=rk3566-teclast-p25t-normal.dtb
elif cmp -s "$ACTIVE" "$BOOT/rk3566-teclast-p25t-usbhost.dtb"; then
    ROLE=host; ROLESRC=rk3566-teclast-p25t-usbhost.dtb
else
    die "active DTB matches neither role copy - sort that out first (set-usb-role.sh status)"
fi
echo "role: $ROLE"

echo; echo "=== 3. space on P25TBOOT ==="
ls -la "$BOOT" | grep -E "Image|\.dtb" || true
df -h "$BOOT" | tail -1
need=$(( $(stat -c %s "$DIR/Image") + 3 * $(stat -c %s "$DIR/rk3566-teclast-p25t.dtb") + 3 * $(stat -c %s "$DIR/rk3566-teclast-p25t-usbhost.dtb") + 1048576 ))
free=$(( $(df -B1 --output=avail "$BOOT" | tail -1) ))
echo "need about $((need / 1048576)) MB, free $((free / 1048576)) MB"
if [ "$free" -lt "$need" ]; then
    echo "Kernel backups on the card:"
    ls -1 "$BOOT"/Image.pre-*-backup 2>/dev/null | sed 's/^/  /'
    echo "Run prune_boot_backups.py first (dry run, then --apply) - it keeps"
    echo "the running kernel + 2 previous and moves the rest to $BK/old/."
    die "not enough space on P25TBOOT"
fi
for f in Image rk3566-teclast-p25t-normal.dtb rk3566-teclast-p25t-usbhost.dtb; do
    [ -e "$BOOT/$f.pre-$TAG-backup" ] && die "$BOOT/$f.pre-$TAG-backup already exists - deployed before? check by hand"
done

echo; echo "=== 4. backups ==="
mkdir -p "$BK"
for f in Image rk3566-teclast-p25t-normal.dtb rk3566-teclast-p25t-usbhost.dtb; do
    cp -p "$BOOT/$f" "$BK/$f.pre-$TAG-backup" || die "backup of $f to $BK failed"
    cmp -s "$BOOT/$f" "$BK/$f.pre-$TAG-backup" || die "backup of $f to $BK differs"
done
cp -p "$BOOT/rk3566-teclast-p25t-normal.dtb" "$BOOT/rk3566-teclast-p25t-normal.dtb.pre-$TAG-backup" || die "card backup failed"
cp -p "$BOOT/rk3566-teclast-p25t-usbhost.dtb" "$BOOT/rk3566-teclast-p25t-usbhost.dtb.pre-$TAG-backup" || die "card backup failed"
mv "$BOOT/Image" "$BOOT/Image.pre-$TAG-backup" || die "rename of Image failed"
sync
echo "backed up to $BK and on the card as *.pre-$TAG-backup"

echo; echo "=== 5. new files onto the card ==="
cp "$DIR/Image" "$BOOT/Image" &&
cp "$DIR/rk3566-teclast-p25t.dtb" "$BOOT/rk3566-teclast-p25t-normal.dtb" &&
cp "$DIR/rk3566-teclast-p25t-usbhost.dtb" "$BOOT/rk3566-teclast-p25t-usbhost.dtb" || die "copy failed - put Image.pre-$TAG-backup back as Image"
sync
cmp -s "$DIR/Image" "$BOOT/Image" || die "Image on the card differs after copy"
cmp -s "$DIR/rk3566-teclast-p25t.dtb" "$BOOT/rk3566-teclast-p25t-normal.dtb" || die "normal DTB differs after copy"
cmp -s "$DIR/rk3566-teclast-p25t-usbhost.dtb" "$BOOT/rk3566-teclast-p25t-usbhost.dtb" || die "usbhost DTB differs after copy"

echo; echo "=== 6. active DTB for role $ROLE ==="
cp "$BOOT/$ROLESRC" "$ACTIVE" && sync
cmp -s "$BOOT/$ROLESRC" "$ACTIVE" || die "active DTB differs after copy"

echo; echo "=== 7. CARD-SHA256SUMS ==="
cp -p "$SUMS" "$BK/CARD-SHA256SUMS.pre-$TAG-backup"
python3 - "$SUMS" "$BOOT" Image rk3566-teclast-p25t-normal.dtb rk3566-teclast-p25t-usbhost.dtb rk3566-teclast-p25t.dtb <<'EOF'
import sys, hashlib, os
sums, boot, names = sys.argv[1], sys.argv[2], sys.argv[3:]
lines = open(sums).read().splitlines()
for name in names:
    new = hashlib.sha256(open(os.path.join(boot, name), 'rb').read()).hexdigest()
    hit = 0
    for i, l in enumerate(lines):
        p = l.split()
        if len(p) == 2 and p[1] == name:
            lines[i] = new + "  " + name
            hit += 1
    print(f"{name}: {'updated' if hit == 1 else 'no line in the list (left as is)' if hit == 0 else 'STOP: listed twice'}")
    if hit > 1:
        sys.exit(1)
open(sums, 'w').write("\n".join(lines) + "\n")
EOF
[ $? -eq 0 ] || die "CARD-SHA256SUMS not updated"
sync
( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "CARD-SHA256SUMS check failed"
echo "CARD-SHA256SUMS: all entries OK"

echo; echo "=== done: new kernel on the card, role $ROLE. Now: sudo reboot ==="
