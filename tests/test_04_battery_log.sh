#!/bin/bash
# battery_log.sh - log what the RK817 fuel gauge reports, to see how its
# capacity estimate behaves (2026-10-15: 27% before a reboot with the
# charger in, 72-78% right after it). Read-only: it only reads
# /sys/class/power_supply. Run on the tablet as the normal user:
#
#     nohup bash battery_log.sh <SECONDS> > /dev/null 2>&1 &
#
# Appends one CSV line every <SECONDS> (default 60) to ~/battery-log.csv,
# also across reboots if started again. Stop it with: pkill -f battery_log.sh
#
# The mainline rk817 driver has no voltage_now/current_now: it reports
# averages (voltage_avg, current_avg). ocv_pct is the % that the battery
# voltage gives on the stock OCV table (the one in our DT) - only
# meaningful when the current is small (tablet idle, charger out), but
# then a good check of capacity_pct.
set -u
EVERY=${1:-60}
OUT="$HOME/battery-log.csv"

BAT="" CHG=""
for p in "${PS_DIR:-/sys/class/power_supply}"/*; do
    case "$(cat "$p/type" 2>/dev/null)" in
        Battery)   BAT=$p ;;
        USB|Mains) CHG=$p ;;
    esac
done
[ -n "$BAT" ] || { echo "no battery in /sys/class/power_supply" >&2; exit 1; }

rd() { cat "$1" 2>/dev/null || echo ""; }   # empty if the file is missing

# stock OCV table (mV, %), as in the DT battery node
ocv_pct() {
    awk -v v="$1" 'BEGIN {
        n = split("4313 4257 4199 4144 4093 4035 3992 3955 3915 3866 3834 3804 3788 3776 3765 3745 3724 3677 3608 3543 3400", mv, " ")
        split("100 95 90 85 80 75 70 65 60 55 50 45 40 35 30 25 20 15 10 5 0", pc, " ")
        if (v >= mv[1]) { print 100; exit }
        if (v <= mv[n]) { print 0; exit }
        for (i = 1; i < n; i++)
            if (v <= mv[i] && v >= mv[i+1]) {
                printf "%.0f\n", pc[i+1] + (pc[i] - pc[i+1]) * (v - mv[i+1]) / (mv[i] - mv[i+1]); exit
            }
    }'
}

[ -s "$OUT" ] || echo "time,uptime_s,status,capacity_pct,ocv_pct,bat_mV,bat_mA,charge_now_mAh,charge_full_mAh,charge_full_design_mAh,charger_online,charger_mV" > "$OUT"

while :; do
    v=$(rd "$BAT/voltage_avg");  c=$(rd "$BAT/current_avg")
    cn=$(rd "$BAT/charge_now");  cf=$(rd "$BAT/charge_full"); cfd=$(rd "$BAT/charge_full_design")
    on="" cv=""
    if [ -n "$CHG" ]; then on=$(rd "$CHG/online"); cv=$(rd "$CHG/voltage_avg"); fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%F %T')" "$(cut -d' ' -f1 /proc/uptime)" \
        "$(rd "$BAT/status")" "$(rd "$BAT/capacity")" \
        "${v:+$(ocv_pct $((v / 1000)))}" \
        "${v:+$((v / 1000))}" "${c:+$((c / 1000))}" \
        "${cn:+$((cn / 1000))}" "${cf:+$((cf / 1000))}" "${cfd:+$((cfd / 1000))}" \
        "$on" "${cv:+$((cv / 1000))}" >> "$OUT"
    sleep "$EVERY"
done
