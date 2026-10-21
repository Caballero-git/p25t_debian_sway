#!/bin/bash
# test_52.sh - front camera driver: why no frames? (watch the receiver)
#
# test_51 (2026-10-19, kernel #2 with patches 0027-0029, front DTB): the
# GC02M2 driver probes and the pipeline links up, but the first capture
# (1600x1200) got no frame: the VICAP's IOMMU reported a write page fault
# (the VICAP wrote outside its buffers), then its interrupt line (IRQ 29)
# fired 200000 times unhandled and the kernel switched it off, so the
# other three captures could not work either.
# Differences from the hand test that worked (test_48): frame size
# (1600x1200 here, 1296x972 there) and the D-PHY/GRF bits left over from
# the rear camera there (lanes 0-1 and clock lane 0 enabled).
#
# One capture at a time, each with the receiver watched every 0.1 s:
#   1. 1296x972, no flip (the size that worked by hand) -> cam52_1296.raw
#   2. 1600x1200, no flip, only if 1 delivered frames  -> cam52_1600.raw
# Printed once per capture: GRF VI_CON0/1, D-PHY lane enable, dual mode,
# THS settle, CSI-2 host lanes; while streaming: CSI PHY_STATE and error
# registers, VICAP MIPI INTSTAT and ID0 control. It stops after the first
# capture that faults (IRQ 29 is then off until a reboot).
# Read-only register access (no writes), no RK817 access. REBOOT FIRST
# (IRQ 29 is still off from test_51). Takes about 10 s.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t sudo dmesg -w
#   ssh -t p25t 'cd tests && sudo bash test_52.sh 2>&1' | tee result_52.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera driver, receiver watch (test_52) ==="
date; uname -rv
[ "$(id -u)" -eq 0 ] || stop "run with sudo"
for c in media-ctl v4l2-ctl python3; do command -v $c >/dev/null || stop "$c missing"; done
[ -e /sys/bus/i2c/drivers/gc02m2/2-0010 ] || stop "gc02m2 not bound (front DTB active?)"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] && [ "$(cat "$VDEV/power/control")" = on ] || stop "VICAP power/control is not 'on' (udev rule)"
IRQ=$(awk '/rockchip-cif/ {sub(":", "", $1); print $1}' /proc/interrupts)
say "VICAP irq $IRQ: $(awk '/rockchip-cif/ {print $2}' /proc/interrupts) so far"
dmesg | grep -q "Disabling IRQ #$IRQ" && stop "IRQ $IRQ was switched off on this boot - reboot first"

M=/dev/media0
SENS=$(media-ctl -d $M -e "gc02m2 2-0010") || stop "no gc02m2 entity"
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0") || stop "no rkcif-mipi0-id0 entity"

cat > /tmp/p25t_mon52.py <<'EOF'
import mmap, os, struct, sys, time
vp = int(sys.argv[1])
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def mp(b): return mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=b)
grf, phy, csi, cif = mp(0xfdc60000), mp(0xfe870000), mp(0xfdfb0000), mp(0xfdfe0000)
r = lambda m, o: struct.unpack("<I", m[o:o + 4])[0]
def alive():
    try:
        os.kill(vp, 0); return True
    except OSError:
        return False
t0 = time.monotonic()
while time.monotonic() - t0 < 0.3:      # let stream-on happen
    time.sleep(0.02)
if not alive():
    print("   capture ended before the first sample"); sys.exit(0)
print("   config: GRF VI_CON0 0x%04x VI_CON1 0x%04x | PHY lane-enable 0x%02x dual 0x%02x THS clk 0x%02x l0 0x%02x l2 0x%02x clk1 0x%02x | CSI N_LANES %d RESETN %d"
      % (r(grf, 0x340) & 0xffff, r(grf, 0x344) & 0xffff, r(phy, 0x00), r(phy, 0x80), r(phy, 0x160),
         r(phy, 0x1e0), r(phy, 0x2e0), r(phy, 0x3e0), r(csi, 0x04), r(csi, 0x10)), flush=True)
print("   VICAP ID0 CTRL0 0x%08x CTRL1 0x%08x (w %d h %d) VLW 0x%x | INTEN 0x%08x"
      % (r(cif, 0x80), r(cif, 0x84), r(cif, 0x84) & 0x1fff, r(cif, 0x84) >> 16, r(cif, 0xb4), r(cif, 0x124)), flush=True)
last = None
while alive() and time.monotonic() - t0 < 4:
    st = r(csi, 0x14)
    row = (st, r(csi, 0x20), r(csi, 0x24), r(cif, 0x128))
    if row != last:
        print("   %5.2f s  CSI PHY_STATE 0x%04x (clk HS %d) ERR1 0x%08x ERR2 0x%08x | VICAP INTSTAT 0x%08x"
              % ((time.monotonic() - t0,) + (st, (st >> 8) & 1) + row[1:]), flush=True)
        last = row
    time.sleep(0.1)
EOF

capture() {   # capture <name> <width> <height>
    local name=$1 w=$2 h=$3 code fr rc before vp
    say ""
    say "--- $name: ${w}x$h, no flip ($(date +%T))"
    v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=horizontal_flip=0
    media-ctl -d $M -V "\"gc02m2 2-0010\":0 [fmt:SRGGB10_1X10/${w}x$h field:none]" &&
    media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:SRGGB10_1X10/${w}x$h field:none]" &&
    media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:SRGGB10_1X10/${w}x$h field:none]" &&
    media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:SRGGB10_1X10/${w}x$h field:none crop:(0,0)/${w}x$h]" || say "   WARNING: media-ctl -V failed"
    media-ctl -d $M --get-v4l2 "\"gc02m2 2-0010\":0"
    v4l2-ctl -d "$VID" --set-fmt-video=width=$w,height=$h,pixelformat=RG10 >/dev/null || say "   WARNING: set-fmt-video failed"
    v4l2-ctl -d "$VID" --get-fmt-video | grep -E "Width|Pixel Format|Bytes per Line|Size Image" | sed 's/^/   /'
    fr=$((w * h * 2))
    before=$(dmesg | grep -c "Page fault")
    rm -f all.raw
    timeout 8 v4l2-ctl -d "$VID" --stream-mmap --stream-count=20 --stream-to=all.raw >/dev/null 2>&1 &
    vp=$!
    python3 /tmp/p25t_mon52.py $vp
    wait $vp; rc=$?; sync
    say "   exit $rc (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / fr )) of 20 frames; irq $IRQ count $(awk '/rockchip-cif/ {print $2}' /proc/interrupts)"
    if [ -s all.raw ]; then
        tail -c $((fr * 2)) all.raw > "cam52_$name.raw"; rm -f all.raw
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "cam52_$name.raw"
        say "   kept cam52_$name.raw (2 frames, RG10)"
    fi
    dmesg | grep -iE "page fault|nobody cared|Disabling IRQ" | tail -4
    sleep 1; say "   alive"
    [ "$(dmesg | grep -c "Page fault")" -eq "$before" ] || return 1
    [ -s "cam52_$name.raw" ] || return 1
    return 0
}

if capture 1296 1296 972; then
    capture 1600 1600 1200 || say "1600x1200 failed (1296x972 worked)"
else
    say "1296x972 failed - 1600x1200 not tried"
fi
rm -f /tmp/p25t_mon52.py

say ""
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -10
say "=== done ==="
