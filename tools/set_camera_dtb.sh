#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# set_camera_dtb.sh - pick which camera the NEXT boot wires to the CSI-2
# host, on the tablet. The SoC has one CSI-2 host, so one camera at a time:
#   rear   rk3566-teclast-p25t-normal.dtb (rear GC5035, the usual DTB)
#   front  rk3566-teclast-p25t-front.dtb  (front GC02M2, patches 0027-0030)
#
#     sudo bash set_camera_dtb.sh front <DIR>   copy <DIR>'s front DTB to the
#                                               card and make it active
#     sudo bash set_camera_dtb.sh front         make the card's front DTB active
#     sudo bash set_camera_dtb.sh rear          back to the normal DTB
#     bash set_camera_dtb.sh status             which DTB is active
#
# <DIR> is the unpacked p25t-kernel-<profile>/ folder (pack_kernel.sh).
# U-Boot always loads rk3566-teclast-p25t.dtb, so the active choice is a
# copy at that name (as set-usb-role does for the USB role). The front DTB
# is the normal-role DT plus the front camera: USB-C stays in device mode.
# CARD-SHA256SUMS is updated and checked after every change.
# Run "rear" again before the next deploy_kernel.sh: that script stops if
# the active DTB is neither the normal nor the usbhost copy.
# Takes a second; reboot afterwards.
set -euo pipefail
BOOT=${BOOT:-/boot/firmware}            # overridable only for testing
ACTIVE=$BOOT/rk3566-teclast-p25t.dtb
NORMAL=$BOOT/rk3566-teclast-p25t-normal.dtb
HOST=$BOOT/rk3566-teclast-p25t-usbhost.dtb
FRONT=$BOOT/rk3566-teclast-p25t-front.dtb
SUMS=$BOOT/CARD-SHA256SUMS

die() { echo "STOP: $*" >&2; exit 1; }

status() {
    if cmp -s "$ACTIVE" "$NORMAL"; then echo "active DTB: normal (rear camera, USB-C device mode)"
    elif [ -f "$HOST" ] && cmp -s "$ACTIVE" "$HOST"; then echo "active DTB: usbhost (rear camera, USB-C host mode)"
    elif [ -f "$FRONT" ] && cmp -s "$ACTIVE" "$FRONT"; then echo "active DTB: front (front camera, USB-C device mode)"
    else echo "active DTB: unknown (matches none of the copies on $BOOT)"
    fi
    echo "running kernel: $(uname -r) $(uname -v)"
}

# set or add the line of one file in CARD-SHA256SUMS, then check all lines
sums_set() {
    local name=$1 sum
    sum=$(sha256sum "$BOOT/$name" | cut -d' ' -f1)
    if grep -q "^[0-9a-f]\{64\}  ${name//./\\.}\$" "$SUMS"; then
        sed -i "s/^[0-9a-f]\{64\}  ${name//./\\.}\$/$sum  $name/" "$SUMS"
    else
        echo "$sum  $name" >> "$SUMS"
    fi
}
sums_check() {
    sync
    ( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "CARD-SHA256SUMS check failed - see above"
    echo "CARD-SHA256SUMS updated and checked"
}

activate() {
    cp "$1" "$ACTIVE"; sync
    cmp -s "$1" "$ACTIVE" || die "$ACTIVE differs from $1 after copying"
    sums_set rk3566-teclast-p25t.dtb
    sums_check
}

case "${1:-}" in
    status) status; exit 0 ;;
    front|rear) ;;
    *) die "usage: sudo bash set_camera_dtb.sh front [<DIR>] | rear | status" ;;
esac
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "${TESTING:-}" ] || mountpoint -q "$BOOT" || die "$BOOT is not mounted"
[ -f "$SUMS" ] && [ -f "$NORMAL" ] || die "$SUMS or $NORMAL missing"

if [ "$1" = rear ]; then
    activate "$NORMAL"
    status
    echo "reboot to use the rear camera"
    exit 0
fi

DIR=${2:-}
if [ -n "$DIR" ]; then
    [ -f "$DIR/rk3566-teclast-p25t-front.dtb" ] || die "$DIR/rk3566-teclast-p25t-front.dtb not found"
    ( cd "$DIR" && sha256sum -c --quiet --ignore-missing files.sha256 ) || die "files in $DIR do not match files.sha256"
    grep -q "  rk3566-teclast-p25t-front.dtb\$" "$DIR/files.sha256" || die "files.sha256 in $DIR does not list the front DTB"
    cmp -s "$DIR/Image" "$BOOT/Image" || die "$BOOT/Image is not the Image of $DIR - deploy that kernel first (deploy_kernel.sh)"
    cp "$DIR/rk3566-teclast-p25t-front.dtb" "$FRONT"; sync
    cmp -s "$DIR/rk3566-teclast-p25t-front.dtb" "$FRONT" || die "$FRONT differs after copying"
    sums_set rk3566-teclast-p25t-front.dtb
    echo "front DTB copied to $FRONT"
fi
[ -f "$FRONT" ] || die "no $FRONT on the card - give the kernel folder: set_camera_dtb.sh front <DIR>"
activate "$FRONT"
status
echo "reboot to use the front camera; 'sudo bash set_camera_dtb.sh rear' goes back"
