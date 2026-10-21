#!/bin/bash
# test_49.sh - front camera, step 3: vertical flip in the sensor
#
# test_48 (2026-10-19): first front pictures (58 frames, ~20 fps, no
# receiver errors, rear pipeline recovered afterwards). Jose: the picture
# is correct but upside down - a reflection about the horizontal mid line
# gives the expected view. Rockchip's driver has a VFLIP control: page 0
# register 0x17 bit 1 (bit 0 = mirror); its init table writes 0x80.
# This test is test_48 with ONE change: 0x17 = 0x82 (vertical flip on).
# Expected: the picture upright. To check as well: whether the Bayer
# order stays RGGB (a flip can move the first row from R/G to G/B).
#   -> cam49_front.raw (last 3 frames of the front phase)
# Writes: as test_48 (all restored). No RK817 access. Takes about 15 s.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t 'sudo dmesg -w'
#   ssh -t p25t 'cd tests && sudo bash test_49.sh 2>&1' | tee result_49.txt

set -u
say() { echo "$@"; sync; }
stop() { say "STOP: $*"; exit 1; }
say "=== front camera, vertical flip 0x17 = 0x82 (test_49) ==="
date; uname -rv
[ "$(id -u)" -eq 0 ] || stop "run with sudo"
for c in media-ctl v4l2-ctl python3 mkfifo; do command -v $c >/dev/null || stop "$c missing"; done
[ -e /sys/bus/i2c/devices/2-0037 ] || stop "rear sensor 2-0037 not found"
[ -e /dev/i2c-2 ] || stop "/dev/i2c-2 missing"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] || stop "VICAP fdfe0000 not found"
[ "$(cat "$VDEV/power/control")" = on ] || stop "VICAP power/control is not 'on' (udev rule) - a capture restart would freeze"
grep -l vdda_0v9 /sys/class/regulator/*/name 2>/dev/null | head -1 | while read -r n; do
    say "regulator vdda_0v9: $(cat "${n%/name}/microvolts") uV (1200000 expected)"; done

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || stop "media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null || stop "set-fmt failed"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
FR=$((W * H * 2))
OUT="$PWD/cam49_front.raw"; rm -f "$OUT"

SH=/dev/shm/p25t49
rm -rf "$SH"; mkdir -p "$SH"; mkfifo "$SH/fifo"; echo rear > "$SH/phase"
cat > "$SH/keeper.py" <<'PYEOF'
# keeper: reads raw frames from the fifo, tags each with the current phase,
# keeps the last 3 "front" frames, publishes the frame count.
import os, sys, time
sh, fr, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
f = open(os.path.join(sh, "fifo"), "rb", buffering=0)
buf = bytearray(fr); mv = memoryview(buf); px = mv.cast("H")
front, n, t0, last, per = [], 0, None, None, {}
def phase():
    try:
        with open(os.path.join(sh, "phase")) as p: return p.read().strip() or "?"
    except OSError: return "?"
while True:
    got = 0
    while got < fr:
        k = f.readinto(mv[got:])
        if not k: break
        got += k
    if got < fr: break
    n += 1
    now = time.monotonic(); t0 = t0 or now
    ph = phase()
    s = px[::4099].tolist()
    mean, mx = sum(s) / len(s), max(s)
    c = per.setdefault(ph, [0, 0.0, now - t0, 0])
    c[0] += 1; c[1] += mean; c[3] = now - t0
    if ph != last or c[0] <= 3 or n % 10 == 0:
        print("frame %4d  t=%6.2f s  phase %-6s  mean %6.1f  max %4d" % (n, now - t0, ph, mean, mx), flush=True)
    last = ph
    with open(os.path.join(sh, "count.tmp"), "w") as cf: cf.write(str(n))
    os.replace(os.path.join(sh, "count.tmp"), os.path.join(sh, "count"))
    if ph == "front":
        front.append(bytes(buf)); front = front[-3:]
if got: print("(last %d bytes: a partial frame, dropped)" % got)
print("frames per phase:")
for ph, (k, sm, ta, tb) in per.items():
    fps = (k - 1) / (tb - ta) if k > 1 and tb > ta else 0
    print("  %-6s %4d frames, mean level %6.1f, %.1f fps" % (ph, k, sm / k, fps))
if front:
    with open(out, "wb") as o:
        for b in front: o.write(b)
    print("kept the last %d front-phase frames: %s (%d bytes)" % (len(front), out, len(front) * fr))
else:
    print("no frame arrived during the front phase - nothing kept")
PYEOF
cat > "$SH/front.py" <<'PYEOF'
# front: switch the CSI-2 receiver from the rear sensor (D-PHY lanes 0-1,
# full mode) to the front GC02M2 (lanes 2-3, split mode) during a running
# rear capture, stream the front for 3 s, then put everything back.
import fcntl, mmap, os, struct, sys, time
VP, SH = int(sys.argv[1]), sys.argv[2]
TABLE = """
fc01 f441 f5c0 f644 f838 f982 fa00 fd80 fc81 fe03 010b f701 fc80 fc80 fc80 fc8e fe00 8709
ee72 fe01 8c90 fe00 9000 0304 047d 4104 42f4 0504 0648 0700 0818 9d18 0900 0a02 0d04 0ebc
1782 1904 2400 5620 5b00 5e01 213c 4420 cc01 1a04 1f11 2730 2b00 3300 5390 e650 3907 4304
462a 7ca0 d0be d140 d240 d3b3 de1c cd06 ce6f fc88 fe10 fe00 fc8e fe00 fe00 fe00 fe00 fc88
fe10 fe00 fc8e fe04 e001 fe00 fe01 5354 8753 8903 fe00 b074 b104 b200 b600 fe04 d800 c040
c000 c000 c000 c060 c000 c0c0 c02a c080 c000 c000 c040 c0a0 c000 c090 c019 c0c0 c000 c0d0
c02f c0e0 c000 c090 c039 c000 c001 c020 c004 c020 c001 c0e0 c00f c040 c001 c0e0 c01a c060
c001 c020 c025 c080 c001 c0a0 c02c c0a0 c001 c0e0 c032 c0c0 c001 c020 c038 c0e0 c001 c060
c03c c000 c002 c0a0 c040 c080 c002 c018 c05c fe00 9f10 fe00 2620 fe01 4022 467f 490f 4af0
fe04 1480 1580 1680 1780 fe01 4120 4c00 4d0c 4408 4803 fe01 9001 9100 9278 9300 949e 9503
96cc 9705 9810 fe03 0123 03ce 0448 1501 2110 2205 2320 2520 2608 2906 2a0a 2b08 fe01 8c10
""".split()           # GC02M2 init, "RRVV" hex (BSP table, window 1296x972)

def say(*a): print(*a, flush=True)
def alive():
    try:
        os.kill(VP, 0); return True
    except OSError:
        return False
def frames():
    try:
        with open(SH + "/count") as c: return int(c.read())
    except (OSError, ValueError):
        return 0
def setphase(p):
    with open(SH + "/phase.tmp", "w") as f: f.write(p)
    os.replace(SH + "/phase.tmp", SH + "/phase")

t = time.monotonic()
while frames() < 3:
    if not alive() or time.monotonic() - t > 10:
        say("STOP: the rear capture did not deliver 3 frames (got %d) - nothing changed" % frames())
        sys.exit(3)
    time.sleep(0.05)
say("rear capture running: %d frames after %.1f s" % (frames(), time.monotonic() - t))

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
def mp(base): return mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
grf, gpio, phy, csi, cif = mp(0xfdc60000), mp(0xfe770000), mp(0xfe870000), mp(0xfdfb0000), mp(0xfdfe0000)
r32 = lambda m, o: struct.unpack("<I", m[o:o + 4])[0]
def w32(m, o, v): m[o:o + 4] = struct.pack("<I", v)
def grfw(off, mask, val): w32(grf, off, (mask << 16) | (val & mask))   # hiword write
VI_CON0, VI_CON1 = 0x340, 0x344
P_LANE, P_DUAL, P_CLK_TS, P_L0_TS, P_L1_TS, P_L2_TS, P_CLK1_TS, P_CLK1_PH = 0x00, 0x80, 0x160, 0x1e0, 0x260, 0x2e0, 0x3e0, 0xcc
C_NLANES, C_RESETN, C_STATE, C_ERR1, C_ERR2, C_SHUTDOWNZ, C_RSTZ = 0x04, 0x10, 0x14, 0x20, 0x24, 0x40, 0x44
V_INTSTAT = 0x128
IOMUX_B_L, DR_L, DDR_L, EXT, B0, B3 = 0x68, 0x00, 0x08, 0x70, 8, 11
def hi(off, bit, val): w32(gpio, off, (1 << (bit + 16)) | ((val & 1) << bit))

i2c = os.open("/dev/i2c-2", os.O_RDWR)
def wr(a, reg, val):
    try:
        fcntl.ioctl(i2c, 0x0706, a); os.write(i2c, bytes((reg, val))); return True
    except OSError:
        return False
def rd(a, reg):
    try:
        fcntl.ioctl(i2c, 0x0706, a); os.write(i2c, bytes((reg,))); return os.read(i2c, 1)[0]
    except OSError:
        return None
def h(v): return "--" if v is None else "%02x" % v

def state(tag):
    if not alive():
        say("  %-26s (capture ended - receiver registers not read)" % tag); return
    st = r32(csi, C_STATE)
    say("  %-26s frames %4d | CSI PHY_STATE 0x%04x (clk HS %d, stopstate clk %d data %x) ERR1 0x%08x ERR2 0x%08x | VICAP INTSTAT 0x%08x"
        % (tag, frames(), st, (st >> 8) & 1, (st >> 10) & 1, (st >> 4) & 0xf, r32(csi, C_ERR1), r32(csi, C_ERR2), r32(cif, V_INTSTAT)))

# ---- found state ------------------------------------------------------------
o = dict(con0=r32(grf, VI_CON0) & 0xffff, con1=r32(grf, VI_CON1) & 0xffff,
         mux=r32(grf, IOMUX_B_L) & 0xffff, ddr=r32(gpio, DDR_L) & 0xffff, dr=r32(gpio, DR_L) & 0xffff)
with open(SH + "/grf_saved", "w") as f:
    f.write("%d %d %d %d %d\n" % (o["con0"], o["con1"], o["mux"], o["ddr"], o["dr"]))
o.update(lane=r32(phy, P_LANE), dual=r32(phy, P_DUAL), l2=r32(phy, P_L2_TS), c1=r32(phy, P_CLK1_TS), nl=r32(csi, C_NLANES))
say("found: GRF VI_CON0 0x%04x VI_CON1 0x%04x | PHY lane-enable 0x%02x dual/cal 0x%02x THS clk 0x%02x l0 0x%02x l1 0x%02x l2 0x%02x clk1 0x%02x clk1-phase 0x%02x"
    % (o["con0"], o["con1"], o["lane"], o["dual"], r32(phy, P_CLK_TS), r32(phy, P_L0_TS), r32(phy, P_L1_TS), o["l2"], o["c1"], r32(phy, P_CLK1_PH)))
say("       CSI N_LANES %d (= %d lanes) RESETN %d SHUTDOWNZ %d DPHY_RSTZ %d | GPIO4B mux 0x%04x DDR 0x%04x DR 0x%04x"
    % (o["nl"], o["nl"] + 1, r32(csi, C_RESETN), r32(csi, C_SHUTDOWNZ), r32(csi, C_RSTZ), o["mux"], o["ddr"], o["dr"]))
say("1. rear sensor streaming (reference):")
for i in range(4):
    state("rear %d" % i); time.sleep(0.25)

changed = {"rear": None, "pins": False, "route": False, "front_on": False}
ok = False
try:
    # ---- 2. rear sensor to standby --------------------------------------
    wr(0x37, 0xfe, 0x00); r3e = rd(0x37, 0x3e)
    if r3e is None: raise RuntimeError("rear sensor 0x37 does not answer")
    wr(0x37, 0x3e, 0x00); changed["rear"] = r3e
    setphase("gap")
    say("2. rear sensor standby (its 0x3e was 0x%02x, now %s)" % (r3e, h(rd(0x37, 0x3e))))
    time.sleep(0.4); state("rear standby")

    # ---- 3. front sensor power-up (as test_47) ---------------------------
    changed["pins"] = True
    grfw(IOMUX_B_L, 0x7007, 0)                  # func 0 (GPIO) for B0 and B3
    hi(DR_L, B0, 1); hi(DR_L, B3, 0); hi(DDR_L, B0, 1); hi(DDR_L, B3, 1)
    time.sleep(0.01)
    hi(DR_L, B3, 1); time.sleep(0.002)          # powerdown off
    hi(DR_L, B0, 0); time.sleep(0.01)           # reset off
    cid = (h(rd(0x10, 0xf0)), h(rd(0x10, 0xf1)))
    say("3. front sensor powered: chip ID %s %s" % cid)
    if cid != ("02", "f0"): raise RuntimeError("GC02M2 not answering")

    # ---- 4. init table --------------------------------------------------
    bad = [tok for tok in TABLE if not wr(0x10, int(tok[:2], 16), int(tok[2:], 16))]
    say("4. init table: %d writes, %d failed%s" % (len(TABLE), len(bad), (" " + " ".join(bad[:8])) if bad else ""))
    wr(0x10, 0xfe, 0x01)
    win = [rd(0x10, r) for r in range(0x91, 0x99)]
    wr(0x10, 0xfe, 0x00)
    w16 = lambda i: -1 if None in win[i:i + 2] else win[i] << 8 | win[i + 1]
    say("   window: y %d x %d, %d lines x %d pixels | exposure 0x%s%s | VTS 0x%s%s | mirror/flip 0x17 = %s"
        % (w16(0), w16(2), w16(4), w16(6), h(rd(0x10, 0x03)), h(rd(0x10, 0x04)), h(rd(0x10, 0x41)), h(rd(0x10, 0x42)),
           h(rd(0x10, 0x17))))
    if len(bad) > 3: raise RuntimeError("too many failed writes")

    # ---- 5. route D-PHY lanes 2-3 (split mode) to the CSI-2 receiver ----
    if not alive(): raise RuntimeError("capture ended before the switch")
    changed["route"] = True
    w32(phy, P_DUAL, 0x5e); w32(phy, P_DUAL, 0x5f)          # dual mode, reset digital part
    w32(phy, P_LANE, o["lane"] | (1 << 4) | (1 << 6))       # data lane 2 + clock lane
    grfw(VI_CON0, 0x00c0, 0x0040)                           # DATALANE_EN1 = lane 2
    grfw(VI_CON0, 0x0400, 0x0400)                           # CLKLANE1_EN
    grfw(VI_CON0, 0x000f, 0x0000)                           # FORCERXMODE off
    grfw(VI_CON1, 0x1880, 0x0880)                           # split; CIF <- lanes 2-3; ISP <- 0-1
    w32(phy, P_CLK1_TS, (o["c1"] & ~0x7f) | 0x10)           # THS settle for 600-699 Mbps
    w32(phy, P_L2_TS, (o["l2"] & ~0x7f) | 0x10)
    w32(csi, C_RESETN, 0); w32(csi, C_NLANES, 0); w32(csi, C_RESETN, 1)   # 1 lane
    say("5. routed: GRF VI_CON0 0x%04x VI_CON1 0x%04x | PHY lane-enable 0x%02x dual 0x%02x THS l2 0x%02x clk1 0x%02x | CSI N_LANES %d"
        % (r32(grf, VI_CON0) & 0xffff, r32(grf, VI_CON1) & 0xffff, r32(phy, P_LANE), r32(phy, P_DUAL),
           r32(phy, P_L2_TS), r32(phy, P_CLK1_TS), r32(csi, C_NLANES)))
    state("routed, front idle")

    # ---- 6. front stream on, watch 3 s ----------------------------------
    setphase("front")
    wr(0x10, 0xfe, 0x00); wr(0x10, 0x3e, 0x90); changed["front_on"] = True
    say("6. front stream on (0x3e = %s):" % h(rd(0x10, 0x3e)))
    f0 = frames()
    for i in range(12):
        time.sleep(0.25); state("front %4.2f s" % ((i + 1) * 0.25))
    say("   frames during the front phase: %d" % (frames() - f0))
    ok = True
except Exception as e:
    say("STOPPED: %s" % e)
finally:
    os.sync()
    if changed["front_on"]:
        wr(0x10, 0xfe, 0x00); wr(0x10, 0x3e, 0x00)
    setphase("back")
    if changed["route"]:
        if alive():
            w32(csi, C_RESETN, 0); w32(csi, C_NLANES, o["nl"]); w32(csi, C_RESETN, 1)
            w32(phy, P_L2_TS, o["l2"]); w32(phy, P_CLK1_TS, o["c1"])
            w32(phy, P_LANE, o["lane"])
            w32(phy, P_DUAL, o["dual"] & ~1); w32(phy, P_DUAL, o["dual"])
        else:
            say("   capture already ended: PHY/CSI are reprogrammed by the next stream-on")
        grfw(VI_CON0, 0x04cf, o["con0"]); grfw(VI_CON1, 0x1880, o["con1"])
    if changed["pins"]:
        hi(DR_L, B0, (o["dr"] >> B0) & 1); hi(DR_L, B3, (o["dr"] >> B3) & 1)
        hi(DDR_L, B0, (o["ddr"] >> B0) & 1); hi(DDR_L, B3, (o["ddr"] >> B3) & 1)
        grfw(IOMUX_B_L, 0x7007, o["mux"])
    say("7. restored: GRF VI_CON0 0x%04x VI_CON1 0x%04x | GPIO4B mux 0x%04x DDR 0x%04x DR 0x%04x"
        % (r32(grf, VI_CON0) & 0xffff, r32(grf, VI_CON1) & 0xffff, r32(grf, IOMUX_B_L) & 0xffff,
           r32(gpio, DDR_L) & 0xffff, r32(gpio, DR_L) & 0xffff))
    if alive():
        say("   PHY lane-enable 0x%02x dual 0x%02x THS l2 0x%02x clk1 0x%02x | CSI N_LANES %d"
            % (r32(phy, P_LANE), r32(phy, P_DUAL), r32(phy, P_L2_TS), r32(phy, P_CLK1_TS), r32(csi, C_NLANES)))
    if changed["rear"] is not None:
        wr(0x37, 0xfe, 0x00); wr(0x37, 0x3e, changed["rear"])
        say("8. rear sensor streaming again (0x3e = %s), does the rear pipeline recover?" % h(rd(0x37, 0x3e)))
        f1 = frames()
        for i in range(4):
            time.sleep(0.25); state("rear again %d" % i)
        say("   rear frames after the restore: %d" % (frames() - f1))
    os.remove(SH + "/grf_saved")
say("RESULT: %s" % ("front phase ran (see frames above)" if ok else "stopped early"))
PYEOF

python3 "$SH/keeper.py" "$SH" $FR "$OUT" > "$SH/keeper.log" 2>&1 &
KP=$!
timeout 40 v4l2-ctl -d "$VID" --stream-mmap --stream-count=2000 --stream-to="$SH/fifo" >/dev/null 2>&1 &
VP=$!
say "capture started ($(date +%T)); keeper pid $KP, capture pid $VP"
echo
python3 "$SH/front.py" $VP "$SH"
RC=$?
sync
if [ -f "$SH/grf_saved" ]; then       # front.py died before its clean-up
    say "front.py exit $RC without clean-up: putting back GRF VI_CON0/1 and GPIO4_B0/B3"
    read -r C0 C1 MUX DDR DR < "$SH/grf_saved"
    python3 - "$C0" "$C1" "$MUX" "$DDR" "$DR" <<'PYEOF'
import mmap, os, struct, sys
c0, c1, mux, ddr, dr = (int(x) for x in sys.argv[1:6])
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
grf = mmap.mmap(fd, 0x1000, offset=0xfdc60000); gpio = mmap.mmap(fd, 0x1000, offset=0xfe770000)
w = lambda m, o, v: m.__setitem__(slice(o, o + 4), struct.pack("<I", v))
w(grf, 0x340, (0x04cf << 16) | (c0 & 0x04cf)); w(grf, 0x344, (0x1880 << 16) | (c1 & 0x1880))
for b in (8, 11):
    w(gpio, 0x00, (1 << (b + 16)) | (((dr >> b) & 1) << b)); w(gpio, 0x08, (1 << (b + 16)) | (((ddr >> b) & 1) << b))
w(grf, 0x68, (0x7007 << 16) | (mux & 0x7007))
print("done")
PYEOF
fi
kill $VP 2>/dev/null; wait $VP 2>/dev/null
( sleep 10; kill $KP 2>/dev/null ) &   # keeper stuck if the capture never opened the fifo
WD=$!; wait $KP; kill $WD 2>/dev/null
echo
say "--- keeper (frames as they arrived) ---"
cat "$SH/keeper.log"
[ -f "$OUT" ] && [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$OUT"
rm -rf "$SH"
sleep 1; say "alive ($(date +%T))"
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -12
say "=== done ==="
