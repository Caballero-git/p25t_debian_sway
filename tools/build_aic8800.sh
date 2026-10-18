#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the AIC8800 Wi-Fi driver (out of tree) for one kernel profile.
#
# Usage:
#     bash ~/p25t-backup/p25t-sway/tools/build_aic8800.sh sway
#     bash ~/p25t-backup/p25t-sway/tools/build_aic8800.sh console
#
# Run it AFTER tools/build_kernel.sh <profile> (it needs that build's
# Module.symvers), and again after every build_kernel.sh run: that script
# recreates modules-staging/ and so removes the Wi-Fi modules.
#
# Source:  ~/p25t-backup/aic8800 = github.com/radxa-pkg/aic8800 at commit
#          516e3b0, Debian patch series applied, plus card 1's 7.3 fix
#          kernel/aic8800-fix-linux-7.3-build.patch (copied unchanged from
#          p25t-linux, so this repo builds on its own).
#          Cloned and prepared on the first run (needs network once).
#          The prepared SDIO driver source is checked against a fingerprint:
#          the exact source of card 1's working modules.
# Output:  build/kernel-<profile>/aic8800/ (objects)
#          build/kernel-<profile>/modules-staging/lib/modules/<release>/extra/
#              aic8800_bsp.ko, aic8800_fdrv.ko (+ depmod)
#          build/kernel-<profile>/firmware-staging/lib/firmware/aic8800_fw/SDIO/aic8800/
# Steps 1-3 take seconds (first run: the clone, ~1 min); step 4 ~1 min.
set -euo pipefail

PROFILE="${1:-}"
case "$PROFILE" in
    console|sway) ;;
    *) echo "usage: $0 console|sway"; exit 1 ;;
esac

REPO="$HOME/p25t-backup/p25t-sway"
SRC="$HOME/p25t-backup/linux-sway"
OUT="$REPO/build/kernel-$PROFILE"
AIC="$HOME/p25t-backup/aic8800"
URL=https://github.com/radxa-pkg/aic8800.git
COMMIT=516e3b087763d80c44f5e3b6d2dd63e0d925c91d
FIX="$REPO/kernel/aic8800-fix-linux-7.3-build.patch"
DRV=src/SDIO/driver_fw/driver/aic8800
FW=src/SDIO/driver_fw/fw/aic8800
# sha256 over the sorted sha256sum lines of the SDIO driver's *.c *.h
# Makefile Kconfig (no *.mod.c) - card 1's working source, 140 files
FINGERPRINT=446581def81b0cd6ca576ac6d00a2770bd8ca19d3278624eb8d212af5ac5f55d
# the only two Debian patches that may fail (USB/line-ending hunks only)
EXPECTED_FAILS="fix-usb-firmware-path.patch fix-Lower-the-debugging-log-level.patch"
MAKE=(make -C "$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=)

say() { echo; echo "=== $*"; }
fingerprint() {
    ( cd "$AIC" && find "$DRV" -type f \( -name '*.c' -o -name '*.h' -o -name Makefile -o -name Kconfig \) \
          ! -name '*.mod.c' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64 )
}

say "1/5 Checks"
command -v aarch64-linux-gnu-gcc > /dev/null || { echo "STOPPED: aarch64-linux-gnu-gcc not found"; exit 1; }
command -v depmod > /dev/null || { echo "STOPPED: depmod not found (package kmod)"; exit 1; }
[ -f "$OUT/Module.symvers" ] || { echo "STOPPED: $OUT/Module.symvers missing - run tools/build_kernel.sh $PROFILE first"; exit 1; }
[ -d "$OUT/modules-staging/lib/modules" ] || { echo "STOPPED: $OUT/modules-staging missing - build_kernel.sh did not finish"; exit 1; }
[ -f "$FIX" ] || { echo "STOPPED: $FIX not found"; exit 1; }
REL=$(make -s -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)
echo "kernel build $OUT, release $REL"

say "2/5 Source $AIC"
if [ ! -d "$AIC/.git" ]; then
    git clone -q "$URL" "$AIC"
    echo "cloned $URL"
fi
[ "$(git -C "$AIC" rev-parse HEAD)" = "$COMMIT" ] || git -C "$AIC" checkout -q "$COMMIT"
echo "at $(git -C "$AIC" log --oneline -1)"

say "3/5 Patches (Debian series + card 1's 7.3 fix)"
if [ "$(fingerprint)" = "$FINGERPRINT" ]; then
    echo "already prepared - source matches card 1's working driver"
else
    [ -z "$(git -C "$AIC" status --porcelain)" ] || {
        echo "STOPPED: $AIC has changes but does not match the expected source."
        echo "Start clean with:  git -C $AIC checkout -- .  and  git -C $AIC clean -fd"
        exit 1; }
    FAILS=""
    cd "$AIC"
    while read -r p; do
        [ -n "$p" ] || continue
        patch -p1 --forward -s < "debian/patches/$p" > /dev/null 2>&1 || FAILS="$FAILS $p"
    done < debian/patches/series
    echo "Debian patches that did not apply fully:${FAILS:- none}"
    for p in $FAILS; do
        case " $EXPECTED_FAILS " in *" $p "*) ;; *) echo "STOPPED: unexpected failure $p"; exit 1 ;; esac
    done
    patch -p1 -s < "$FIX"
    echo "applied $(basename "$FIX")"
    [ "$(fingerprint)" = "$FINGERPRINT" ] || { echo "STOPPED: prepared source differs from card 1's working driver"; exit 1; }
    echo "source matches card 1's working driver"
fi

say "4/5 Build against $OUT"
rm -rf "$OUT/aic8800"
cp -r "$AIC/$DRV" "$OUT/aic8800"
"${MAKE[@]}" M="$OUT/aic8800" -j"$(nproc)" modules > "$OUT/aic8800/build.log" 2>&1 || {
    tail -20 "$OUT/aic8800/build.log"; echo "STOPPED: build failed, full log $OUT/aic8800/build.log"; exit 1; }
for m in aic8800_bsp/aic8800_bsp.ko aic8800_fdrv/aic8800_fdrv.ko; do
    VM=$(modinfo -F vermagic "$OUT/aic8800/$m" | cut -d' ' -f1)
    [ "$VM" = "$REL" ] || { echo "STOPPED: $m is for '$VM', not $REL"; exit 1; }
done
echo "built for $REL (log: $OUT/aic8800/build.log)"

say "5/5 Staging"
EXTRA="$OUT/modules-staging/lib/modules/$REL/extra"
mkdir -p "$EXTRA"
cp "$OUT/aic8800/aic8800_bsp/aic8800_bsp.ko" "$OUT/aic8800/aic8800_fdrv/aic8800_fdrv.ko" "$EXTRA/"
depmod -b "$OUT/modules-staging" -F "$OUT/System.map" "$REL"
grep -q "extra/aic8800_fdrv.ko" "$OUT/modules-staging/lib/modules/$REL/modules.dep" || { echo "STOPPED: depmod did not list the modules"; exit 1; }
FWD="$OUT/firmware-staging/lib/firmware/aic8800_fw/SDIO"
rm -rf "$FWD"; mkdir -p "$FWD"
cp -r "$AIC/$FW" "$FWD/"
( cd "$EXTRA" && sha256sum aic8800_bsp.ko aic8800_fdrv.ko )
echo "firmware: $FWD/aic8800 ($(ls "$FWD/aic8800" | wc -l) files)"
echo "AIC8800 OK ($PROFILE, $REL)"
