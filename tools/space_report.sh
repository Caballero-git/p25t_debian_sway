#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# space_report.sh - where the PC's disk space goes. READ-ONLY.
#
# Usage:
#     bash ~/p25t-backup/p25t-sway/tools/space_report.sh > ~/space_report.txt
#
# Shows free space, the size of every folder in ~ and in ~/p25t-backup,
# the biggest files in ~/p25t-backup, and how much of each kernel tree is
# build output (removable with 'make clean' / 'git clean', rebuilt on
# demand). Takes a minute or two on a big home (du walks everything).
# Nothing is deleted or moved: the clean-up is decided afterwards.
set -u
B="$HOME/p25t-backup"

echo "=== space report $(date '+%F %T') on $(hostname)"
echo
echo "--- free space"
df -h / "$HOME" | awk 'NR == 1 || !seen[$0]++'

echo
echo "--- folders in $HOME (biggest first)"
du -sh "$HOME"/* "$HOME"/.[!.]* 2>/dev/null | sort -rh | head -25

echo
echo "--- folders and files in $B (biggest first)"
du -sh "$B"/* 2>/dev/null | sort -rh

echo
echo "--- files over 100 MB in $B"
find "$B" -xdev -type f -size +100M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null | sort -rn |
    awk -F'\t' '{ printf "%8.0f MB  %s  %s\n", $1 / 1048576, $2, $3 }' | head -30

echo
echo "--- kernel trees: sources (git) vs build output"
for t in "$B"/linux "$B"/linux-sway; do
    [ -d "$t/.git" ] || continue
    ALL=$(du -sh "$t" 2>/dev/null | cut -f1)
    GIT=$(du -sh "$t/.git" 2>/dev/null | cut -f1)
    OBJ=$(find "$t" -xdev \( -name '*.o' -o -name '*.ko' -o -name '*.cmd' -o -name '*.a' \) -type f -printf '%s\n' 2>/dev/null |
          awk '{ s += $1 } END { printf "%.1fG", s / 1073741824 }')
    echo "$t: total $ALL, of which .git $GIT, object files ~$OBJ"
done
for o in "$B"/p25t-sway/build/*; do
    [ -d "$o" ] && echo "$o: $(du -sh "$o" 2>/dev/null | cut -f1) (out-of-tree build output)"
done
echo
echo "=== done (nothing changed)"
