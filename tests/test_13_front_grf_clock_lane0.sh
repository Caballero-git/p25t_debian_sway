#!/bin/bash
# test_53.sh - front camera driver: clock lane 0 enabled as in test_48
#
# test_52 (2026-10-19): 1296x972 capture. The VICAP was set up exactly as
# for the rear camera (1296x972, line 2592 bytes), the CSI-2 host saw the
# HS clock and no errors at 0.3 s - then the tablet froze (sampling
# registers while the VICAP/IOMMU went wrong, probably the same buffer
# overrun as test_51).
# Remaining difference from the hand test that worked (test_48):
#   GRF VI_CON0  0x0440 now  (lanes 2-3 + clock lane 1 only)
#                0x0570 then (also data lanes 0-1, bits 5:4, and clock
#                             lane 0, bit 8, left on by the rear camera)
#   D-PHY lane enable 0x51 now, 0x5d then (lanes 0-1 bits 3:2 on)
# The GRF bits survive a stream start (the split-mode code does not touch
# them), so this test sets VI_CON0 bits 8 and 5:4 BEFORE the capture, as
# test_48 had them, and changes nothing else. One 1296x972 capture of 5
# frames, no register reads while streaming. VI_CON0 is put back after.
# Writes: GRF VI_CON0 bits 8, 5, 4 (restored). No RK817 access.
# REBOOT FIRST. Takes about 10 s; if the tablet freezes again, a long
# press on power is needed (RK817 settings come back from the DT).
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t sudo dmesg -w
#   ssh -t p25t 'cd tests && sudo bash test_53.sh 2>&1' | tee result_53.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera driver, GRF clock lane 0 on (test_53) ==="
date; uname -rv
[ "$(id -u)" -eq 0 ] || stop "run with sudo"
for c in media-ctl v4l2-ctl python3; do command -v $c >/dev/null || stop "$c missing"; done
[ -e /sys/bus/i2c/drivers/gc02m2/2-0010 ] || stop "gc02m2 not bound (front DTB active?)"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] && [ "$(cat "$VDEV/power/control")" = on ] || stop "VICAP power/control is not 'on' (udev rule)"
dmesg | grep -q "Disabling IRQ" && stop "an IRQ was switched off on this boot - reboot first"
dmesg | grep -q "Page fault" && stop "an IOMMU page fault happened on this boot already - reboot first"

grf() {   # grf get | grf set <mask> <value>   (VI_CON0, hiword write)
python3 - "$@" <<'EOF'
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfdc60000)
if sys.argv[1] == "set":
    mask, val = int(sys.argv[2], 0), int(sys.argv[3], 0)
    m[0x340:0x344] = struct.pack("<I", (mask << 16) | (val & mask))
print("0x%04x" % (struct.unpack("<I", m[0x340:0x344])[0] & 0xffff))
EOF
}

OLD=$(grf get)
say "GRF VI_CON0 before: $OLD (VI_CON1 is set by the driver at stream start)"
NEW=$(grf set 0x0130 0x0130)
say "GRF VI_CON0 now:    $NEW (bit 8 clock lane 0, bits 5:4 data lanes 0-1 on)"

M=/dev/media0
SENS=$(media-ctl -d $M -e "gc02m2 2-0010") || stop "no gc02m2 entity"
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0") || stop "no rkcif-mipi0-id0 entity"
W=1296; H=972; F=SRGGB10_1X10
v4l2-ctl -d "$SENS" --set-ctrl=vertical_flip=0 --set-ctrl=horizontal_flip=0
media-ctl -d $M -V "\"gc02m2 2-0010\":0 [fmt:$F/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$F/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$F/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$F/${W}x$H field:none crop:(0,0)/${W}x$H]" || say "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=RG10 >/dev/null || say "WARNING: set-fmt-video failed"
FR=$((W * H * 2))

say "capture, 5 frames ($(date +%T))"
rm -f all.raw cam53_1296.raw
timeout 8 v4l2-ctl -d "$VID" --stream-mmap --stream-count=5 --stream-to=all.raw >/dev/null 2>&1
RC=$?; sync
say "exit $RC (124 = timeout); $(( $(stat -c %s all.raw 2>/dev/null || echo 0) / FR )) of 5 frames; irq count $(awk '/rockchip-cif/ {print $2}' /proc/interrupts)"
dmesg | grep -iE "page fault|nobody cared|Disabling IRQ" | tail -3
if [ -s all.raw ]; then
    tail -c $((FR * 2)) all.raw > cam53_1296.raw; rm -f all.raw
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam53_1296.raw
    say "kept cam53_1296.raw (2 frames, RG10)"
fi

say "GRF VI_CON0 back: $(grf set 0x0130 "$OLD")"
sleep 1; say "alive ($(date +%T))"
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
say "=== done ==="
