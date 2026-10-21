#!/bin/bash
# test_56.sh - front camera driver: what the sensor sends per line
#
# test_55 (2026-10-19): three 1600x1200 captures, all frames arrived but
# rolled, the seam at a different line in each capture (~350, 1017, 1046)
# and the same line in every frame of one capture. The following
# 1296x972 capture made the VICAP write past its buffers - as in test_54
# (1296x972 after 1600x1200). Only the very first capture after a boot
# was a clean 1296x972 (test_53).
# Suspect for the overrun: the sensor's MIPI line length. The driver
# writes Rockchip's table (1600x1200 window, then the MIPI setup), then
# changes the window to 1296x972; if the MIPI block keeps a line length
# for 1600 pixels (2000 bytes) the VICAP gets longer lines than it was
# told and overruns. This test reads the sensor's MIPI registers (page 3:
# 0x10-0x13 incl. the line word count 0x12/0x13, 0x01, 0x15), its window
# (page 1: 0x90-0x98) and 0x3e/0x17 (page 0) over I2C WHILE it streams,
# and counts VICAP interrupts per capture:
#   1. 1296x972  (as test_53, expected to work)  -> cam56_1_1296.raw
#   2. 1600x1200                                 -> cam56_2_1600.raw
#   3. 1296x972  again (expected to fault, last) -> cam56_3_1296.raw
# 8 frames each, keeping the last 3. Stops at the first IOMMU page fault.
# Writes: GRF VI_CON0 bits 8, 5, 4 (restored); sensor page register 0xfe
# (read access, set back to page 0). No RK817 access.
# REBOOT FIRST (test_55 ended with a fault). Takes about 20 s.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t sudo dmesg -w
#   ssh -t p25t 'cd tests && sudo bash test_56.sh 2>&1' | tee result_56.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera driver, sensor MIPI line length (test_56) ==="
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

cat > /tmp/p25t_rd56.py <<'PYEOF'
import fcntl, os, sys, time
vp = int(sys.argv[1])
time.sleep(0.5)
try:
    os.kill(vp, 0)
except OSError:
    print("   (capture ended before the register read)"); sys.exit(0)
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, 0x10)          # I2C_SLAVE_FORCE (the driver owns 0x10)
def wr(r, v): os.write(i2c, bytes((r, v)))
def rd(r):
    os.write(i2c, bytes((r,))); return os.read(i2c, 1)[0]
def page(p, regs):
    wr(0xfe, p); return {r: rd(r) for r in regs}
p3 = page(3, [0x01, 0x10, 0x11, 0x12, 0x13, 0x15])
p1 = page(1, list(range(0x90, 0x99)))
p0 = page(0, [0x3e, 0x17])
wr(0xfe, 0)
w = lambda d, a: d[a] << 8 | d[a + 1]
print("   sensor while streaming: page 3 01=%02x 10=%02x 11=%02x 12/13=%02x %02x (LWC %d or %d bytes) 15=%02x"
      % (p3[0x01], p3[0x10], p3[0x11], p3[0x12], p3[0x13], p3[0x13] << 8 | p3[0x12], p3[0x12] << 8 | p3[0x13], p3[0x15]))
print("   page 1 window 90=%02x y %d x %d h %d w %d | page 0 3e=%02x 17=%02x"
      % (p1[0x90], w(p1, 0x91), w(p1, 0x93), w(p1, 0x95), w(p1, 0x97), p0[0x3e], p0[0x17]), flush=True)
PYEOF
irqs() { awk '/rockchip-cif/ {print $2}' /proc/interrupts; }

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
    rm -f all.raw "cam56_$name.raw"
    i0=$(irqs)
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=8 --stream-to=all.raw >/dev/null 2>&1 &
    vp=$!
    python3 /tmp/p25t_rd56.py $vp
    wait $vp; rc=$?; sync
    say "   VICAP interrupts during the capture: $(( $(irqs) - i0 ))"
    say "   exit $rc (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / fr )) of 8 frames"
    if [ -s all.raw ]; then
        tail -c $((fr * 3)) all.raw > "cam56_$name.raw"; rm -f all.raw
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "cam56_$name.raw"
        say "   kept cam56_$name.raw (3 frames, $1 = $pf)"
    fi
    sleep 1; say "   alive"
    if dmesg | grep -q "Page fault"; then
        say "   IOMMU page fault - no more captures"; FAULT=1
    fi
}
FAULT=0

capture 1_1296 1296 972 0 256 0
[ $FAULT -eq 0 ] && capture 2_1600 1600 1200 0 256 0
[ $FAULT -eq 0 ] && capture 3_1296 1296 972 0 256 0
rm -f /tmp/p25t_rd56.py
v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=analogue_gain=128 2>/dev/null
say "GRF VI_CON0 back: $(grf set 0x0130 "$OLDGRF")"

say ""
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -12
say "=== done ==="
