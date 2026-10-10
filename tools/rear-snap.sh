#!/bin/bash
# rear-snap.sh - take a photo with the P25T rear camera (GC5035) as a PNG.
#
#   rear-snap [-e EXPOSURE] [-g GAIN] [-n FRAMES] [-r auto|0|90|180|270] [-k] [FILE]
#
#   FILE  output PNG; "{now}" in the name becomes the date and time,
#         e.g. photo_{now}.png -> photo_20261008-091530.png.
#         Default: photo_{now}.png in the current folder.
#   -e    exposure in lines, 4..1992 (default 1992 = longest at 1296x972)
#   -g    analogue gain, 256 = 1x .. 4096 = 16x (default 1024 = 4x)
#   -n    frames to capture; the last one is kept (default 20 - the first
#         frames after stream-on are dark)
#   -r    clockwise rotation of the picture (default auto: from the
#         accelerometer - landscape the usual way 180, portrait with the
#         landscape-left edge up 270, the other portrait 90, landscape
#         upside down 0; lying flat 180)
#   -k    also keep the raw frame next to the PNG (FILE with .raw)
#
# Picture: 648x486 (2x2 binning of the 1296x972 raw frame, Bayer RGGB),
# grey-world white balance, auto brightness - see raw2png.py.
# Needs: patch 0030 (RK817 LDO2 at 1.2 V) and the udev rule
# 99-p25t-vicap.rules (VICAP kept powered; without it a second capture
# freezes the tablet). Both are checked first.
# Access: run with sudo, or be in group "video" for /dev/media0,
# /dev/video* and /dev/v4l-subdev*.
#
# Install on the tablet (from the repo's tools folder):
#   sudo install -m 755 rear-snap.sh /usr/local/bin/rear-snap
#   sudo install -D -m 644 raw2png.py /usr/local/lib/p25t/raw2png.py
# python3-numpy makes the PNG step fast (without it: pure Python, slow).

set -u
EXP=1992; GAIN=1024; FRAMES=20; ROT=auto; KEEP=0
usage() { sed -n '4,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while getopts "e:g:n:r:kh" o; do
    case $o in
        e) EXP=$OPTARG ;; g) GAIN=$OPTARG ;; n) FRAMES=$OPTARG ;;
        r) ROT=$OPTARG ;; k) KEEP=1 ;; h) usage 0 ;; *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
DEFAULT='photo_{now}.png'; NOWTAG='{now}'
OUT=${1:-$DEFAULT}
OUT=${OUT//"$NOWTAG"/$(date +%Y%m%d-%H%M%S)}
case "$OUT" in *.png) ;; *) OUT=$OUT.png ;; esac
case "$ROT" in auto|0|90|180|270) ;; *) echo "rear-snap: -r must be auto, 0, 90, 180 or 270" >&2; exit 1 ;; esac
[ "$FRAMES" -ge 2 ] 2>/dev/null || { echo "rear-snap: -n must be 2 or more" >&2; exit 1; }

die() { echo "rear-snap: $*" >&2; exit 1; }

# --- safety checks ----------------------------------------------------------
LDO2=""
for n in /sys/class/regulator/*/name; do
    [ "$(cat "$n" 2>/dev/null)" = vdda_0v9 ] && LDO2=$(cat "${n%/name}/microvolts" 2>/dev/null)
done
[ "$LDO2" = 1200000 ] || die "RK817 LDO2 (vdda_0v9) is '${LDO2:-not found}' uV, not 1200000 - patch 0030 DTB not active; the sensor cannot stream"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] || die "camera capture block (fdfe0000) not found"
[ "$(cat "$VDEV/power/control")" = on ] || die "VICAP power/control is not 'on' - install 99-p25t-vicap.rules first (a second capture would freeze the tablet)"

R2P=""
for f in "$(dirname "$(readlink -f "$0")")/raw2png.py" /usr/local/lib/p25t/raw2png.py; do
    [ -f "$f" ] && { R2P=$f; break; }
done
[ -n "$R2P" ] || die "raw2png.py not found (next to this script or in /usr/local/lib/p25t/)"
command -v media-ctl >/dev/null && command -v v4l2-ctl >/dev/null || die "v4l-utils missing (sudo apt install v4l-utils)"
[ -w /dev/media0 ] || die "no access to /dev/media0 - run with sudo or join group video"

# --- rotation from the accelerometer (SC7A20, mount-matrix of patch 0026:
# device frame = landscape the usual way, x right, y up, z out of the screen)
auto_rotation() {
    local d found=""
    for d in /sys/bus/iio/devices/iio:device*; do
        case "$(cat "$d/name" 2>/dev/null)" in *sc7a20*|*accel*) found=$d ;; esac
    done
    [ -n "$found" ] || { echo "180 (no accelerometer found)"; return; }
    python3 - "$found" <<'PYEOF'
import sys
d = sys.argv[1]
rd = lambda f: open(d + "/" + f).read().strip()
mm = ""
for f in ("mount_matrix", "in_mount_matrix", "in_accel_mount_matrix"):
    try:
        mm = rd(f)
        break
    except OSError:
        pass
M = [[float(v) for v in r.split(",")] for r in mm.split(";")] if mm else [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
raw = [float(rd("in_accel_%s_raw" % a)) for a in "xyz"]
x, y, z = (sum(M[i][j] * raw[j] for j in range(3)) for i in range(3))
if abs(z) > max(abs(x), abs(y)):
    print("180 (lying flat)")
elif abs(y) >= abs(x):
    print("180 (landscape)" if y > 0 else "0 (landscape upside down)")
else:
    print("270 (portrait, landscape-left edge up)" if x < 0 else "90 (portrait, landscape-right edge up)")
PYEOF
}
if [ "$ROT" = auto ]; then
    POSE=$(auto_rotation 2>/dev/null) || POSE=""
    case "$POSE" in [0-9]*) ;; *) POSE="180 (accelerometer not readable)" ;; esac
    ROT=${POSE%% *}
else
    POSE="$ROT (by -r)"
fi

# --- pipeline ---------------------------------------------------------------
W=1296; H=972; FMT=SGRBG10_1X10; M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0") || die "video node not found"
SENS=$(media-ctl -d $M -e "gc5035 2-0037") || die "sensor subdev not found"
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || die "media-ctl format setup failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null || die "video format setup failed"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0 --set-ctrl=exposure="$EXP" --set-ctrl=analogue_gain="$GAIN" || die "sensor controls failed (exposure 4..1992, gain 256..4096)"

TMP=$(mktemp -d /tmp/rear-snap.XXXXXX) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
FR=$((W * H * 2))
timeout 20 v4l2-ctl -d "$VID" --stream-mmap --stream-count="$FRAMES" --stream-to="$TMP/all.raw" >/dev/null 2>&1
SZ=$(stat -c %s "$TMP/all.raw" 2>/dev/null || echo 0)
[ "$SZ" -ge "$FR" ] || die "capture failed ($SZ bytes)"
tail -c $FR "$TMP/all.raw" > "$TMP/last.raw"

python3 "$R2P" "$TMP/last.raw" $W $H --order RGGB --rotate "$ROT" --out "$OUT" >/dev/null || die "raw2png failed"
if [ $KEEP -eq 1 ]; then cp "$TMP/last.raw" "${OUT%.png}.raw"; fi
if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER": "$OUT" 2>/dev/null; [ $KEEP -eq 1 ] && chown "$SUDO_USER": "${OUT%.png}.raw"; fi
echo "$OUT (exposure $EXP, gain $GAIN, rotation $POSE)$([ $KEEP -eq 1 ] && echo "; raw: ${OUT%.png}.raw")"
