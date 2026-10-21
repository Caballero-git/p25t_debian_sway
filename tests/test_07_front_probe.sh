#!/bin/bash
# test_47.sh - front camera, step 1: does the GC02M2 answer?
#
# Stock DT (Android): front sensor "galaxycore,gc02m2" at i2c2 0x10, reset
# GPIO4_B0 (active high), powerdown GPIO4_B3 (active low), MCLK = the same
# CLK_CIF_OUT pin as the rear camera, power domain PD_VI, 1 MIPI lane on
# the D-PHY's second half (lanes 2-3, split mode). Expected chip ID at
# registers 0xf0/0xf1: 02 f0 (Rockchip's gc02m2.c).
# No kernel driver yet: this powers the sensor by hand and reads its ID.
#
#   sudo bash test_47.sh | tee result_47.txt
#
# What it does (about 3 s):
#  1. keeps the rear sensor powered for the test (sysfs power/control =
#     on), so MCLK (24 MHz) and the camera power domain are on;
#  2. reads 0xf0/0xf1 at i2c2 addresses 0x10, 0x21, 0x3c before anything;
#  3. GPIO4_B0/B3 as GPIO outputs, Rockchip's power-on order: reset on,
#     powerdown off, reset off - then reads the ID again;
#  4. if 0x10 stays silent: tries all four B0/B3 levels;
#  5. puts back the pin setup, the GPIO registers and power/control as
#     found.
# Writes: GRF pin mux of GPIO4_B0/B3, GPIO4 direction/level of B0/B3
# (both restored), sysfs power/control of the rear sensor (restored).
# No RK817 (power chip) access.
set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
echo "=== front camera probe (test_47) ==="
date; uname -rv

RDEV=/sys/bus/i2c/devices/2-0037
[ -e "$RDEV/power/control" ] || { echo "ABORT: rear sensor 2-0037 not found"; exit 1; }
for r in vdda_0v9 vcc1v8_dvp vcc2v8_dvp vcc_camera; do
    for n in /sys/class/regulator/*/name; do
        [ "$(cat "$n")" = "$r" ] && echo "regulator $r: $(cat "${n%/name}/microvolts" 2>/dev/null) uV, $(cat "${n%/name}/state" 2>/dev/null)"
    done
done
OLDCTL=$(cat "$RDEV/power/control")
echo on > "$RDEV/power/control"
sleep 0.3
echo "rear sensor: power/control $OLDCTL -> on, runtime_status $(cat "$RDEV/power/runtime_status")"

cat > /tmp/p25t_front.py <<'EOF'
import fcntl, mmap, os, struct, time
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
def mp(base): return mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
grf, gpio, cru = mp(0xfdc60000), mp(0xfe770000), mp(0xfdd20000)
r32 = lambda m, o: struct.unpack("<I", m[o:o + 4])[0]
def w32(m, o, v): m[o:o + 4] = struct.pack("<I", v)
IOMUX_B_L = 0x68              # GRF_GPIO4B_IOMUX_L: B0 bits 2:0, B3 bits 14:12
DR_L, DDR_L, EXT = 0x00, 0x08, 0x70
B0, B3 = 8, 11                # bit numbers in the 32-bit port (B0 = 8, B3 = 11)

def hi(m, off, bit, val):     # hiword write of one bit in a _L register
    w32(m, off, (1 << (bit + 16)) | ((val & 1) << bit))
def pins():
    e = r32(gpio, EXT)
    return "B0=%d B3=%d" % ((e >> B0) & 1, (e >> B3) & 1)

i2c = os.open("/dev/i2c-2", os.O_RDWR)
def rd(addr, reg):
    try:
        fcntl.ioctl(i2c, 0x0706, addr)          # I2C_SLAVE_FORCE
        os.write(i2c, bytes((reg,)))
        return "%02x" % os.read(i2c, 1)[0]
    except OSError:
        return "--"
def ids(tag):
    out = []
    for a in (0x10, 0x21, 0x3c):
        out.append("0x%02x: %s %s" % (a, rd(a, 0xf0), rd(a, 0xf1)))
    print("%-34s %s | %s" % (tag, " | ".join(out), pins()), flush=True)
    return out[0].endswith("02 f0")

mux0, ddr0, dr0 = r32(grf, IOMUX_B_L), r32(gpio, DDR_L), r32(gpio, DR_L)
gate = (r32(cru, 0x300 + 4 * 19) >> 8) & 1
print("found: GPIO4B_IOMUX_L 0x%04x (B0 func %d, B3 func %d), DDR_L 0x%04x, DR_L 0x%04x; MCLK gate %s"
      % (mux0 & 0xffff, mux0 & 7, (mux0 >> 12) & 7, ddr0 & 0xffff, dr0 & 0xffff,
         "OPEN (clock running)" if gate == 0 else "closed (no clock!)"), flush=True)
ids("before (front not powered by us)")

# pins as GPIO, outputs
w32(grf, IOMUX_B_L, (0x7 << 16) | (0x7 << 28))          # func 0 for B0 and B3
hi(gpio, DR_L, B0, 1); hi(gpio, DR_L, B3, 0)             # reset on, powerdown on
hi(gpio, DDR_L, B0, 1); hi(gpio, DDR_L, B3, 1)
time.sleep(0.01)
ids("reset on, powerdown on")
hi(gpio, DR_L, B3, 1); time.sleep(0.002)                # powerdown off (high)
hi(gpio, DR_L, B0, 0); time.sleep(0.01)                 # reset off (low)
found = ids("Rockchip order: B3 high, B0 low")
if not found:
    for b0 in (0, 1):
        for b3 in (0, 1):
            hi(gpio, DR_L, B0, b0); hi(gpio, DR_L, B3, b3); time.sleep(0.02)
            if ids("levels B0=%d B3=%d" % (b0, b3)): found = True

# back as found: levels first, then direction, then mux
hi(gpio, DR_L, B0, (dr0 >> B0) & 1); hi(gpio, DR_L, B3, (dr0 >> B3) & 1)
hi(gpio, DDR_L, B0, (ddr0 >> B0) & 1); hi(gpio, DDR_L, B3, (ddr0 >> B3) & 1)
w32(grf, IOMUX_B_L, (0x7 << 16) | (0x7 << 28) | (mux0 & 0x7) | (mux0 & 0x7000))
print("restored: GPIO4B_IOMUX_L 0x%04x, DDR_L 0x%04x, DR_L 0x%04x"
      % (r32(grf, IOMUX_B_L) & 0xffff, r32(gpio, DDR_L) & 0xffff, r32(gpio, DR_L) & 0xffff))
print("RESULT: GC02M2 chip ID 02 f0 at 0x10: %s" % ("FOUND" if found else "not seen"))
EOF

echo
python3 /tmp/p25t_front.py
echo "$OLDCTL" > "$RDEV/power/control"
echo "rear sensor power/control back to $(cat "$RDEV/power/control")"
rm -f /tmp/p25t_front.py
echo "=== done ==="
