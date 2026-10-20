#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_initramfs.sh - build the P25T stage-1 system (initramfs.cpio.gz): a
# static arm64 busybox and initramfs/init, nothing else.
#
# Usage (PC, normal user):
#     bash ~/p25t-backup/p25t-sway/tools/build_initramfs.sh
#         download busybox (first run only), build, pack
#     bash ~/p25t-backup/p25t-sway/tools/build_initramfs.sh compare
#         the same, then compare with the initramfs the cards carry
#         (~/p25t-backup/debian/initramfs.cpio.gz, sha256 af94fcee...)
#
# Source, pinned: busybox 1.37.0, the release tarball (sha256 3311dff3...),
# from busybox.net or, if that fails, the identical Debian/Ubuntu "orig"
# tarball. Kept in build/src/.
# Busybox configuration: defconfig, plus three changes - the same as the
# busybox on the cards (checked 2026-10-19: same 402 commands, same code):
#   CONFIG_STATIC=y                      no shared libraries in the initramfs
#   CONFIG_SHA1_HWACCEL, SHA256_HWACCEL  off: x86-only code that breaks
#                                        a cross build in 1.37.0
#   CONFIG_TC                            off: does not build against current
#                                        kernel headers (CBQ was removed)
# The cards' busybox calls itself "v1.37.0.git"; this one "v1.37.0".
#
# Output, in build/stage1/ (build/initramfs/ is install_debian.sh's copy of the
# cards' initramfs and is left alone):
#   initramfs.cpio.gz, .sha256     what install_debian.sh puts on P25TBOOT
#   initramfs.list                 its contents (mode, owner, name, link)
#   compare-cards.txt              the report of "compare"
# Reproducible: fixed file times (SOURCE_DATE_EPOCH = the busybox release
# date), sorted names, cpio --reproducible, gzip -n.
#
# Host packages: gcc-aarch64-linux-gnu make cpio curl bzip2
set -euo pipefail
umask 022                       # the same file modes for every user

REPO="$HOME/p25t-backup/p25t-sway"
SRC="$REPO/build/src"
OUT="$REPO/build/stage1"
BB_VER=1.37.0
BB_TAR="busybox-$BB_VER.tar.bz2"
BB_SHA=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
BB_URLS="https://busybox.net/downloads/$BB_TAR
http://archive.ubuntu.com/ubuntu/pool/main/b/busybox/busybox_$BB_VER.orig.tar.bz2"
CARD_CPIO="$HOME/p25t-backup/debian/initramfs.cpio.gz"
CARD_SHA=af94fceef82006ee4813095b0b32a70de5e3a491db7290b8b635010a83ccefd8
MODE=${1:-build}

say() { echo; echo "=== $*"; }
die() { echo "STOPPED: $*" >&2; exit 1; }
case "$MODE" in build|compare) ;; *) sed -n '3,33p' "$0"; exit 1 ;; esac

# one line per cpio entry: mode owner group name [-> target] (no dates, no sizes)
cpio_list() {
    zcat "$1" | cpio -itv --quiet 2> /dev/null \
        | awk '{ l = $1 " " $3 " " $4 " " $9; if ($10 == "->") l = l " -> " $11; print l }' \
        | sort -k4
}

say "1/5 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
missing=""
for t in make cpio curl bzip2 gzip aarch64-linux-gnu-gcc; do
    command -v "$t" > /dev/null || missing="$missing $t"
done
[ -z "$missing" ] || die "missing:$missing
  sudo apt install gcc-aarch64-linux-gnu make cpio curl bzip2"
[ -f "$REPO/initramfs/init" ] || die "$REPO/initramfs/init missing"
if [ "$MODE" = compare ]; then
    [ -f "$CARD_CPIO" ] || die "$CARD_CPIO missing"
    echo "$CARD_SHA  $CARD_CPIO" | sha256sum -c --quiet \
        || die "$CARD_CPIO is not the cards' initramfs (af94fcee...)"
fi
echo "OK ($MODE)"

say "2/5 Source: busybox $BB_VER"
mkdir -p "$SRC" "$OUT"
if [ ! -f "$SRC/$BB_TAR" ]; then
    for u in $BB_URLS; do
        echo "downloading $u"
        if curl -fsSL --max-time 300 -o "$SRC/$BB_TAR.part" "$u"; then
            mv "$SRC/$BB_TAR.part" "$SRC/$BB_TAR"; break
        fi
        rm -f "$SRC/$BB_TAR.part"
    done
fi
[ -f "$SRC/$BB_TAR" ] || die "could not download $BB_TAR"
echo "$BB_SHA  $SRC/$BB_TAR" | sha256sum -c --quiet \
    || die "$SRC/$BB_TAR is not the known release (sha256 ${BB_SHA:0:12}...)"
echo "$BB_TAR: sha256 ${BB_SHA:0:12}... OK"

say "3/5 Busybox build (about a minute)"
BB="$SRC/busybox-$BB_VER"
rm -rf "$BB"                                   # always from a fresh tree
tar -xjf "$SRC/$BB_TAR" -C "$SRC"
export SOURCE_DATE_EPOCH TZ=UTC                # same banner date on every PC
SOURCE_DATE_EPOCH=$(stat -c %Y "$BB/Makefile")  # the release date
make -C "$BB" -s defconfig > /dev/null
sed -i -e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' \
       -e 's/^CONFIG_SHA1_HWACCEL=y$/# CONFIG_SHA1_HWACCEL is not set/' \
       -e 's/^CONFIG_SHA256_HWACCEL=y$/# CONFIG_SHA256_HWACCEL is not set/' \
       -e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' "$BB/.config"
grep -qx 'CONFIG_STATIC=y' "$BB/.config" || die "CONFIG_STATIC not set"
for c in SHA1_HWACCEL SHA256_HWACCEL TC; do
    grep -qx "# CONFIG_$c is not set" "$BB/.config" || die "CONFIG_$c not switched off"
done
make -C "$BB" -s CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" > "$OUT/busybox-build.log" 2>&1 \
    || { tail -20 "$OUT/busybox-build.log"; die "busybox build failed (log: $OUT/busybox-build.log)"; }
cp "$BB/.config" "$OUT/busybox.config"
strings "$BB/busybox" | grep -m1 '^BusyBox v' || true

say "4/5 initramfs"
ROOT="$OUT/root"
rm -rf "$ROOT"; mkdir -p "$ROOT"
make -C "$BB" -s CROSS_COMPILE=aarch64-linux-gnu- CONFIG_PREFIX="$ROOT" install > /dev/null
mkdir -p "$ROOT"/boot "$ROOT"/dev "$ROOT"/etc "$ROOT"/proc "$ROOT"/sys "$ROOT"/tmp
install -m 755 "$REPO/initramfs/init" "$ROOT/init"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
( cd "$ROOT" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet ) \
    | gzip -9 -n > "$OUT/initramfs.cpio.gz"
( cd "$OUT" && sha256sum initramfs.cpio.gz > initramfs.cpio.gz.sha256 )
cpio_list "$OUT/initramfs.cpio.gz" > "$OUT/initramfs.list"
echo "$OUT/initramfs.cpio.gz: $(stat -c %s "$OUT/initramfs.cpio.gz") bytes, $(wc -l < "$OUT/initramfs.list") entries, sha256 $(cut -c1-16 "$OUT/initramfs.cpio.gz.sha256")..."

if [ "$MODE" = build ]; then
    say "5/5 Done (compare with the cards' initramfs: run again with 'compare')"
    exit 0
fi

say "5/5 Compare with the cards' initramfs ($CARD_CPIO)"
CMP="$OUT/compare-cards"
rm -rf "$CMP"; mkdir -p "$CMP/card"
REPORT="$OUT/compare-cards.txt"
( cd "$CMP/card" && zcat "$CARD_CPIO" | cpio -id --quiet 2> /dev/null )
cpio_list "$CARD_CPIO" > "$CMP/card.list"
{
echo "build_initramfs.sh compare, $(date -u '+%F %T') UTC"
echo "new:   $OUT/initramfs.cpio.gz"
echo "cards: $CARD_CPIO (af94fcee...)"
echo
echo "## Entries (mode, owner, name, link target; dates and sizes left out)"
echo "  cards $(wc -l < "$CMP/card.list"), new $(wc -l < "$OUT/initramfs.list")"
if diff "$CMP/card.list" "$OUT/initramfs.list" > "$CMP/list.diff"; then
    echo "  the same: every directory, file and command link"
else
    echo "  DIFFERENT (< cards, > new):"; sed 's/^/    /' "$CMP/list.diff"
fi
echo
echo "## init (the new one has one line more: the SPDX line)"
if sed 2d "$ROOT/init" | cmp -s - "$CMP/card/init"; then
    echo "  the same apart from the SPDX line"
else
    echo "  DIFFERENT:"; sed 2d "$ROOT/init" | diff "$CMP/card/init" - | sed 's/^/    /' || true
fi
echo
echo "## busybox"
echo "  cards: $(strings "$CMP/card/bin/busybox" | grep -m1 '^BusyBox v'), $(stat -c %s "$CMP/card/bin/busybox") bytes"
echo "  new:   $(strings "$ROOT/bin/busybox" | grep -m1 '^BusyBox v'), $(stat -c %s "$ROOT/bin/busybox") bytes"
echo "  (the command links above are busybox's command list)"
} | tee "$REPORT"
echo
echo "report: $REPORT"
