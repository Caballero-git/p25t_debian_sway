#!/bin/bash
# Check that every package in packages-*.txt exists in Debian trixie for
# arm64. Run on the tablet (it has Debian's package lists), from the
# folder that holds the lists:
#
#     bash check_packages.sh
#
# Read-only. Run "sudo apt update" first if the lists are old.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MISSING=0
AGE=$(( ( $(date +%s) - $(stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0) ) / 86400 ))
echo "apt lists are $AGE days old"
for f in "$HERE"/packages-*.txt; do
    n=0; bad=0
    while read -r p; do
        case "$p" in ""|"#"*) continue ;; esac
        n=$((n + 1))
        v=$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^  Candidate: //p')
        if [ -z "$v" ] || [ "$v" = "(none)" ]; then
            echo "MISSING  $p  ($(basename "$f"))"; bad=$((bad + 1))
        fi
    done < "$f"
    echo "$(basename "$f"): $n packages, $bad missing"
    MISSING=$((MISSING + bad))
done
[ "$MISSING" -eq 0 ] && echo "ALL PACKAGES FOUND" || echo "$MISSING missing - send me the MISSING lines"
