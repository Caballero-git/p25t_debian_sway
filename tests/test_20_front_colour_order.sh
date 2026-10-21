#!/bin/bash
# test_60.sh - front camera: colour order with the horizontal flip
#
# test_59 (2026-10-20, kernel #4 with 0030 + 0031): five captures in a
# row, sizes and vertical flip mixed - all 8 of 8 frames, no roll, no
# fault. But with vertical_flip=1 the frames are still RGGB (the sensor
# moves its readout by a row), while the driver reported GBRG: the
# driver's colour order table is wrong for the vertical flip. Before
# fixing it, the horizontal flip (not tried yet) must be checked too:
#   1. 1600x1200, no flip (reference)          -> cam60_1_noflip.raw
#   2. 1600x1200, horizontal flip              -> cam60_2_hflip.raw
#   3. 1600x1200, horizontal + vertical flip   -> cam60_3_hvflip.raw
# 8 frames each, keeping the last 3. The order is read from the frames
# on the PC (the green pixels are the brighter diagonal pair).
# Needs: kernel #4, front DTB active. No RK817 access. About 15 s.
# Point the camera at something with colour, e.g. a coloured book.
#
# Run it FROM THE PC (repo's tests folder):
#   ssh -t p25t 'cd tests && sudo bash test_60.sh 2>&1' | tee result_60.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera, colour order with flips (test_60) ==="
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
dmesg | grep -q "Page fault" && stop "an IOMMU page fault happened on this boot already - reboot first"

GRF0=$(python3 - <<'PYEOF'
import mmap, os, struct
m = mmap.mmap(os.open("/dev/mem", os.O_RDONLY | os.O_SYNC), 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdc60000)
print("0x%04x" % (struct.unpack("<I", m[0x340:0x344])[0] & 0xffff))
PYEOF
)
say "GRF VI_CON0 (read only, set by the D-PHY driver at stream start): $GRF0 at boot"

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
capture() {   # capture <name> <width> <height> <vflip> <gain> <hflip>
    local name=$1 w=$2 h=$3 vf=$4 gain=$5 hf=$6 code pf fr rc vb
    N=$((N + 1))
    say ""
    say "--- $((N + 1)). $name: ${w}x$h, horizontal_flip=$hf, vertical_flip=$vf, analogue_gain=$gain ($(date +%T))"
    v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip="$vf" --set-ctrl=horizontal_flip="$hf" \
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
    rm -f all.raw "cam60_$name.raw"
    i0=$(awk '/rockchip-cif/ {print $2}' /proc/interrupts)
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=8 --stream-to=all.raw >/dev/null 2>&1
    rc=$?; sync
    say "   VICAP interrupts during the capture: $(( $(awk '/rockchip-cif/ {print $2}' /proc/interrupts) - i0 ))"
    say "   exit $rc (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / fr )) of 8 frames"
    if [ -s all.raw ]; then
        tail -c $((fr * 3)) all.raw > "cam60_$name.raw"; rm -f all.raw
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "cam60_$name.raw"
        say "   kept cam60_$name.raw (3 frames, $1 = $pf)"
    fi
    sleep 1; say "   alive"
    if dmesg | grep -q "Page fault"; then
        say "   IOMMU page fault - no more captures"; FAULT=1
    fi
}
FAULT=0

capture 1_noflip 1600 1200 0 256 0
[ $FAULT -eq 0 ] && capture 2_hflip 1600 1200 0 256 1
[ $FAULT -eq 0 ] && capture 3_hvflip 1600 1200 1 256 1
v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=horizontal_flip=0 --set-ctrl=analogue_gain=128 2>/dev/null

say ""
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -12
say "=== done ==="
