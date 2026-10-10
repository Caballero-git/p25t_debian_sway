#!/bin/bash
# Install the kernel modules (and the AIC8800 Wi-Fi firmware) from a folder
# made by pack_kernel.sh, on the tablet, with a backup of what they replace.
# Run it BEFORE deploy_kernel.sh, then reboot.
#
#     sudo bash install_modules.sh <TAG> <DIR>       install (TAG like 0031)
#     sudo bash install_modules.sh restore <TAG>     put the backed-up modules back
#
# <DIR> is the unpacked p25t-kernel-<profile>/ folder. Backups go to
# /home/jose/boot-backups/ (the same place deploy_kernel.sh uses):
#   modules-<release>.pre-<TAG>-backup.tar   (only if that release existed)
#   firmware-aic8800.pre-<TAG>-backup.tar    (only if the firmware changes)
# It never deletes a backup.
set -u
BK=/home/jose/boot-backups
MODS=/usr/lib/modules
FW=/usr/lib/firmware

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

if [ "${1:-}" = restore ]; then
    TAG=${2:-}
    case "$TAG" in [0-9][0-9][0-9][0-9]) ;; *) die "usage: sudo bash install_modules.sh restore <TAG>" ;; esac
    T=$(ls "$BK"/modules-*.pre-"$TAG"-backup.tar 2>/dev/null | head -1)
    [ -n "$T" ] || die "no modules backup for $TAG in $BK"
    REL=$(basename "$T"); REL=${REL#modules-}; REL=${REL%.pre-$TAG-backup.tar}
    echo "restoring $MODS/$REL from $T"
    rm -rf "$MODS/.$REL.restore" && mkdir -p "$MODS/.$REL.restore"
    tar -C "$MODS/.$REL.restore" -xf "$T" || die "unpack failed"
    [ -d "$MODS/.$REL.restore/$REL" ] || die "backup does not contain $REL"
    rm -rf "$MODS/$REL" && mv "$MODS/.$REL.restore/$REL" "$MODS/$REL" && rmdir "$MODS/.$REL.restore"
    F="$BK/firmware-aic8800.pre-$TAG-backup.tar"
    if [ -f "$F" ]; then
        echo "restoring $FW/aic8800_fw from $F"
        rm -rf "$FW/aic8800_fw" && tar -C "$FW" -xf "$F" || die "firmware restore failed"
    fi
    depmod -a "$REL"; sync
    echo "restored modules of $REL. Restore the boot files as in deploy_kernel.sh (rollback), then reboot."
    exit 0
fi

TAG=${1:-}; DIR=${2:-}
case "$TAG" in [0-9][0-9][0-9][0-9]) ;; *) die "usage: sudo bash install_modules.sh <TAG like 0031> <DIR>" ;; esac
[ -d "$DIR" ] || die "folder $DIR not found"
DIR=$(cd "$DIR" && pwd)

echo "=== 1. files ==="
( cd "$DIR" && sha256sum -c --quiet files.sha256 ) || die "files do not match files.sha256"
REL=$(cat "$DIR/release.txt")
IMGREL=$(strings "$DIR/Image" | sed -n 's/.*Linux version \([0-9][^ ]*\).*/\1/p' | sed -n 1p)
[ "$IMGREL" = "$REL" ] || die "Image is $IMGREL, modules are $REL"
tar -tf "$DIR/modules.tar" | grep -q "^lib/modules/$REL/extra/aic8800_fdrv.ko$" || die "modules.tar has no AIC8800 module for $REL"
echo "release $REL (running now: $(uname -r))"

echo; echo "=== 2. space ==="
need=$(( $(stat -c %s "$DIR/modules.tar") * 2 + 10485760 ))
free=$(df -B1 --output=avail "$MODS" | tail -1)
echo "need about $((need / 1048576)) MB, free $((free / 1048576)) MB on the root fs"
[ "$free" -gt "$need" ] || die "not enough space"

echo; echo "=== 3. backup ==="
mkdir -p "$BK"
MB="$BK/modules-$REL.pre-$TAG-backup.tar"
[ -e "$MB" ] && die "$MB exists already - installed before? check by hand"
if [ -d "$MODS/$REL" ]; then
    tar -C "$MODS" -cf "$MB" "$REL" || die "backup of $MODS/$REL failed"
    chown jose:jose "$MB"
    echo "backup: $MB ($(tar -tf "$MB" | grep -c '\.ko') modules)"
else
    echo "no $MODS/$REL yet - nothing to back up"
fi

echo; echo "=== 4. modules ==="
NEW="$MODS/.$REL.new"
rm -rf "$NEW" && mkdir -p "$NEW"
tar -C "$NEW" -xf "$DIR/modules.tar" || die "unpack failed (nothing replaced)"
[ -d "$NEW/lib/modules/$REL" ] || die "unexpected layout in modules.tar"
rm -rf "$MODS/$REL" && mv "$NEW/lib/modules/$REL" "$MODS/$REL" && rm -rf "$NEW" || die "replace failed - restore with: sudo bash install_modules.sh restore $TAG"
depmod -a "$REL" || die "depmod failed"
grep -q 'extra/aic8800_fdrv.ko' "$MODS/$REL/modules.dep" || die "modules.dep does not list aic8800_fdrv"
echo "installed $(find "$MODS/$REL" -name '*.ko*' | wc -l) modules in $MODS/$REL"
# check every installed module against the tar
( cd "$MODS" && for k in $(tar -tf "$DIR/modules.tar" | grep '\.ko'); do
      r=${k#lib/modules/}; cmp -s <(tar -xOf "$DIR/modules.tar" "$k") "$r" || { echo "differs: $r"; exit 1; }
  done ) || die "an installed module differs from the tar"
echo "all modules checked against the tar"

echo; echo "=== 5. AIC8800 firmware ==="
T=$(mktemp -d)
tar -C "$T" -xf "$DIR/firmware-aic8800.tar"
if [ -d "$FW/aic8800_fw" ] && diff -rq "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" > /dev/null; then
    echo "firmware identical to the installed one - left as is"
else
    if [ -d "$FW/aic8800_fw" ]; then
        tar -C "$FW" -cf "$BK/firmware-aic8800.pre-$TAG-backup.tar" aic8800_fw && echo "firmware backup: $BK/firmware-aic8800.pre-$TAG-backup.tar"
    fi
    mkdir -p "$FW" && rm -rf "$FW/aic8800_fw" && cp -r "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" || die "firmware copy failed"
    diff -rq "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" > /dev/null || die "firmware differs after copy"
    echo "firmware installed"
fi
rm -rf "$T"
sync

echo; echo "=== done: modules of $REL installed. Next: sudo bash deploy_kernel.sh $TAG $DIR, then sudo reboot ==="
echo "Rollback: sudo bash install_modules.sh restore $TAG, plus the boot-file rollback of deploy_kernel.sh."
