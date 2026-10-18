#!/bin/bash
# sway_check.sh - what a running sway sees on the P25T (plan stage 4).
# Run over ssh as the normal user (no sudo) while sway runs on tty1:
#
#     bash sway_check.sh <LABEL>
#
# Appends to sway-check.txt in the current folder. Read-only: it only
# asks sway and the system, it changes nothing. Reads the sway log
# ~/sway-first.log if it exists.
set -u
LABEL=${1:?usage: bash sway_check.sh LABEL}
OUT="$PWD/sway-check.txt"
LOG="$HOME/sway-first.log"

{
echo "=================== $LABEL   $(date '+%F %T')"
echo "kernel: $(uname -r) $(uname -v)"

echo "## /dev/dri"
ls -l /dev/dri /dev/dri/by-path 2>&1

echo "## sessions (sway needs one on seat0, tty1, Remote=no, Active=yes)"
loginctl list-sessions --no-pager
for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    loginctl show-session "$s" -p Id -p TTY -p VTNr -p Seat -p Type -p Class -p Remote -p Active
    echo
done

echo "## sway processes"
pgrep -a -x sway || echo "(sway not running)"

SOCK=""
for f in /run/user/"$(id -u)"/sway-ipc.*.sock; do
    [ -S "$f" ] && SOCK=$f
done
if [ -n "$SOCK" ]; then
    export SWAYSOCK=$SOCK
    echo "## swaymsg (socket $SOCK)"
    swaymsg -t get_version
    echo "## outputs"
    swaymsg -t get_outputs
    echo "## inputs"
    swaymsg -t get_inputs
else
    echo "## no sway IPC socket in /run/user/$(id -u)"
fi

if [ -f "$LOG" ]; then
    echo "## $LOG: $(wc -l < "$LOG") lines; renderer, GPU, DRM and error lines"
    grep -i -E 'renderer|gles|egl|panfrost|rockchip|drm|connector|mode|transform|orientation|error|fail|unable|cannot' "$LOG" | head -120
else
    echo "## no $LOG"
fi

echo "## memory"
free -m
echo "## temperatures"
for z in /sys/class/thermal/thermal_zone*; do
    echo "$(cat "$z/type") $(( $(cat "$z/temp") / 1000 )) C"
done
echo "## backlight"
cat /sys/class/backlight/backlight/brightness
} >> "$OUT" 2>&1

echo "$LABEL done -> $OUT"
