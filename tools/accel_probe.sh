#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# accel_probe.sh - what the accelerometer and iio-sensor-proxy see, for one
# tablet position. Run on the tablet, with the tablet still:
#
#     sudo bash accel_probe.sh <POSITION>
#
# <POSITION> is a free label, e.g. L0 (landscape as the console reads),
# P90 (turned 90 degrees clockwise), L180 (upside down), P270.
# Appends to accel-probe.txt in the current folder. Read-only: it changes
# nothing on the tablet.
set -u
POS=${1:?usage: sudo bash accel_probe.sh POSITION}
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
OUT="$PWD/accel-probe.txt"

{
echo "=================== position $POS   $(date '+%F %T')"

# the IIO device that has accelerometer channels
DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ -e "$d/in_accel_x_raw" ] && { DEV=$d; break; }
done
if [ -z "$DEV" ]; then
    echo "no IIO device with in_accel_x_raw"
else
    echo "## device $DEV  name: $(cat "$DEV/name")"
    for f in in_accel_mount_matrix mount_matrix in_mount_matrix in_accel_scale; do
        [ -e "$DEV/$f" ] && echo "$f: $(cat "$DEV/$f")"
    done
    echo "## raw x y z, 3 readings"
    for i in 1 2 3; do
        echo "$(cat "$DEV/in_accel_x_raw") $(cat "$DEV/in_accel_y_raw") $(cat "$DEV/in_accel_z_raw")"
        sleep 0.3
    done
    echo "## udev properties (mount matrix from hwdb would show here)"
    udevadm info -q property -p "$DEV" | grep -i -E 'accel|mount|iio|sensor' || echo "(none)"
fi

echo "## iio-sensor-proxy"
dpkg-query -W iio-sensor-proxy
echo "## monitor-sensor, 2 runs of 4 s (first line may be the previous position)"
for i in 1 2; do
    timeout 4 monitor-sensor 2>&1 | grep -E 'orientation|Accelerometer' || echo "(no orientation lines)"
done
} >> "$OUT" 2>&1

# Only the first time: sessions and the daemon's log
if ! grep -q '^## sessions' "$OUT"; then
    {
    echo "## sessions"
    loginctl list-sessions --no-pager
    for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
        loginctl show-session "$s" -p Id -p Name -p TTY -p Seat -p Type -p Class -p Remote -p Active -p State
        echo
    done
    echo "## iio-sensor-proxy journal (this boot, last 30 lines)"
    journalctl -b -u iio-sensor-proxy --no-pager | tail -30
    } >> "$OUT" 2>&1
fi

[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:" "$OUT"
echo "position $POS done -> $OUT"
