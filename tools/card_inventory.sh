#!/bin/bash
# Inventory of a running P25T card: what was added or changed after the
# first Debian build (packages installed by hand, /etc files changed or
# added, local scripts, enabled services, udev rules, sound state, user
# groups). Read-only: it changes nothing on the system.
#
#     sudo bash card_inventory.sh
#
# Output: /home/jose/inventory/   (text files + copies of the changed files)
#         /home/jose/card-inventory.tar  (the same, for copying to the PC)
# The tar contains the Wi-Fi configuration (network name and the password
# hash): keep it out of git (the p25t-sway build/ folder is ignored).
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
D=/home/jose/inventory
[ -e "$D" ] && { echo "STOPPED: $D exists already - move it away first"; exit 1; }
mkdir -p "$D/files"
T=$(mktemp -d)

# 00 system
{
    echo "kernel: $(uname -r) $(uname -v)"
    echo "debian: $(cat /etc/debian_version)"
    echo "hostname: $(cat /etc/hostname)"
    echo "timezone: $(cat /etc/timezone 2>/dev/null) / $(readlink /etc/localtime)"
    echo "locale: $(cat /etc/default/locale 2>/dev/null | tr '\n' ' ')"
    echo "user: $(id jose)"
    echo "root fs: $(df -h / | awk 'NR == 2 {print $2 " total, " $3 " used"}')"
} > "$D/00-system.txt"

# 10-12 packages
apt-mark showmanual | sort > "$D/10-packages-manual.txt"
dpkg-query -W -f='${Package} ${Version}\n' | sort > "$D/11-packages-all.txt"
apt-mark showauto | sort > "$D/12-packages-auto.txt"

# 20 configuration files changed from the package version: compare each
# conffile with the md5 dpkg recorded for it (only conffiles, so it is quick)
dpkg-query -W -f='${Conffiles}\n' 2>/dev/null | awk 'NF >= 2 && $2 != "newconffile" {print $2 "  " $1}' \
    | while read -r sum file; do
          [ -f "$file" ] || continue
          [ "$(md5sum < "$file" | cut -d' ' -f1)" = "$sum" ] || echo "$file"
      done | sort -u > "$D/20-conffiles-changed.txt"

# 27 package files in /etc that are not conffiles but were edited
# (e.g. /etc/default/consolation by p25t-consolation.sh): dpkg's md5sums
( cd / && cat /var/lib/dpkg/info/*.md5sums 2>/dev/null | awk '$2 ~ /^etc\// {print}' \
      | md5sum -c --quiet 2>/dev/null | sed -n 's/: FAILED.*$//p' | sed 's|^|/|' ) | sort -u > "$D/27-package-files-changed.txt"

# 21 files in /etc, /usr/local, /var/lib/alsa that no package owns
cat /var/lib/dpkg/info/*.list | sort -u > "$T/owned"
find /etc /usr/local /var/lib/alsa -xdev \( -type f -o -type l \) 2>/dev/null | sort > "$T/present"
comm -13 "$T/owned" "$T/present" \
    | grep -v -E '^/etc/(ssh/ssh_host_|machine-id|ld\.so\.cache|adjtime|shadow-|gshadow-|passwd-|group-|subuid-|subgid-|\.pwd\.lock|resolv\.conf|mtab|alternatives/|ssl/certs/)' \
    > "$D/21-files-not-from-packages.txt"

# 22 services and timers enabled, units written by hand
systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort > "$D/22-units-enabled.txt"
systemctl list-unit-files --state=masked --no-legend --no-pager | awk '{print $1}' | sort > "$D/23-units-masked.txt"

# 24 udev rules, modules-load, kernel command line extras
{
    echo "## /etc/udev/rules.d"; ls -1 /etc/udev/rules.d 2>/dev/null
    echo "## /etc/modules-load.d"; for f in /etc/modules-load.d/*; do [ -f "$f" ] && { echo "# $f"; grep -v '^\s*#' "$f" | grep -v '^\s*$'; }; done
    echo "## /etc/modprobe.d"; ls -1 /etc/modprobe.d 2>/dev/null
} > "$D/24-udev-modules.txt"

# 25 home folder of jose: names only (contents stay on the card), crontabs
{
    echo "## /home/jose (top level, without inventory/health)"; ls -1A /home/jose | grep -v -E '^(inventory|health|card-inventory\.tar)$'
    echo "## ~/.ssh"; ls -1 /home/jose/.ssh 2>/dev/null
    echo "## crontab jose"; crontab -u jose -l 2>/dev/null
    echo "## crontab root"; crontab -l 2>/dev/null
} > "$D/25-home-and-cron.txt"

# copies: every changed conffile or package file and every file no package owns
# (at most 2000 files; a tablet card has far fewer - more means something unexpected)
N=0
{ cat "$D/20-conffiles-changed.txt"; cat "$D/27-package-files-changed.txt"; cat "$D/21-files-not-from-packages.txt"; } | sort -u | while read -r f; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    N=$((N + 1))
    [ "$N" -le 2000 ] || { echo "$f (not copied, over 2000 files)" >> "$D/26-skipped-large.txt"; continue; }
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$sz" -le 1048576 ] || { echo "$f (skipped, $sz bytes)" >> "$D/26-skipped-large.txt"; continue; }
    mkdir -p "$D/files$(dirname "$f")"
    cp -a "$f" "$D/files$f"
done
cp -a /home/jose/.ssh/authorized_keys "$D/files/authorized_keys" 2>/dev/null

rm -rf "$T"
chown -R jose:jose "$D"
tar -C /home/jose -cf /home/jose/card-inventory.tar inventory
chown jose:jose /home/jose/card-inventory.tar
echo "inventory in $D, tar /home/jose/card-inventory.tar ($(du -h /home/jose/card-inventory.tar | cut -f1))"
wc -l "$D"/*.txt | sed 's|/home/jose/inventory/||'
echo "copied files: $(find "$D/files" -type f | wc -l)"
