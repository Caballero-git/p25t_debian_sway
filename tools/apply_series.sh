#!/bin/bash
# Apply the common P25T patch series to the kernel clone and compare the
# result with the old bring-up branch.
#
# Usage (from anywhere):
#     bash ~/p25t-backup/p25t-sway/tools/apply_series.sh
#
# Works in ~/p25t-backup/linux-sway (never in ~/p25t-backup/linux).
# Expects branch p25t-base to sit at the base commit f2c53ea94 (it creates
# the branch if it does not exist yet). Stops if anything looks different.
set -euo pipefail

KERNEL="$HOME/p25t-backup/linux-sway"
PATCHES="$HOME/p25t-backup/p25t-sway/kernel/patches"
BASE=f2c53ea949c5048f96b3dbb5a5ee7131ce4ff2de
OLD=origin/p25t-bringup

cd "$KERNEL"
echo "kernel tree: $(pwd)"

# a git am left half-done by an earlier try
if [ -d .git/rebase-apply ]; then
    echo "an unfinished 'git am' was found - aborting it"
    git am --abort
fi

if git rev-parse --verify -q p25t-base > /dev/null; then
    git checkout -q p25t-base
else
    git checkout -q -b p25t-base "$BASE"
fi

HEAD_NOW=$(git rev-parse HEAD)
if [ "$HEAD_NOW" != "$BASE" ]; then
    echo "STOPPED: branch p25t-base is at $HEAD_NOW, not at the base $BASE"
    echo "(already applied? see: git log --oneline -3)"
    exit 1
fi
[ -z "$(git status --porcelain)" ] || { echo "STOPPED: the working tree has changes"; exit 1; }

N=$(ls "$PATCHES"/*.patch | wc -l)
echo "applying $N patches from $PATCHES"
git am -q "$PATCHES"/*.patch
echo "applied: $(git rev-list --count "$BASE"..HEAD) commits on p25t-base"

echo
echo "difference to the old bring-up branch ($OLD):"
git diff --stat "$OLD" p25t-base
echo
echo "expected: drivers/gpu/drm/panel/panel-jadard-jd9365da-h3.c | 12 +++++-------"
echo "          1 file changed, 5 insertions(+), 7 deletions(-)"
