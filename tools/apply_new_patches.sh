#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Bring the kernel tree up to date with the repo's patch series: apply, with
# git am, the patches in kernel/patches that the tree does not have yet.
#
# Usage (PC):
#     bash ~/p25t-backup/p25t-sway/tools/apply_new_patches.sh          check only
#     bash ~/p25t-backup/p25t-sway/tools/apply_new_patches.sh apply    apply them
#
# Source: ~/p25t-backup/linux-sway, branch p25t-base, whose commits on top
# of the base are the series 0001, 0002, ... in order. The tree has N
# commits since the base; patches numbered N+1 and up are the new ones.
# Before applying, the subjects of the tree's N commits are compared with
# the subjects of patches 0001..N: a tree that does not match the series
# is left alone. git am stops on the first patch that does not apply
# (then: git -C ~/p25t-backup/linux-sway am --abort).
# Takes a few seconds.
set -euo pipefail

REPO="$HOME/p25t-backup/p25t-sway"
SRC="$HOME/p25t-backup/linux-sway"
BASE=f2c53ea949c5048f96b3dbb5a5ee7131ce4ff2de
PD="$REPO/kernel/patches"
MODE="${1:-check}"

die() { echo "STOPPED: $*"; exit 1; }
case "$MODE" in check|apply) ;; *) die "usage: $0 [apply]" ;; esac

[ "$(git -C "$SRC" rev-parse --abbrev-ref HEAD)" = "p25t-base" ] || die "$SRC is not on branch p25t-base"
[ -z "$(git -C "$SRC" status --porcelain)" ] || die "$SRC has local changes"
git -C "$SRC" merge-base --is-ancestor "$BASE" HEAD || die "$SRC does not contain the base $BASE"

N=$(git -C "$SRC" rev-list --count "$BASE..HEAD")
echo "tree: $N commits on top of the base"

# subject of a patch file (the Subject: header may be folded over two lines)
subject() {
    sed -n '/^Subject: /,/^$/p' "$1" | sed '$d' | tr -d '\n' |
        sed -e 's/^Subject: //' -e 's/^\[PATCH[^]]*\] //' -e 's/  */ /g'
}

MISMATCH=0
for i in $(seq 1 "$N"); do
    num=$(printf '%04d' "$i")
    f=$(ls "$PD"/"$num"-*.patch 2>/dev/null | head -1)
    [ -n "$f" ] || die "tree has commit $i but there is no patch $num"
    want=$(subject "$f")
    have=$(git -C "$SRC" log --format=%s -1 "HEAD~$((N - i))")
    if [ "$want" != "$have" ]; then
        echo "commit $i: tree '$have'"
        echo "     patch $num: '$want'"
        MISMATCH=1
    fi
done
[ "$MISMATCH" -eq 0 ] || die "the tree's commits do not match the series - nothing applied"
echo "commits 1-$N match patches 0001-$(printf '%04d' "$N")"

NEW=()
i=$((N + 1))
while f=$(ls "$PD"/"$(printf '%04d' "$i")"-*.patch 2>/dev/null | head -1) && [ -n "$f" ]; do
    NEW+=("$f"); i=$((i + 1))
done
if [ "${#NEW[@]}" -eq 0 ]; then
    echo "no new patches - the tree is up to date"
    exit 0
fi
echo "new patches:"
for f in "${NEW[@]}"; do echo "    $(basename "$f")"; done

if [ "$MODE" = check ]; then
    echo "check only - run again with 'apply' to apply them"
    exit 0
fi
git -C "$SRC" am "${NEW[@]}"
echo "applied; tree now:"
git -C "$SRC" log --oneline -"${#NEW[@]}"
echo "APPLY OK ($(git -C "$SRC" rev-list --count "$BASE..HEAD") commits on top of the base)"
