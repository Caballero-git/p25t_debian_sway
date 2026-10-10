#!/bin/bash
# Health snapshot of the running P25T system, for before/after comparisons
# (e.g. a kernel change). Run on the tablet:
#
#     sudo bash health_snapshot.sh <LABEL>        e.g. before, after
#
# Writes /home/jose/health/<LABEL>/ with one text file per topic. Files
# 0x-4x are written so that two snapshots can be compared line by line
# (no timestamps); 5x holds values that always change (temperatures,
# battery, boot times) and is shown, not compared. Compare with:
#
#     bash health_compare.sh <LABEL-A> <LABEL-B>
#
# Read-only: it changes nothing on the system.
set -u
LABEL=${1:-}
[ -n "$LABEL" ] || { echo "usage: sudo bash health_snapshot.sh <LABEL>"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (dmesg and debugfs need root)"; exit 1; }
D=/home/jose/health/$LABEL
[ -e "$D" ] && { echo "STOPPED: $D exists already - pick another label"; exit 1; }
mkdir -p "$D"
REL=$(uname -r)

# 00 kernel
{ echo "release: $REL"; echo "version: $(uname -v)"; echo "cmdline: $(cat /proc/cmdline)"; } > "$D/00-kernel.txt"

# 10-12 kernel log: warnings and errors, full log, without timestamps
dmesg -t --level=emerg,alert,crit,err,warn > "$D/10-dmesg-warn-err.txt" 2>&1
dmesg -t > "$D/11-dmesg-full.txt" 2>&1
dmesg -t | grep -i -E 'fail|error|timeout|timed out|defer|not found|unable|cannot|invalid|-[0-9]+\)?$' > "$D/12-dmesg-keywords.txt"

# 20-21 systemd
journalctl -b -p warning -o cat --no-pager > "$D/20-journal-warn.txt" 2>&1
systemctl --failed --no-legend --plain > "$D/21-failed-units.txt" 2>&1

# 30 modules loaded (names only)
lsmod | tail -n +2 | awk '{print $1}' | sort > "$D/30-modules-loaded.txt"

# 31 drivers bound to devices: "bus driver device"
for drv in /sys/bus/*/drivers/*; do
    bus=$(basename "$(dirname "$(dirname "$drv")")")
    for dev in "$drv"/*; do
        [ -L "$dev" ] || continue
        n=$(basename "$dev"); [ "$n" = module ] && continue
        echo "$bus $(basename "$drv") $n"
    done
done | sort > "$D/31-drivers-bound.txt"

# 32 devices still waiting for a driver (deferred probe)
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ -r /sys/kernel/debug/devices_deferred ]; then
    sort /sys/kernel/debug/devices_deferred > "$D/32-devices-deferred.txt"
else
    echo "(debugfs not available)" > "$D/32-devices-deferred.txt"
fi

# 33 regulators: name, state, voltage (RK817 rails matter on this board)
for r in /sys/class/regulator/regulator.*; do
    printf '%s %s %s\n' "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null || echo -)" "$(cat "$r/microvolts" 2>/dev/null || echo -)"
done | sort > "$D/33-regulators.txt"

# 40 devices that the tools rely on
{
    echo "## /dev/dri";        ls /dev/dri 2>&1
    echo "## video/media";     ls /dev | grep -E '^(video|media|v4l-subdev)' 2>&1
    echo "## input devices";   grep '^N: ' /proc/bus/input/devices | sed 's/^N: Name=//'
    echo "## iio";             for i in /sys/bus/iio/devices/iio:device*; do [ -e "$i/name" ] && echo "$(basename "$i") $(cat "$i/name") mount_matrix: $(cat "$i/in_mount_matrix" 2>/dev/null || cat "$i/mount_matrix" 2>/dev/null)"; done
    echo "## backlight";       for b in /sys/class/backlight/*; do echo "$(basename "$b") max $(cat "$b/max_brightness")"; done
    echo "## power supplies";  for p in /sys/class/power_supply/*; do echo "$(basename "$p") type $(cat "$p/type" 2>/dev/null)"; done
    echo "## thermal zones";   for t in /sys/class/thermal/thermal_zone*; do echo "$(basename "$t") $(cat "$t/type")"; done
    echo "## cpufreq";         cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>&1
    echo "## devfreq";         for f in /sys/class/devfreq/*; do echo "$(basename "$f") $(cat "$f/governor") $(cat "$f/available_frequencies")"; done
    echo "## sound cards";     cat /proc/asound/cards 2>&1
    echo "## network links";   ip -br link | awk '{print $1, $2}'
    echo "## rfkill";          for k in /sys/class/rfkill/rfkill*; do echo "$(cat "$k/name") $(cat "$k/type") soft=$(cat "$k/soft") hard=$(cat "$k/hard")"; done
    echo "## bluetooth";       ls /sys/class/bluetooth 2>&1
    echo "## leds";            ls /sys/class/leds 2>&1
    echo "## usb role";        for u in /sys/class/usb_role/*; do echo "$(basename "$u") $(cat "$u/role" 2>/dev/null)"; done; ls /sys/class/udc 2>&1
    echo "## media topology";  for m in /dev/media*; do media-ctl -d "$m" -p 2>/dev/null | grep -E '^- entity|^\s+(pad|<-|->)' ; done
} > "$D/40-devices.txt" 2>&1

# 41 files the kernel loads from the root fs (names + sha256)
{
    echo "## /usr/lib/modules/$REL"
    ( cd "/usr/lib/modules/$REL" 2>/dev/null && find . -name '*.ko*' | sort | xargs -r sha256sum )
    echo "## /usr/lib/firmware/aic8800_fw"
    ( cd /usr/lib/firmware/aic8800_fw 2>/dev/null && find . -type f | sort | xargs -r sha256sum )
} > "$D/41-module-files.txt" 2>&1

# 50 values that always change: shown, not compared
{
    echo "uptime: $(cut -d' ' -f1 /proc/uptime) s"
    systemd-analyze 2>&1 | head -1
    echo "## slowest units"; systemd-analyze blame 2>/dev/null | head -8
    echo "## temperatures";  for t in /sys/class/thermal/thermal_zone*; do [ -r "$t/temp" ] || continue; echo "$(cat "$t/type") $(( $(cat "$t/temp") / 1000 )) C"; done
    echo "## battery";       for p in /sys/class/power_supply/*; do [ -e "$p/capacity" ] && echo "$(basename "$p") $(cat "$p/capacity")% $(cat "$p/status")"; done
    echo "## cpu freq now";  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
    echo "## memory";        free -m | head -2
} > "$D/50-values.txt" 2>&1

chown -R jose:jose /home/jose/health
echo "snapshot '$LABEL' of $REL ($(uname -v)) in $D:"
wc -l "$D"/*.txt | sed 's|/home/jose/health/||'
echo "warnings/errors in dmesg: $(wc -l < "$D/10-dmesg-warn-err.txt"), journal warnings: $(wc -l < "$D/20-journal-warn.txt"), failed units: $(wc -l < "$D/21-failed-units.txt"), deferred: $(wc -l < "$D/32-devices-deferred.txt")"
