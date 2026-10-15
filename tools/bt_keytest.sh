#!/bin/bash
# bt_keytest.sh - is the Bluetooth keyboard's trouble the keyboard, the
# radio shared with Wi-Fi (AIC8800, 2.4 GHz), or something else?
# Records every key press/release for 45 s while you type, with Wi-Fi on
# or off, plus the Bluetooth state and logs. Run on the tablet:
#
#     sudo bash bt_keytest.sh <LABEL> [wifi-off]
#
# While it records, type on the Bluetooth keyboard, slowly and evenly,
# the alphabet three times:  abcdefghijklmnopqrstuvwxyz (no Enter needed).
# With "wifi-off", wlan0 is down during the 45 s and back up afterwards
# (an ssh over Wi-Fi freezes meanwhile and normally recovers; use ssh over
# the USB cable to be safe). Output: bt-keys-<LABEL>.txt in this folder.
# Changes nothing else; Wi-Fi is brought back up even on Ctrl+C.
set -u
LABEL=${1:?usage: sudo bash bt_keytest.sh LABEL [wifi-off]}
MODE=${2:-wifi-on}
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
OUT="$PWD/bt-keys-$LABEL.txt"
RAW=$(mktemp)
SECS=45

{
echo "=================== $LABEL ($MODE)   $(date '+%F %T')   $(uname -r)"
echo "## Wi-Fi"
/usr/sbin/iw dev wlan0 link | grep -E 'SSID|freq|signal' || echo "(not connected)"
echo "## Bluetooth services"
systemctl is-active bluetooth p25t-bluetooth
pgrep -a btattach
echo "## controller"
bluetoothctl show | grep -E 'Controller|Powered|Discoverable|Pairable'
echo "## paired / connected devices"
for m in $(bluetoothctl devices Paired | awk '{print $2}'); do
    bluetoothctl info "$m" | grep -E 'Device|Name|Icon|Paired|Bonded|Trusted|Connected|RSSI|LegacyPairing'
done
echo "## input devices"
libinput list-devices 2>/dev/null | grep -E '^Device|^Kernel'
} >> "$OUT" 2>&1

restore() { [ "$MODE" = wifi-off ] && ip link set wlan0 up; }
trap 'restore; rm -f "$RAW"' EXIT

if [ "$MODE" = wifi-off ]; then
    ip link set wlan0 down
    echo "Wi-Fi is down for $SECS s."
fi
echo "Recording $SECS s: type the alphabet three times on the Bluetooth keyboard now."
timeout "$SECS" libinput debug-events --show-keycodes > "$RAW" 2>&1
restore
trap 'rm -f "$RAW"' EXIT
[ "$MODE" = wifi-off ] && sleep 8   # give Wi-Fi time to reconnect

{
echo "## key events per device (node: presses / releases / pressed-but-never-released)"
awk '/KEYBOARD_KEY/ {
        dev=$1; sub(/^-/, "", dev); k=""; for (i=1;i<=NF;i++) if ($i ~ /^KEY_/) k=$i
        if ($NF=="pressed")  { p[dev]++; down[dev SUBSEP k]=1; seq[dev]=seq[dev] substr(k,5) " " }
        if ($NF=="released") { r[dev]++; delete down[dev SUBSEP k] }
     }
     END {
        for (d in p) {
            stuck=""; for (x in down) { split(x, a, SUBSEP); if (a[1]==d) stuck=stuck a[2] " " }
            printf "%s: %d / %d / %s\n", d, p[d], r[d], (stuck=="" ? "none" : stuck)
            printf "  typed: %s\n", seq[d]
        }
     }' "$RAW"
echo "## kernel messages (Bluetooth, UART, HID) during this boot, last 40"
dmesg | grep -i -E 'bluetooth|hci|btattach|ttyS1|uart|hid' | tail -40
echo "## bluetooth journal, last 30"
journalctl -b -u bluetooth -u p25t-bluetooth --no-pager | tail -30
echo "## raw events"
cat "$RAW"
} >> "$OUT" 2>&1
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER:" "$OUT"
echo "done -> $OUT"
