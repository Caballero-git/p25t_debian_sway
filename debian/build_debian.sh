#!/bin/bash
# Build the Debian 13 (trixie) arm64 root filesystem for one P25T profile,
# on the PC. Nothing here touches an SD card or the tablet: the result is
#     ~/p25t-backup/p25t-sway/build/rootfs-<profile>
# which install_debian.sh later copies onto the card.
#
# Usage (from your normal account, it asks for sudo itself):
#     bash ~/p25t-backup/p25t-sway/debian/build_debian.sh sway
#     bash ~/p25t-backup/p25t-sway/debian/build_debian.sh console
#
# Needs first:
#   - the kernel for this profile, packed: tools/pack_kernel.sh <profile>
#     (its modules and Wi-Fi firmware go into the root filesystem)
#   - build/personal/wpa_supplicant-wlan0.conf and build/personal/authorized_keys
#     (taken once from build/card-inventory.tar if missing; never in git)
#
# Steps: 1 checks, 2 host tools, 3 Debian keys, 4 download + install Debian
# (mmdebstrap, 10-25 min), 5 kernel modules + firmware, 6 tablet setup,
# 7 password, 8 summary.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=HOME bash "$0" "$@"
fi

PROFILE="${1:-}"
case "$PROFILE" in
    console) HOSTNAME_NEW=p25t ;;
    sway)    HOSTNAME_NEW=p25t-sway ;;
    *) echo "usage: $0 console|sway"; exit 1 ;;
esac

TABLET_USER=jose
REPO="$HOME/p25t-backup/p25t-sway"
HERE="$REPO/debian"
R="$REPO/build/rootfs-$PROFILE"
LOG="$REPO/build/rootfs-$PROFILE-build-log.txt"
KP="$REPO/build/kernel-$PROFILE/p25t-kernel-$PROFILE"
PERS="$REPO/build/personal"
INV="$REPO/build/card-inventory.tar"
SUITE=trixie
MIRROR=http://deb.debian.org/debian
COMPONENTS="main contrib non-free non-free-firmware"

say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }
pkglist() { grep -h -v -E '^\s*(#|$)' "$@" | tr -d ' \t' | paste -sd, ; }

say "1/8 Checks ($PROFILE, hostname $HOSTNAME_NEW)"
[ "$(uname -m)" = "x86_64" ] || die "this script expects an x86_64 PC"
[ ! -e "$R" ] || die "$R exists already (an earlier build). Remove it first with:  sudo rm -rf $R"
for f in packages-base.txt packages-common.txt "packages-$PROFILE.txt" p25t-setup.sh; do
    [ -f "$HERE/$f" ] || die "$HERE/$f missing"
done
for f in "$REPO/tools/rear-snap.sh" "$REPO/tools/raw2png.py" "$HERE/files/asound.state"; do
    [ -f "$f" ] || die "$f missing"
done
[ -f "$KP/release.txt" ] || die "no packed kernel in $KP - run tools/pack_kernel.sh $PROFILE first"
( cd "$KP" && sha256sum -c --quiet files.sha256 ) || die "packed kernel files do not match files.sha256"
REL=$(cat "$KP/release.txt")
echo "kernel modules: $REL (from $KP)"
mkdir -p "$PERS"
if [ ! -f "$PERS/wpa_supplicant-wlan0.conf" ] || [ ! -f "$PERS/authorized_keys" ]; then
    [ -f "$INV" ] || die "build/personal/ is incomplete and $INV is missing"
    T=$(mktemp -d)
    tar -C "$T" -xf "$INV" inventory/files/etc/wpa_supplicant/wpa_supplicant-wlan0.conf inventory/files/authorized_keys \
        || die "card-inventory.tar has no Wi-Fi configuration or authorized_keys"
    [ -f "$PERS/wpa_supplicant-wlan0.conf" ] || install -m 600 "$T/inventory/files/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" "$PERS/"
    [ -f "$PERS/authorized_keys" ] || install -m 600 "$T/inventory/files/authorized_keys" "$PERS/"
    rm -rf "$T"
    echo "personal files taken from card 1's inventory into $PERS"
fi
grep -q 'psk=' "$PERS/wpa_supplicant-wlan0.conf" || die "$PERS/wpa_supplicant-wlan0.conf has no network (psk=)"
grep -q '^ssh-' "$PERS/authorized_keys" || die "$PERS/authorized_keys has no ssh key"
chmod 700 "$PERS"; chmod 600 "$PERS"/*
FREE_KB=$(df -Pk "$REPO/build" | awk 'NR == 2 {print $4}')
[ "$FREE_KB" -gt 6000000 ] || die "need at least 6 GB free in $REPO/build"
PKGS=$(pkglist "$HERE/packages-base.txt" "$HERE/packages-common.txt" "$HERE/packages-$PROFILE.txt")
echo "packages: $(echo "$PKGS" | tr ',' '\n' | wc -l) listed (base + common + $PROFILE), without Recommends"
echo "root filesystem: $R   (free space: $((FREE_KB / 1024)) MB)"

say "2/8 Host tools (mmdebstrap, qemu-user-static, keyring)"
apt-get update -qq
apt-get install -y -qq mmdebstrap qemu-user-static binfmt-support debian-archive-keyring \
    gpg curl rsync > /dev/null
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || update-binfmts --enable qemu-aarch64 || true
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "arm64 emulation (binfmt qemu-aarch64) is not active"
echo "arm64 emulation active"

say "3/8 Debian signing keys"
KEYS=$(mktemp -d)
cp /usr/share/keyrings/debian-archive-keyring.gpg "$KEYS/"
for k in archive-key-13 archive-key-13-security release-13; do
    if curl -fsS -m 30 "https://ftp-master.debian.org/keys/$k.asc" -o "$KEYS/$k.asc"; then
        gpg --dearmor < "$KEYS/$k.asc" > "$KEYS/$k.gpg" && echo "added $k"
    else
        echo "could not download $k (continuing with the installed keyring)"
    fi
    rm -f "$KEYS/$k.asc"
done

say "4/8 Downloading and installing Debian $SUITE arm64 (10-25 minutes)"
mkdir -p "$REPO/build"
mmdebstrap --architectures=arm64 --variant=minbase \
    --components="$COMPONENTS" --keyring="$KEYS" \
    --aptopt='Apt::Install-Recommends "false"' \
    --include="$PKGS" \
    "$SUITE" "$R" \
    "deb $MIRROR $SUITE $COMPONENTS" \
    "deb $MIRROR $SUITE-updates $COMPONENTS" \
    "deb http://security.debian.org/debian-security $SUITE-security $COMPONENTS" \
    > "$LOG" 2>&1 || { tail -25 "$LOG"; die "mmdebstrap failed, full log $LOG"; }
[ -x "$R/usr/lib/systemd/systemd" ] || die "Debian install failed, see $LOG"
rm -rf "$KEYS"
echo "Debian installed ($(du -sh "$R" | cut -f1))"

say "5/8 Kernel modules ($REL) and AIC8800 firmware"
tar -C "$R/usr" -xf "$KP/modules.tar"
tar -C "$R/usr" -xf "$KP/firmware-aic8800.tar"
chroot "$R" depmod -a "$REL"
grep -q 'extra/aic8800_fdrv.ko' "$R/usr/lib/modules/$REL/modules.dep" || die "modules.dep does not list aic8800_fdrv"
echo "$(find "$R/usr/lib/modules/$REL" -name '*.ko*' | wc -l) modules, firmware $(ls "$R/usr/lib/firmware/aic8800_fw/SDIO/aic8800" | wc -l) files"

say "6/8 Tablet configuration"
mkdir -p "$R/root/p25t-files"
cp "$HERE/p25t-setup.sh" "$R/root/p25t-setup.sh"
cp "$HERE/files/asound.state" "$HERE/files/61-p25t-sensor.hwdb" "$REPO/tools/rear-snap.sh" "$REPO/tools/raw2png.py" "$REPO/tools/set-usb-role.sh" \
   "$PERS/wpa_supplicant-wlan0.conf" "$PERS/authorized_keys" "$R/root/p25t-files/"
[ -f /etc/timezone ] && cp /etc/timezone "$R/root/host-timezone"
if ! chroot "$R" /bin/bash /root/p25t-setup.sh "$TABLET_USER" "$PROFILE" "$HOSTNAME_NEW" 2>&1 | tee -a "$LOG"; then
    die "tablet configuration failed, see $LOG"
fi
rm -rf "$R/root/p25t-setup.sh" "$R/root/host-timezone" "$R/root/p25t-files"

say "7/8 Password for '$TABLET_USER' on the tablet (you type it; it is not stored anywhere else)"
until chroot "$R" passwd "$TABLET_USER"; do echo "Try again."; done

say "8/8 Summary"
N=$(chroot "$R" dpkg-query -W -f='${Package}\n' | wc -l)
{
    echo "profile: $PROFILE"
    echo "hostname: $(cat "$R/etc/hostname")"
    echo "kernel modules: $REL"
    echo "packages installed: $N"
    echo "size: $(du -sh "$R" | cut -f1)"
    echo "built: $(date)"
} | tee "$R.info"
echo "log: $LOG"
echo "BUILD OK ($PROFILE) - next: bash $HERE/install_debian.sh $PROFILE"
