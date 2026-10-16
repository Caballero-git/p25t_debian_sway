#!/bin/bash
# manual_vs_lists.sh - does the build's package list cover a running card?
# Run on the tablet as the normal user (read-only), with a copy of the
# repo's debian/ folder:
#
#     bash manual_vs_lists.sh <DEBIAN-FOLDER> console|sway
#
# Prints two lists:
#   1. packages installed by hand on this card (apt-mark showmanual) that
#      are in none of packages-base/common/<profile>.txt - candidates to
#      add to the lists, so a rebuilt card has them too. Debian's own
#      required/important packages are left out (every build has them).
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

echo "## 1. installed by hand on $(hostname), in none of the lists"
comm -23 "$T/manual" "$T/lists" | comm -23 - "$T/debian-base" | sed 's/^/  /'
echo "## 2. in the lists ($P), not installed on $(hostname)"
comm -23 "$T/lists" "$T/all" | sed 's/^/  /'
echo "## done: $(wc -l < "$T/lists") packages listed, $(wc -l < "$T/manual") marked manual here"
