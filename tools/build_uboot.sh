#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_uboot.sh - build the P25T boot loader: mainline U-Boot and Rockchip's
# BL31 in one FIT image, the file the tablet's stock SPL loads from the card.
#
# Usage (PC, normal user):
#     bash ~/p25t-backup/p25t-sway/tools/build_uboot.sh
#         download the sources (first run only), build, make the FIT
#     bash ~/p25t-backup/p25t-sway/tools/build_uboot.sh compare
#         the same, then compare the FIT with the one on card 1, read from
#         build/card1-first-1GiB.img (tools/clone_boot_part.sh read)
#
# Sources, pinned (downloaded into build/src/, about 420 MB):
#   U-Boot  github.com/u-boot/u-boot, tag v2026.10-rc5 (commit a06e89ab)
#   BL31    github.com/rockchip-linux/rkbin, bin/rk35/rk3568_bl31_v1.46.elf
#           at commit 3e288fe8, checked by sha256. Only this one file is
#           fetched. It is Rockchip's binary under Rockchip's licence, so it
#           never goes into this repository.
# From this repository:
#   u-boot/p25t-u-boot.config  U-Boot configuration (boot command, no delay)
#   u-boot/split_bl31.py       BL31 ELF -> one file per load segment
#   u-boot/p25t.its            FIT layout the stock SPL accepts
# Output, in build/u-boot/:
#   uboot.itb, uboot.itb.sha256    the FIT (must stay below 2 MiB)
#   u-boot.bin, u-boot.dtb, bl31_0x*.bin, p25t.its   what went into it
#   compare-card1.txt              the report of "compare"
#
# The build is reproducible: SOURCE_DATE_EPOCH is the tag's commit time, so
# the date inside U-Boot and the FIT is the same on every run and every PC
# (with the same compiler). Card 1's U-Boot was built without it, so its
# build date differs; "compare" shows exactly which bytes differ.
#
# Host packages (Debian/Ubuntu/Mint names):
#   gcc-aarch64-linux-gnu make bison flex swig python3-dev python3-setuptools
#   libssl-dev libgnutls28-dev uuid-dev git
set -euo pipefail

REPO="$HOME/p25t-backup/p25t-sway"
SRC="$REPO/build/src"
UB="$SRC/u-boot"
RKBIN="$SRC/rkbin"
OUT="$REPO/build/u-boot"
UB_URL=https://github.com/u-boot/u-boot.git
UB_TAG=v2026.10-rc5
UB_COMMIT=a06e89ab05eaa2b8344d521319399333cd760ae5
RKBIN_URL=https://github.com/rockchip-linux/rkbin.git
RKBIN_COMMIT=3e288fe814e059dd06833495f845cab04ac20a5c
BL31_PATH=bin/rk35/rk3568_bl31_v1.46.elf
BL31_SHA=c81ac7e8e1fd727cf7f0db62a9aaea760bde2b270e34d98eb264a264b86df749
CARD_IMG="$REPO/build/card1-first-1GiB.img"
MODE=${1:-build}

say() { echo; echo "=== $*"; }
die() { echo "STOPPED: $*" >&2; exit 1; }
case "$MODE" in build|compare) ;; *) sed -n '3,35p' "$0"; exit 1 ;; esac

say "1/5 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
missing=""
for t in git make bison flex swig python3 aarch64-linux-gnu-gcc; do
    command -v "$t" > /dev/null || missing="$missing $t"
done
python3 -c 'import setuptools' 2> /dev/null || missing="$missing python3-setuptools"
[ -f /usr/include/openssl/ssl.h ] || missing="$missing libssl-dev"
[ -f /usr/include/gnutls/gnutls.h ] || missing="$missing libgnutls28-dev"
python3 -c 'import sysconfig, os, sys; sys.exit(not os.path.exists(os.path.join(sysconfig.get_paths()["include"], "Python.h")))' \
    || missing="$missing python3-dev"
[ -z "$missing" ] || die "missing:$missing
  sudo apt install gcc-aarch64-linux-gnu make bison flex swig python3-dev python3-setuptools libssl-dev libgnutls28-dev uuid-dev git"
for f in p25t-u-boot.config split_bl31.py p25t.its; do
    [ -f "$REPO/u-boot/$f" ] || die "$REPO/u-boot/$f missing"
done
if [ "$MODE" = compare ]; then
    [ -f "$CARD_IMG" ] || die "$CARD_IMG missing (tools/clone_boot_part.sh read makes it)"
fi
echo "OK ($MODE)"

say "2/5 Sources"
mkdir -p "$SRC" "$OUT"
if [ ! -d "$UB/.git" ]; then
    echo "downloading U-Boot $UB_TAG (shallow, about 420 MB) ..."
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$UB_TAG" "$UB_URL" "$UB"
fi
[ "$(git -C "$UB" rev-parse HEAD)" = "$UB_COMMIT" ] \
    || die "$UB is not at $UB_TAG ($UB_COMMIT)"
[ -z "$(git -C "$UB" status --porcelain --untracked-files=no)" ] \
    || die "$UB has changed files (git -C $UB status)"
echo "U-Boot: $UB_TAG, ${UB_COMMIT:0:12}, unchanged"
if [ ! -d "$RKBIN/.git" ]; then
    echo "downloading rkbin's history without file contents (a few MB) ..."
    git clone -q --filter=blob:none --no-checkout "$RKBIN_URL" "$RKBIN"
fi
git -C "$RKBIN" show "$RKBIN_COMMIT:$BL31_PATH" > "$OUT/bl31.elf"
echo "$BL31_SHA  $OUT/bl31.elf" | sha256sum -c --quiet \
    || die "BL31 is not the known file (sha256 ${BL31_SHA:0:12}...)"
echo "BL31: $(basename "$BL31_PATH") from rkbin ${RKBIN_COMMIT:0:12}, sha256 ${BL31_SHA:0:12}... OK"

say "3/5 U-Boot build (about a minute; only u-boot.bin, u-boot.dtb and the tools)"
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$UB" log -1 --format=%ct)
cp "$REPO/u-boot/p25t-u-boot.config" "$UB/.config"
make -C "$UB" -s CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
cmp -s "$REPO/u-boot/p25t-u-boot.config" "$UB/.config" \
    || echo "note: olddefconfig changed the config (diff $REPO/u-boot/p25t-u-boot.config $UB/.config)"
make -C "$UB" -s CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" u-boot.bin u-boot.dtb tools
strings "$UB/u-boot.bin" | grep -m1 'U-Boot 20.*(' || true

say "4/5 FIT image"
rm -f "$OUT"/bl31_0x*.bin "$OUT/uboot.itb"
python3 "$REPO/u-boot/split_bl31.py" "$OUT/bl31.elf" "$OUT"
cp "$UB/u-boot.bin" "$UB/u-boot.dtb" "$REPO/u-boot/p25t.its" "$OUT/"
# mkimage runs "dtc" from PATH: use the one U-Boot just built
( cd "$OUT" && PATH="$UB/scripts/dtc:$PATH" "$UB/tools/mkimage" -E -B 0x200 -p 0x1000 \
      -f p25t.its uboot.itb > mkimage.log ) || { cat "$OUT/mkimage.log"; die "mkimage failed"; }
SIZE=$(stat -c %s "$OUT/uboot.itb")
[ "$SIZE" -lt 2097152 ] || die "FIT is $SIZE bytes, more than 2 MiB"
( cd "$OUT" && sha256sum uboot.itb > uboot.itb.sha256 )
echo "$OUT/uboot.itb: $SIZE bytes, sha256 $(cut -c1-16 "$OUT/uboot.itb.sha256")..."

if [ "$MODE" = build ]; then
    say "5/5 Done (compare with card 1: run again with 'compare')"
    exit 0
fi

say "5/5 Compare with card 1 ($CARD_IMG)"
CMP="$OUT/compare-card1"
rm -rf "$CMP"; mkdir -p "$CMP"
REPORT="$OUT/compare-card1.txt"
DUMP="$UB/tools/dumpimage"
{
echo "build_uboot.sh compare, $(date '+%F %T')"
echo "new FIT: $OUT/uboot.itb ($SIZE bytes)"
echo
echo "## The six copies on card 1 (partitions uboot, uboot_a, uboot_b; +0 and +4096)"
first=""
for s in 16384 20480 24576 28672 32768 36864; do
    dd if="$CARD_IMG" of="$CMP/copy-$s.itb" bs=512 skip=$s count=4096 status=none
    if [ -z "$first" ]; then
        first=$s; echo "  sector $s: reference"
    elif cmp -s "$CMP/copy-$first.itb" "$CMP/copy-$s.itb"; then
        echo "  sector $s: same as $first"
    else
        echo "  sector $s: DIFFERENT from $first"
    fi
done
CARD="$CMP/copy-$first.itb"
echo
echo "## FIT headers"
echo "  card 1: $("$DUMP" -l "$CARD" | grep -m1 '^FIT description')"
echo "          $("$DUMP" -l "$CARD" | grep -m1 '^Created')"
echo "  new:    $("$DUMP" -l "$OUT/uboot.itb" | grep -m1 '^FIT description')"
echo "          $("$DUMP" -l "$OUT/uboot.itb" | grep -m1 '^Created')"
echo
echo "## The eight parts (0 = U-Boot, 1-6 = BL31 pieces, 7 = U-Boot's device tree)"
same=0
for i in 0 1 2 3 4 5 6 7; do
    "$DUMP" -T flat_dt -p $i -o "$CMP/card-$i.bin" "$CARD" > /dev/null
    "$DUMP" -T flat_dt -p $i -o "$CMP/new-$i.bin" "$OUT/uboot.itb" > /dev/null
    a=$(sha256sum < "$CMP/card-$i.bin" | cut -c1-16)
    b=$(sha256sum < "$CMP/new-$i.bin" | cut -c1-16)
    sa=$(stat -c %s "$CMP/card-$i.bin"); sb=$(stat -c %s "$CMP/new-$i.bin")
    if [ "$a" = "$b" ]; then
        echo "  part $i: SAME       $sa bytes, sha256 $a..."; same=$((same + 1))
    else
        echo "  part $i: DIFFERENT  card $sa bytes $a... / new $sb bytes $b..."
    fi
done
echo
echo "## U-Boot itself (part 0), byte by byte"
if cmp -s "$CMP/card-0.bin" "$CMP/new-0.bin"; then
    echo "  identical"
else
    # cmp exits 1 when the files differ: that is the expected case here
    cmp -l "$CMP/card-0.bin" "$CMP/new-0.bin" > "$CMP/u-boot.cmp" 2> /dev/null || true
    n=$(wc -l < "$CMP/u-boot.cmp")
    echo "  $n bytes differ; sizes card $(stat -c %s "$CMP/card-0.bin") / new $(stat -c %s "$CMP/new-0.bin")"
    echo "  differing byte offsets (first and last): $(awk 'NR==1{f=$1} {l=$1} END{print f-1, l-1}' "$CMP/u-boot.cmp")"
    echo "  version strings:"
    echo "    card 1: $(strings "$CMP/card-0.bin" | grep -m1 'U-Boot 20.*(')"
    echo "    new:    $(strings "$CMP/new-0.bin" | grep -m1 'U-Boot 20.*(')"
fi
echo
echo "## Result: $same of 8 parts identical"
} | tee "$REPORT"
echo
echo "report: $REPORT"
