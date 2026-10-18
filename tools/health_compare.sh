#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Compare two health snapshots made by health_snapshot.sh. Run on the tablet:
#
#     bash health_compare.sh <LABEL-A> <LABEL-B>      e.g. before after
#
# For each comparable file (00-41) it prints "same" or the differences
# (lines only in A start with "-", only in B with "+"). The kernel log
# files are compared as sorted line sets, so a different probe order is
# not reported. 50-values.txt is printed side by side, not compared.
set -u
A=/home/jose/health/${1:-}
B=/home/jose/health/${2:-}
[ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: bash health_compare.sh <LABEL-A> <LABEL-B>"; exit 1; }
[ -d "$A" ] && [ -d "$B" ] || { echo "STOPPED: $A or $B not found"; exit 1; }
CHANGED=0
for f in "$A"/[0-4]*.txt; do
    n=$(basename "$f")
    [ -f "$B/$n" ] || { echo "### $n: missing in $(basename "$B")"; CHANGED=1; continue; }
    case "$n" in
        1*-dmesg*|20-*) d=$(diff <(sort "$f") <(sort "$B/$n") | grep -E '^[<>]' | sed 's/^</-/; s/^>/+/') ;;
        *)              d=$(diff "$f" "$B/$n" | grep -E '^[<>]' | sed 's/^</-/; s/^>/+/') ;;
    esac
    if [ -z "$d" ]; then
        echo "### $n: same"
    else
        echo "### $n: $(echo "$d" | wc -l) lines differ"; echo "$d" | sed 's/^/    /'; CHANGED=1
    fi
done
echo; echo "### 50-values.txt (not compared)"
paste -d'|' "$A/50-values.txt" "$B/50-values.txt" | sed 's/|/   ||   /'
echo
[ "$CHANGED" -eq 0 ] && echo "RESULT: no differences in 00-41" || echo "RESULT: differences above - read each one"
