#!/bin/bash
# Bring a card built before 2026-10-14 in line with the corrected build
# (debian/packages-common.txt and debian/p25t-setup.sh of that date):
#   1. packages card 1 has and the first sway build missed:
#      emacs-common-non-dfsg (Emacs manuals), util-linux-extra, unzip,
#      manpages, python3-dev
#   2. wlan0: [DHCPv4] UseHostname=no - stops "Could not set hostname:
#      Access denied" (networkd asking hostnamed without polkitd)
#   3. console: CODESET="Lat15" as on card 1 (was "guess" = Uni2)
# Run on the tablet:   sudo bash card_fix_2026-10-14.sh
# Idempotent. 2 and 3 take effect at the next boot.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "=== 1. packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    emacs-common-non-dfsg util-linux-extra unzip manpages python3-dev
for p in emacs-common-non-dfsg util-linux-extra unzip manpages python3-dev; do
    dpkg-query -W -f='${Status} ${Package}\n' "$p" | grep -q '^install ok installed' || { echo "STOP: $p not installed"; exit 1; }
done
echo "packages installed"

echo "=== 2. wlan0: UseHostname=no"
W=/etc/systemd/network/60-wlan.network
if grep -q '^UseHostname=no' "$W"; then
    echo "already set"
else
    grep -q '^\[DHCPv4\]' "$W" || { echo "STOP: no [DHCPv4] section in $W"; exit 1; }
    cp -p "$W" "$W.pre-2026-10-14"
    sed -i 's/^\[DHCPv4\]$/[DHCPv4]\n# keep our hostname: without polkitd, networkd'"'"'s attempt to take a name\n# from the router only logs "Could not set hostname: Access denied"\nUseHostname=no/' "$W"
    grep -q '^UseHostname=no' "$W" || { echo "STOP: edit failed"; exit 1; }
    echo "set (copy of the old file: $W.pre-2026-10-14)"
fi
cat "$W"

echo "=== 3. console CODESET Lat15"
C=/etc/default/console-setup
sed -i 's/^CODESET=.*/CODESET="Lat15"/' "$C"
grep '^CODESET=' "$C"

echo "=== done - reboot when convenient (sudo reboot)"
