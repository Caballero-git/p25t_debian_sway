#!/bin/bash
# test_55.sh - front camera driver: is the picture roll random?
#
# test_54 (2026-10-19, GRF fix by hand): 1600x1200 captured with and
# without vertical flip (20 of 20 frames each) - but both pictures were
# ROLLED: the frame starts in the middle of the picture (seam at line
# ~537 without flip, ~673 with flip), the same roll as in tests 49-50.
# 1296x972 with flip then made the VICAP write past its buffers (IOMMU
# page fault). test_53's 1296x972 without flip was not rolled.
# So: does the roll change from one capture to the next (a start-up
# timing matter) or stay put (a sensor setting)? Does a longer vertical
# blanking change it? Six short captures, no flip, the scene kept still:
#   1-3  1600x1200, three times             -> cam55_1..3_1600.raw
#   4-5  1296x972, twice                    -> cam55_4..5_1296.raw
#   6    1600x1200, vertical blanking +1000 -> cam55_6_1600_vb.raw
# 8 frames each, keeping the last 3 (is the seam the same in every
# frame of one capture?). Stops at the first IOMMU page fault.
# Writes: GRF VI_CON0 bits 8, 5, 4 (restored). No RK817 access.
# REBOOT FIRST (test_54 ended with a fault). Keep the tablet still; a lit
# scene helps. Takes about 20 s.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t sudo dmesg -w
#   ssh -t p25t 'cd tests && sudo bash test_55.sh 2>&1' | tee result_55.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera driver, roll check (test_55) ==="
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

grf() {   # grf get | grf set <mask> <value>   (GRF VI_CON0, hiword write)
python3 - "$@" <<'PYEOF'
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfdc60000)
if sys.argv[1] == "set":
    mask, val = int(sys.argv[2], 0), int(sys.argv[3], 0)
    m[0x340:0x344] = struct.pack("<I", (mask << 16) | (val & mask))
print("0x%04x" % (struct.unpack("<I", m[0x340:0x344])[0] & 0xffff))
PYEOF
}
OLDGRF=$(grf get)
say "GRF VI_CON0 $OLDGRF -> $(grf set 0x0130 0x0130) (clock lane 0, data lanes 0-1 on, as patch 0030 will do)"

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
capture() {   # capture <name> <width> <height> <vflip> <gain> <extra vblank>
    local name=$1 w=$2 h=$3 vf=$4 gain=$5 xvb=$6 code pf fr rc vb
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
    if [ "$xvb" -gt 0 ]; then
        vb=$(v4l2-ctl -d "$SENS" --get-ctrl=vertical_blanking | awk '{print $2}')
        v4l2-ctl -d "$SENS" --set-ctrl=vertical_blanking=$((vb + xvb)) || say "   set vblank failed"
    fi
    v4l2-ctl -d "$SENS" --get-ctrl=exposure --get-ctrl=analogue_gain --get-ctrl=vertical_flip --get-ctrl=vertical_blanking 2>&1 | tr '\n' ' '; echo
    fr=$((w * h * 2))
    rm -f all.raw "cam55_$name.raw"
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=8 --stream-to=all.raw >/dev/null 2>&1
    rc=$?; sync
    say "   exit $rc (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / fr )) of 8 frames"
    if [ -s all.raw ]; then
        tail -c $((fr * 3)) all.raw > "cam55_$name.raw"; rm -f all.raw
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "cam55_$name.raw"
        say "   kept cam55_$name.raw (3 frames, $1 = $pf)"
    fi
    sleep 1; say "   alive"
    if dmesg | grep -q "Page fault"; then
        say "   IOMMU page fault - no more captures"; FAULT=1
    fi
}
FAULT=0

capture 1_1600 1600 1200 0 256 0
[ $FAULT -eq 0 ] && capture 2_1600 1600 1200 0 256 0
[ $FAULT -eq 0 ] && capture 3_1600 1600 1200 0 256 0
[ $FAULT -eq 0 ] && capture 4_1296 1296 972 0 256 0
[ $FAULT -eq 0 ] && capture 5_1296 1296 972 0 256 0
[ $FAULT -eq 0 ] && capture 6_1600_vb 1600 1200 0 256 1000
v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=analogue_gain=128 2>/dev/null
say "GRF VI_CON0 back: $(grf set 0x0130 "$OLDGRF")"

say ""
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -12
say "=== done ==="
