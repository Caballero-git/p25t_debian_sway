#!/bin/bash
# set-usb-role.sh - choose which DTB U-Boot loads on the NEXT boot, to pick
# the USB-C port's role for that boot: "normal" (USB-C acts as a USB
# device - gives the PC a serial console + network link, current default)
# or "host" (USB-C acts as a USB host - a wired keyboard/mouse plugged
# into it works directly, but the console/network link over that cable is
# not available for that boot).
#
# Why a script instead of a boot menu: U-Boot's bootcmd on this board
# hardcodes the filename it loads - "fatload mmc 1:4 ${fdt_addr_r}
# rk3566-teclast-p25t.dtb" (see docs/boot.org) - so which DTB variant's
# *content* sits at that exact path decides the role. This can't be
# changed once the kernel has booted (the USB PHY's dr_mode is fixed at
# probe time) - only for the boot that hasn't happened yet.
#
# P25TBOOT is mounted at /boot/firmware in Debian (see docs/debian.org).
# Usage: set-usb-role.sh [host|normal|status]
#
# host/normal also update the rk3566-teclast-p25t.dtb line in
# CARD-SHA256SUMS and re-check the whole file, so a role switch never
# leaves the card's checksum list stale (2026-09-29: a switch did, and a
# stale role copy silently rolled the DT back to before patch 0017).
# IMPORTANT: -normal.dtb and -usbhost.dtb must be refreshed on every DT
# change - this script copies whatever is in them, old or new.

set -euo pipefail
BOOT=${BOOT:-/boot/firmware}   # overridable only for testing
NORMAL="$BOOT/rk3566-teclast-p25t-normal.dtb"
HOST="$BOOT/rk3566-teclast-p25t-usbhost.dtb"
ACTIVE="$BOOT/rk3566-teclast-p25t.dtb"
SUMS="$BOOT/CARD-SHA256SUMS"

# Copy a role variant over the active DTB, verify, update CARD-SHA256SUMS.
set_role() {
    local src=$1
    sudo cp "$src" "$ACTIVE"
    sync
    if ! cmp -s "$src" "$ACTIVE"; then
        echo "ERROR: $ACTIVE does not match $src after copying - CARD-SHA256SUMS not touched." >&2
        exit 1
    fi
    if [ ! -f "$SUMS" ]; then
        echo "WARNING: $SUMS not found - checksum list NOT updated." >&2
        return
    fi
    if ! grep -q '^[0-9a-f]\{64\}  rk3566-teclast-p25t\.dtb$' "$SUMS"; then
        echo "WARNING: no rk3566-teclast-p25t.dtb line in $SUMS - NOT updated, fix by hand." >&2
        return
    fi
    local new
    new=$(sha256sum "$ACTIVE" | cut -d' ' -f1)
    sudo sed -i "s/^[0-9a-f]\{64\}  rk3566-teclast-p25t\.dtb\$/$new  rk3566-teclast-p25t.dtb/" "$SUMS"
    sync
    if (cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS); then
        echo "CARD-SHA256SUMS updated ($new) - all entries verified OK."
    else
        echo "ERROR: CARD-SHA256SUMS check failed after update - see lines above." >&2
        exit 1
    fi
}

usage() {
    echo "Usage: $0 [host|normal|status]"
    echo "  host   - next boot: USB-C as host (wired keyboard/mouse works; no console/network over that cable)"
    echo "  normal - next boot: USB-C as device (console/network over the cable, current default)"
    echo "  status - show which role is currently set for the next boot"
    exit 1
}

[ $# -eq 1 ] || usage

for f in "$NORMAL" "$HOST" "$ACTIVE"; do
    [ -f "$f" ] || { echo "Missing expected file: $f" >&2; exit 1; }
done

case "$1" in
    host)
        set_role "$HOST"
        echo "Set: host mode (USB-C keyboard/mouse) will be active on the next boot."
        echo "Reboot now with: sudo reboot"
        echo "Note: while in host mode the USB-C port sources power for the attached"
        echo "device instead of just receiving it, so charging behaviour over that"
        echo "same cable may change - keep an eye on the battery level."
        ;;
    normal)
        set_role "$NORMAL"
        echo "Set: normal mode (USB-C console/network) will be active on the next boot."
        echo "Reboot now with: sudo reboot"
        ;;
    status)
        if cmp -s "$ACTIVE" "$HOST"; then
            echo "Currently set for: host (next boot)"
        elif cmp -s "$ACTIVE" "$NORMAL"; then
            echo "Currently set for: normal (next boot)"
        else
            echo "Active DTB matches neither known variant - check manually."
        fi
        ;;
    *)
        usage
        ;;
esac
