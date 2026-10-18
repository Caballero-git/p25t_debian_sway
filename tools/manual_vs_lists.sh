#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# manual_vs_lists.sh - does the build's package list cover a running card?
# Run on the tablet as the normal user (read-only), with a copy of the
# repo's debian/ folder:
#
#     bash manual_vs_lists.sh <DEBIAN-FOLDER> console|sway
#
# Prints two lists:
#   1. packages installed by hand on this card (apt-mark showmanual) that
#      are in none of packages-base/common/<profile>.txt, split in two:
#      1a  nothing installed depends on them - candidates to add to the
#          lists, so a rebuilt card has them too;
#      1b  other installed packages depend on them (libraries the build
#          marks "manual", like libc6) - they come back by themselves.
#      Debian's own required/important packages are left out.
#   2. packages in the lists that this card does not have - would be new
#      on a rebuilt card (fine if added on purpose).
set -u
D=${1:?usage: bash manual_vs_lists.sh DEBIAN-FOLDER console|sway}
P=${2:?usage: bash manual_vs_lists.sh DEBIAN-FOLDER console|sway}
LISTS=("$D/packages-base.txt" "$D/packages-common.txt" "$D/packages-$P.txt")
for f in "${LISTS[@]}"; do
    [ -f "$f" ] || { echo "ABORT: $f missing"; exit 1; }
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

grep -h -v -E '^\s*(#|$)' "${LISTS[@]}" | tr -d ' \t' | sort -u > "$T/lists"
apt-mark showmanual | sed 's/:.*//' | sort -u > "$T/manual"
dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Priority}\n' \
    | awk -F'|' '$1 ~ /^ii/ {print $2, $3}' > "$T/installed"
awk '$2 == "required" || $2 == "important" {print $1}' "$T/installed" | sort -u > "$T/debian-base"
awk '{print $1}' "$T/installed" | sort -u > "$T/all"

comm -23 "$T/manual" "$T/lists" | comm -23 - "$T/debian-base" > "$T/extra"
: > "$T/leaves"; : > "$T/needed"
while read -r p; do
    n=$(apt-cache rdepends --installed --no-suggests --no-recommends --no-enhances \
            --no-conflicts --no-breaks --no-replaces "$p" 2>/dev/null \
        | sed '1,/^Reverse Depends:/d' | grep -c .)
    if [ "$n" -eq 0 ]; then echo "$p" >> "$T/leaves"; else echo "$p" >> "$T/needed"; fi
done < "$T/extra"
echo "## 1a. installed by hand on $(hostname), in none of the lists, nothing depends on them"
sed 's/^/  /' "$T/leaves"
echo "## 1b. the same, but other installed packages need them (come back by themselves)"
echo "  $(wc -l < "$T/needed") packages: $(paste -sd' ' "$T/needed")"
echo "## 2. in the lists ($P), not installed on $(hostname)"
comm -23 "$T/lists" "$T/all" | sed 's/^/  /'
echo "## done: $(wc -l < "$T/lists") packages listed, $(wc -l < "$T/manual") marked manual here"
