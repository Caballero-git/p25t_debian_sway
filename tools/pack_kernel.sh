#!/bin/bash
# Pack a built kernel (one profile) for the tablet: boot files, modules
# (with the AIC8800 Wi-Fi modules), Wi-Fi firmware and the tablet scripts,
# all in one tar with checksums.
#
# Usage (PC, after build_kernel.sh <profile> and build_aic8800.sh <profile>):
#     bash ~/p25t-backup/p25t-sway/tools/pack_kernel.sh console
#     bash ~/p25t-backup/p25t-sway/tools/pack_kernel.sh sway
#
# Output: build/kernel-<profile>/p25t-kernel-<profile>.tar, which unpacks
# to a folder p25t-kernel-<profile>/ with:
#   Image, rk3566-teclast-p25t.dtb, rk3566-teclast-p25t-usbhost.dtb,
#   new.sha256           (the three boot files; read by deploy_kernel.sh)
#   modules.tar          (lib/modules/<release>/, incl. extra/aic8800_*.ko)
#   firmware-aic8800.tar (lib/firmware/aic8800_fw/)
#   release.txt          (kernel release, e.g. 7.3.0-rc4-p25t)
#   install_modules.sh, deploy_kernel.sh, health_snapshot.sh, health_compare.sh
#   files.sha256         (all of the above)
set -euo pipefail

PROFILE="${1:-}"
case "$PROFILE" in
    console|sway) ;;
    *) echo "usage: $0 console|sway"; exit 1 ;;
esac

REPO="$HOME/p25t-backup/p25t-sway"
OUT="$REPO/build/kernel-$PROFILE"
NAME="p25t-kernel-$PROFILE"
P="$OUT/$NAME"
B="$OUT/arch/arm64/boot"

say() { echo; echo "=== $*"; }
die() { echo "STOPPED: $*"; exit 1; }

say "1/4 Checks"
for f in "$B/Image" "$B/dts/rockchip/rk3566-teclast-p25t.dtb" "$B/dts/rockchip/rk3566-teclast-p25t-usbhost.dtb"; do
    [ -f "$f" ] || die "$f missing - run build_kernel.sh $PROFILE"
done
N=$(ls "$OUT/modules-staging/lib/modules" | wc -l)
[ "$N" -eq 1 ] || die "expected one release in modules-staging, found $N"
REL=$(ls "$OUT/modules-staging/lib/modules")
IMGREL=$(strings "$B/Image" | sed -n 's/.*Linux version \([0-9][^ ]*\).*/\1/p' | sed -n 1p)
[ "$IMGREL" = "$REL" ] || die "Image is $IMGREL but the modules are $REL"
M="$OUT/modules-staging/lib/modules/$REL"
[ -f "$M/extra/aic8800_fdrv.ko" ] && [ -f "$M/extra/aic8800_bsp.ko" ] || die "no AIC8800 modules - run build_aic8800.sh $PROFILE (after every build_kernel.sh)"
grep -q 'extra/aic8800_fdrv.ko' "$M/modules.dep" || die "modules.dep does not list the AIC8800 modules"
[ -d "$OUT/firmware-staging/lib/firmware/aic8800_fw" ] || die "no staged AIC8800 firmware"
for s in install_modules.sh deploy_kernel.sh health_snapshot.sh health_compare.sh; do
    [ -f "$REPO/tools/$s" ] || die "$REPO/tools/$s missing"
done
echo "release $REL, $(find "$M" -name '*.ko*' | wc -l) modules"

say "2/4 Collect files in $P"
rm -rf "$P" "$OUT/$NAME.tar"
mkdir -p "$P"
cp "$B/Image" "$B/dts/rockchip/rk3566-teclast-p25t.dtb" "$B/dts/rockchip/rk3566-teclast-p25t-usbhost.dtb" "$P/"
( cd "$P" && sha256sum Image rk3566-teclast-p25t.dtb rk3566-teclast-p25t-usbhost.dtb > new.sha256 )
tar -C "$OUT/modules-staging" --owner=0 --group=0 --exclude="lib/modules/$REL/build" --exclude="lib/modules/$REL/source" -cf "$P/modules.tar" "lib/modules/$REL"
tar -C "$OUT/firmware-staging" --owner=0 --group=0 -cf "$P/firmware-aic8800.tar" lib/firmware/aic8800_fw
echo "$REL" > "$P/release.txt"
for s in install_modules.sh deploy_kernel.sh health_snapshot.sh health_compare.sh; do cp "$REPO/tools/$s" "$P/"; done
( cd "$P" && sha256sum Image rk3566-teclast-p25t.dtb rk3566-teclast-p25t-usbhost.dtb new.sha256 modules.tar firmware-aic8800.tar release.txt install_modules.sh deploy_kernel.sh health_snapshot.sh health_compare.sh > files.sha256 )

say "3/4 Tar"
tar -C "$OUT" -cf "$OUT/$NAME.tar" "$NAME"
tar -tf "$OUT/$NAME.tar" | sed 's/^/    /'
( cd "$P" && sha256sum -c --quiet files.sha256 ) && echo "files.sha256 OK"

say "4/4 Summary"
cat "$P/new.sha256"
echo "tar: $OUT/$NAME.tar ($(du -h "$OUT/$NAME.tar" | cut -f1)), release $REL"
echo "PACK OK ($PROFILE, $REL)"
