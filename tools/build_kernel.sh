#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Configure and build the P25T kernel for one profile, out of tree.
#
# Usage:
#     bash ~/p25t-backup/p25t-sway/tools/build_kernel.sh sway
#     bash ~/p25t-backup/p25t-sway/tools/build_kernel.sh console
#
# Source:  ~/p25t-backup/linux-sway, branch p25t-base (never ~/p25t-backup/linux)
# Config:  kernel/p25t-kernel.config + kernel/common.fragment + kernel/<profile>.fragment
# Output:  build/kernel-<profile>/ (objects, Image, DTBs)
#          build/kernel-<profile>/modules-staging/ (modules_install)
#          kernel/p25t-<profile>.config (the resulting full config, for the record)
# Steps 1-3 take seconds; step 4 (compiling) takes long; run it again after
# an error and make continues where it stopped.
set -euo pipefail

PROFILE="${1:-}"
case "$PROFILE" in
    console|sway) ;;
    *) echo "usage: $0 console|sway"; exit 1 ;;
esac

REPO="$HOME/p25t-backup/p25t-sway"
SRC="$HOME/p25t-backup/linux-sway"
OUT="$REPO/build/kernel-$PROFILE"
K="$REPO/kernel"
MAKE=(make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=)

say() { echo; echo "=== $*"; }

say "1/5 Checks"
[ "$(git -C "$SRC" rev-parse --abbrev-ref HEAD)" = "p25t-base" ] || { echo "STOPPED: $SRC is not on branch p25t-base"; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "STOPPED: $SRC has local changes"; exit 1; }
[ ! -e "$SRC/.config" ] || { echo "STOPPED: $SRC/.config exists (in-tree build); out-of-tree builds need a clean source"; exit 1; }
command -v aarch64-linux-gnu-gcc > /dev/null || { echo "STOPPED: aarch64-linux-gnu-gcc not found"; exit 1; }
echo "source $SRC at $(git -C "$SRC" log --oneline -1)"
echo "output $OUT"
mkdir -p "$OUT"

say "2/5 Config: base + common + $PROFILE"
( cd "$SRC" && scripts/kconfig/merge_config.sh -m -O "$OUT" \
      "$K/p25t-kernel.config" "$K/common.fragment" "$K/$PROFILE.fragment" > "$OUT/merge.log" )
"${MAKE[@]}" -s olddefconfig

# every line asked for in the fragments must be in the final config
MISSING=0
for f in "$K/common.fragment" "$K/$PROFILE.fragment"; do
    while IFS= read -r line; do
        case "$line" in ""|"#"*) continue ;; esac
        if ! grep -qxF -- "$line" "$OUT/.config"; then
            echo "NOT IN FINAL CONFIG: $line"; MISSING=1
        fi
    done < "$f"
done
[ "$MISSING" -eq 0 ] || { echo "STOPPED: a requested option did not survive olddefconfig (see above)"; exit 1; }
echo "all requested options present"
echo "changes against card 1's config:"
"$SRC/scripts/diffconfig" "$K/p25t-kernel.config" "$OUT/.config" | sed 's/^/    /'
cp "$OUT/.config" "$K/p25t-$PROFILE.config"
echo "full config saved as kernel/p25t-$PROFILE.config"

say "3/5 Release name"
REL=$("${MAKE[@]}" -s kernelrelease)
echo "kernel release: $REL"

say "4/5 Build Image, DTBs, modules (long)"
"${MAKE[@]}" -j"$(nproc)" Image dtbs modules

say "5/5 Modules into a staging folder, summary"
rm -rf "$OUT/modules-staging"
"${MAKE[@]}" -s INSTALL_MOD_PATH="$OUT/modules-staging" modules_install
D="$OUT/arch/arm64/boot"
( cd "$D" && sha256sum Image dts/rockchip/rk3566-teclast-p25t.dtb dts/rockchip/rk3566-teclast-p25t-usbhost.dtb )
echo "modules: $OUT/modules-staging/lib/modules/$REL ($(find "$OUT/modules-staging" -name '*.ko*' | wc -l) files)"
echo "BUILD OK ($PROFILE, $REL)"
