#!/bin/bash
# test_51.sh - front camera with its own driver (patches 0027-0029)
#
# Tests 47-50 drove the GC02M2 by hand through the rear camera's running
# pipeline. Now the kernel has a GC02M2 driver (0027), split mode in the
# D-PHY driver (0028) and a front-camera DTB (0029), so every capture
# starts cleanly: sensor, D-PHY lanes 2-3, CSI-2 host and VICAP together.
# Needs: the new kernel deployed and the front DTB active
# (sudo bash set_camera_dtb.sh front <DIR>, reboot).
#
# Four captures of 20 frames each, keeping the last 2 (~2 s each):
#   A 1600x1200, no flip                -> cam51_a_1600_noflip.raw
#   B 1600x1200, vertical flip          -> cam51_b_1600_vflip.raw
#   C 1296x972 crop, vertical flip      -> cam51_c_1296_vflip.raw
#   D 1600x1200, vflip, gain x4         -> cam51_d_1600_vflip_gain4.raw
# B and C retest the roll seen in tests 49-50; D the darkness.
# Read-only checks first; stops before capturing if the driver or the
# VICAP udev rule is missing (a second capture without it freezes).
# No register pokes, no RK817 access. Takes about 15 s.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t sudo dmesg -w
#   ssh -t p25t 'cd tests && sudo bash test_51.sh 2>&1' | tee result_51.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera with the GC02M2 driver (test_51) ==="
date; uname -rv
[ "$(id -u)" -eq 0 ] || stop "run with sudo"
for c in media-ctl v4l2-ctl; do command -v $c >/dev/null || stop "$c missing"; done

say "--- 1. driver and DT"
dmesg | grep -iE "gc02m2|csidphy|csi2rx|fdfb0000" | tail -8
[ -d /sys/bus/i2c/drivers/gc02m2 ] || stop "no gc02m2 driver in this kernel"
[ -e /sys/bus/i2c/drivers/gc02m2/2-0010 ] || stop "gc02m2 driver did not bind 2-0010 (front DTB active? see dmesg above)"
[ -e /proc/device-tree/phy@fe870000/rockchip,split-lanes-2-3 ] && say "D-PHY: split mode (lanes 2-3) in the DT" || say "WARNING: D-PHY split property not in the DT"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] && [ "$(cat "$VDEV/power/control")" = on ] || stop "VICAP power/control is not 'on' (udev rule) - a second capture would freeze"
say "VICAP power/control on"

M=/dev/media0
SENS=$(media-ctl -d $M -e "gc02m2 2-0010") || stop "no 'gc02m2 2-0010' entity in $M"
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0") || stop "no rkcif-mipi0-id0 entity"
say "sensor subdev $SENS, video $VID"
media-ctl -d $M -p | grep -E "entity|ENABLED|fmt:" | head -20
v4l2-ctl -d "$SENS" -l 2>&1 | sed 's/^/    /'

# bus code -> media-ctl name and V4L2 pixel format
fourcc() {
    case "$1" in
        SRGGB10_1X10) echo RG10 ;; SGRBG10_1X10) echo BA10 ;;
        SGBRG10_1X10) echo GB10 ;; SBGGR10_1X10) echo BG10 ;;
        *) echo "" ;;
    esac
}

N=0
capture() {   # capture <name> <width> <height> <vflip> <gain>
    local name=$1 w=$2 h=$3 vf=$4 gain=$5 code pf fr rc
    N=$((N + 1))
    say ""
    say "--- $((N + 1)). $name: ${w}x$h, vertical_flip=$vf, analogue_gain=$gain ($(date +%T))"
    v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip="$vf" --set-ctrl=horizontal_flip=0 \
        --set-ctrl=analogue_gain="$gain" || { say "   set-ctrl failed"; return; }
    media-ctl -d $M -V "\"gc02m2 2-0010\":0 [fmt:SRGGB10_1X10/${w}x$h field:none]"
    code=$(media-ctl -d $M --get-v4l2 "\"gc02m2 2-0010\":0" | sed -n 's/.*fmt:\([A-Z0-9_]*\)\/\([0-9]*x[0-9]*\).*/\1 \2/p')
    say "   sensor pad now: $code"
    set -- $code
    [ "${2:-}" = "${w}x$h" ] || { say "   sensor did not take ${w}x$h - skipped"; return; }
    pf=$(fourcc "$1"); [ -n "$pf" ] || { say "   unknown bus code $1 - skipped"; return; }
    media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$1/${w}x$h field:none]" &&
    media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$1/${w}x$h field:none]" &&
    media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$1/${w}x$h field:none crop:(0,0)/${w}x$h]" || say "   WARNING: media-ctl -V failed"
    v4l2-ctl -d "$VID" --set-fmt-video=width=$w,height=$h,pixelformat=$pf >/dev/null || say "   WARNING: set-fmt-video $pf failed"
    v4l2-ctl -d "$SENS" --get-ctrl=exposure --get-ctrl=analogue_gain --get-ctrl=vertical_flip --get-ctrl=vertical_blanking 2>&1 | tr '\n' ' '; echo
    fr=$((w * h * 2))
    rm -f all.raw "cam51_$name.raw"
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=20 --stream-to=all.raw >/dev/null 2>&1
    rc=$?; sync
    say "   exit $rc (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / fr )) of 20 frames"
    if [ -s all.raw ]; then
        tail -c $((fr * 2)) all.raw > "cam51_$name.raw"; rm -f all.raw
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "cam51_$name.raw"
        say "   kept cam51_$name.raw (2 frames, $1 = $pf)"
    fi
    sleep 1; say "   alive"
}

capture a_1600_noflip 1600 1200 0 128
capture b_1600_vflip 1600 1200 1 128
capture c_1296_vflip 1296 972 1 128
capture d_1600_vflip_gain4 1600 1200 1 256
v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=analogue_gain=128 2>/dev/null

say ""
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -12
say "=== done ==="
