#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Runs INSIDE the new Debian root filesystem (chroot), called by
# build_debian.sh. Configures it for the Teclast P25T.
#
#     p25t-setup.sh <USER> <PROFILE> <HOSTNAME>      PROFILE: console | sway
#
# Files from the build come in /root/p25t-files/ (removed afterwards):
#   asound.state, 61-p25t-sensor.hwdb, rear-snap.sh, raw2png.py, set-usb-role.sh,
#   wpa_supplicant-wlan0.conf, authorized_keys   (personal, from build/personal/)
#   config/   the repo's config/ folder: the user's ~/.config (sway profile)
# Based on p25t-linux debian/p25t-setup.sh plus everything card 1 gained
# later (docs/card1-inventory.org). No service is started here (chroot):
# units are only enabled.
set -euo pipefail
U="$1"; PROFILE="$2"; HOST="$3"
F=/root/p25t-files
case "$PROFILE" in console|sway) ;; *) echo "bad profile $PROFILE"; exit 1 ;; esac

echo "--- hostname, hosts ($HOST)"
echo "$HOST" > /etc/hostname
cat > /etc/hosts <<EOT
127.0.0.1	localhost
127.0.1.1	$HOST
::1		localhost ip6-localhost ip6-loopback
EOT

echo "--- fstab"
mkdir -p /boot/firmware
cat > /etc/fstab <<'EOT'
# Teclast P25T - SD card
LABEL=p25troot  /               ext4  defaults,noatime,errors=remount-ro  0 1
LABEL=P25TBOOT  /boot/firmware  vfat  defaults,noatime,nofail,flush        0 2
EOT

echo "--- apt sources"
# Main archive: Universidad de Zaragoza mirror instead of the generic
# deb.debian.org redirector - noticeably quicker from here, confirmed to
# carry arm64 (not every mirror does; e.g. ftp.cica.es only has
# amd64/i386/all, checked 2026-09-28 - unusable for this tablet).
# security.debian.org is left as-is on purpose: it's not a redirector
# to random mirrors like deb.debian.org, it's Debian's own dedicated
# security CDN, and ordinary mirrors generally don't carry
# debian-security at all.
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<'EOT'
Types: deb
URIs: https://softlibre.unizar.es/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
echo "--- apt: no Recommends (card 1 got exim4 that way)"
cat > /etc/apt/apt.conf.d/90-p25t-no-recommends <<'EOT'
// P25T: install only real dependencies. On card 1 emacs pulled in
// mailutils and a mail server (exim4) through Recommends.
APT::Install-Recommends "false";
EOT

echo "--- user $U"
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm,video,render,input,plugdev,dialout,audio "$U"
passwd -l root >/dev/null

echo "--- time zone"
if [ -s /root/host-timezone ]; then
    TZ_NAME=$(cat /root/host-timezone)
    if [ -e "/usr/share/zoneinfo/$TZ_NAME" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
        echo "$TZ_NAME" > /etc/timezone
        echo "time zone $TZ_NAME"
    fi
fi

echo "--- locales: en_US.UTF-8 (default); en_GB and es_ES as well, for ssh from the PC"
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/; s/^# *\(en_GB.UTF-8 UTF-8\)/\1/; s/^# *\(es_ES.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
sed -i 's/^#AcceptEnv/AcceptEnv/' /etc/ssh/sshd_config

echo "--- keyboard: Spanish and US, Alt+Shift switches (console; sway reads its own config)"
cat > /etc/default/keyboard <<'EOT'
# P25T: Spanish layout first, US second; Alt+Shift switches between them.
XKBMODEL="pc105"
XKBLAYOUT="es,us"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOT

echo "--- console font (large, for the 800x1280 screen)"
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="10x20"/; s/^CODESET=.*/CODESET="Lat15"/' /etc/default/console-setup
# 10x20 (or 11x22) suits the 800x1280 panel; 16x32 is far too big.
# CODESET Lat15 as on card 1 ("guess" would pick Uni2 for en_US.UTF-8).

echo "--- USB gadget: serial console (ACM) + network (NCM)"
cat > /usr/local/sbin/p25t-gadget <<'EOT'
#!/bin/sh
# Set up the USB-C port as a composite USB device: serial console + network.
G=/sys/kernel/config/usb_gadget/p25t
# Host mode (usbhost DTB, see set-usb-role.sh): the port is a USB host and
# there is no device controller (UDC). Without this check the loop below
# waits 20 s for one and fails, and the boot waits with it (2026-10-05).
M=$(tr -d '\0' < /proc/device-tree/usb@fcc00000/dr_mode 2>/dev/null)
[ "$M" = host ] && { echo "USB-C port in host mode: no gadget"; exit 0; }
[ -d $G ] && exit 0
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0100 > $G/bcdDevice
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo "p25t0001"          > $G/strings/0x409/serialnumber
echo "Teclast"           > $G/strings/0x409/manufacturer
echo "P25T Debian"       > $G/strings/0x409/product
mkdir -p $G/configs/c.1/strings/0x409
echo "ACM+NCM" > $G/configs/c.1/strings/0x409/configuration
echo 250 > $G/configs/c.1/MaxPower
mkdir -p $G/functions/acm.usb0 $G/functions/ncm.usb0
# fixed addresses, so the PC always sees the same network device
echo 02:25:54:00:00:01 > $G/functions/ncm.usb0/dev_addr
echo 02:25:54:00:00:02 > $G/functions/ncm.usb0/host_addr
ln -s $G/functions/acm.usb0 $G/configs/c.1/
ln -s $G/functions/ncm.usb0 $G/configs/c.1/
UDC=""
for i in $(seq 1 20); do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "$UDC" ] || { echo "no UDC"; exit 1; }
echo "$UDC" > $G/UDC
echo "gadget bound to $UDC"
EOT
chmod 755 /usr/local/sbin/p25t-gadget
cat > /etc/systemd/system/p25t-gadget.service <<'EOT'
[Unit]
Description=P25T USB gadget (serial console + network)
After=sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/p25t-gadget

[Install]
WantedBy=multi-user.target
EOT
echo "--- network: usb0 (192.168.7.2, route to the PC as backup), wlan0 by DHCP"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/50-usb0.network <<'EOT'
[Match]
Name=usb*

[Network]
Address=192.168.7.2/24
DNS=1.1.1.1
DNS=9.9.9.9
DHCPServer=yes
ConfigureWithoutCarrier=yes

[Route]
Gateway=192.168.7.1
Metric=2000

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
EmitRouter=no
EOT
cat > /etc/systemd/network/60-wlan.network <<'EOT'
[Match]
Name=wlan*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
# keep our hostname: without polkitd, networkd's attempt to take a name
# from the router only logs "Could not set hostname: Access denied"
UseHostname=no
EOT
cat > /etc/systemd/network/10-wlan-kernel-name.link <<'EOT'
[Match]
Type=wlan

[Link]
NamePolicy=kernel
EOT

echo "--- Wi-Fi: AIC8800 driver at boot, network from build/personal/"
mkdir -p /etc/modules-load.d
echo aic8800_fdrv > /etc/modules-load.d/aic8800.conf
install -m 600 -o root -g root "$F/wpa_supplicant-wlan0.conf" /etc/wpa_supplicant/wpa_supplicant-wlan0.conf

echo "--- Bluetooth: attach the AIC8800 (H4 on ttyS1, 1.5 Mbaud)"
cat > /etc/systemd/system/p25t-bluetooth.service <<'EOT'
[Unit]
Description=P25T: attach the AIC8800 Bluetooth (H4 on ttyS1, 1.5 Mbaud, RTS/CTS)
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/btattach -B /dev/ttyS1 -P h4 -S 1500000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

echo "--- volume buttons and speaker mute (same files as debian/p25t-audio-keys.sh)"
cat > /usr/local/sbin/p25t-audio <<'EOT'
#!/bin/sh
# p25t-audio up|down|hp-in|hp-out|sync - called by triggerhappy (see
# /etc/triggerhappy/triggers.d/p25t-audio.conf) and at boot.
C=RK817
case "$1" in
    up)     amixer -q -c "$C" sset Master 5%+ ;;
    down)   amixer -q -c "$C" sset Master 5%- ;;
    hp-in)  amixer -q -c "$C" sset 'Internal Speakers' off ;;
    hp-out) amixer -q -c "$C" sset 'Internal Speakers' on ;;
    sync)   if amixer -c "$C" cget iface=CARD,name='Headphones Jack' | grep -q 'values=on'
            then "$0" hp-in; else "$0" hp-out; fi ;;
    *)      echo "usage: p25t-audio up|down|hp-in|hp-out|sync" >&2; exit 1 ;;
esac
EOT
chmod 755 /usr/local/sbin/p25t-audio
mkdir -p /etc/triggerhappy/triggers.d
cat > /etc/triggerhappy/triggers.d/p25t-audio.conf <<'EOT'
# P25T: volume buttons and headphone jack (see /usr/local/sbin/p25t-audio)
# event	value	command	(1 = press/in, 2 = held, 0 = release/out)
KEY_VOLUMEUP	1	/usr/local/sbin/p25t-audio up
KEY_VOLUMEUP	2	/usr/local/sbin/p25t-audio up
KEY_VOLUMEDOWN	1	/usr/local/sbin/p25t-audio down
KEY_VOLUMEDOWN	2	/usr/local/sbin/p25t-audio down
SW_HEADPHONE_INSERT	1	/usr/local/sbin/p25t-audio hp-in
SW_HEADPHONE_INSERT	0	/usr/local/sbin/p25t-audio hp-out
EOT
mkdir -p /etc/systemd/system/triggerhappy.service.d
cat > /etc/systemd/system/triggerhappy.service.d/p25t.conf <<'EOT'
# P25T: run thd as root (nobody cannot open the sound card) and set the
# speaker switch from the jack state at start (no event if headphones
# were already plugged in at boot).
[Unit]
After=sound.target alsa-restore.service

[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --deviceglob /dev/input/event*
ExecStartPost=/usr/local/sbin/p25t-audio sync
EOT

echo "--- mixer levels from card 1 (speaker, headphones, mic gain 6, capture 255)"
mkdir -p /var/lib/alsa
install -m 644 "$F/asound.state" /var/lib/alsa/asound.state

echo "--- journal: at most 100 MB"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/p25t-size.conf <<'EOT'
[Journal]
SystemMaxUse=100M
EOT

echo "--- camera tools: rear-snap"
install -m 755 "$F/rear-snap.sh" /usr/local/bin/rear-snap
mkdir -p /usr/local/lib/p25t
install -m 755 "$F/raw2png.py" /usr/local/lib/p25t/raw2png.py

echo "--- USB-C role for the next boot: set-usb-role host|normal|status"
# Card 1 has it as ~/set-usb-role.sh; here system-wide. It switches the
# DTB copy on P25TBOOT (-normal.dtb / -usbhost.dtb, put there by
# install_debian.sh) and uses sudo itself, so it is run as the user.
install -m 755 "$F/set-usb-role.sh" /usr/local/bin/set-usb-role

echo "--- accelerometer: P25T mount matrix for iio-sensor-proxy"
# systemd's 60-sensor.hwdb gives every devicetree SC7A20 the PineTab2
# matrix, 90 degrees off here (2026-10-15, tools/accel_probe.sh). This
# file overrides it; see its comments.
install -D -m 644 "$F/61-p25t-sensor.hwdb" /etc/udev/hwdb.d/61-p25t-sensor.hwdb
systemd-hwdb update

echo "--- boot log onto the card (for boots without a USB cable)"
cat > /usr/local/sbin/p25t-bootlog <<'EOT'
#!/bin/sh
# Write a status report onto the card: /boot/firmware/logs/boot-N-debian.txt
D=/boot/firmware/logs
[ -d $D ] || exit 0
N=$(cat $D/bootcount 2>/dev/null || echo 0)
{
    echo "=== $(date)  uptime $(cut -d' ' -f1 /proc/uptime) s"
    echo "=== failed units"; systemctl --failed --no-legend
    echo "=== gadget"; systemctl status --no-pager -n 20 p25t-gadget.service
    for u in /sys/class/udc/*; do echo "$u state: $(cat $u/state)"; done
    echo "=== network"; ip addr
    echo "=== logins"; who
    echo "=== warnings and errors this boot"; journalctl -b -p warning --no-pager
    echo "=== dmesg"; dmesg
} > $D/boot-$N-debian.txt 2>&1
sync
EOT
chmod 755 /usr/local/sbin/p25t-bootlog
cat > /etc/systemd/system/p25t-bootlog.service <<'EOT'
[Unit]
Description=P25T status report onto the SD card

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/p25t-bootlog
EOT
cat > /etc/systemd/system/p25t-bootlog.timer <<'EOT'
[Unit]
Description=P25T status report onto the SD card, 1 min after boot and every 4 min

[Timer]
OnBootSec=60
OnUnitActiveSec=240

[Install]
WantedBy=timers.target
EOT
echo "--- camera: keep the VICAP powered (udev)"
cat > /etc/udev/rules.d/99-p25t-vicap.rules <<'EOT'
# /etc/udev/rules.d/99-p25t-vicap.rules - keep the camera capture block
# (VICAP, fdfe0000) powered. Mainline rkcif pulses the VICAP resets on
# every runtime suspend, which also wipes its IOMMU: the next capture then
# DMAs through a dead IOMMU and the tablet freezes hard (tests 41/43).
# With runtime PM off for this device it never suspends (test_44: three
# captures in a row, IOMMU intact). Remove once the driver is fixed.
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="fdfe0000.video-capture", ATTR{power/control}="on"
EOT
echo "--- ssh key of the PC"
H=$(getent passwd "$U" | cut -d: -f6)
install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
install -m 600 -o "$U" -g "$U" "$F/authorized_keys" "$H/.ssh/authorized_keys"

if [ "$PROFILE" = console ]; then
    echo "--- console profile: consolation without mouse reporting"
    C=/etc/default/consolation
    touch "$C"
    if grep -q '^DAEMON_OPTS=' "$C"; then
        sed -i 's|^DAEMON_OPTS=.*|DAEMON_OPTS="--disable-mouse-reporting"|' "$C"
    else
        echo 'DAEMON_OPTS="--disable-mouse-reporting"' >> "$C"
    fi
    echo "--- console profile: palette dim, backlight 80 (as debian/p25t-console-colors.sh install dim 80)"
    cat > /etc/p25t-vtrgb <<'EOT'
28,170,58,170,58,154,58,176,92,200,100,200,100,180,100,208
28,58,154,122,90,74,154,176,92,100,180,180,130,100,180,208
28,58,58,42,170,154,154,176,92,100,100,100,200,180,180,208
EOT
    cat > /etc/systemd/system/p25t-console-colors.service <<'EOT'
[Unit]
Description=P25T console palette (dim) and backlight (80)
After=systemd-vconsole-setup.service console-setup.service systemd-backlight@backlight:backlight.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/bin/setvtrgb /etc/p25t-vtrgb
ExecStart=/bin/sh -c 'echo 80 > /sys/class/backlight/backlight/brightness'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT
    echo "--- console profile: touch in landscape for console tools"
    cat > /etc/udev/rules.d/99-p25t-touch-landscape.rules <<'EOT'
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="silead_ts", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
EOT
fi
if [ "$PROFILE" = sway ]; then
    # never the console's landscape touch rule here: sway rotates touch itself
    rm -f /etc/udev/rules.d/99-p25t-touch-landscape.rules
    echo "--- sway profile: user config (repo config/ -> ~/.config of $U)"
    # The same files tools/install_user_config.sh puts on a running card:
    # sway (config, bar, rotation, brightness, power key and idle, autostart),
    # foot, fuzzel, GTK dark theme, zathura, xdg-open defaults (mimeapps.list).
    [ -f "$F/config/sway/config" ] || { echo "$F/config/sway/config missing"; exit 1; }
    install -d -m 755 -o "$U" -g "$U" "$H/.config"
    cp -r "$F/config/." "$H/.config/"
    chmod 755 "$H"/.config/sway/*.sh
    chmod 644 "$H/.config/sway/autostart.sh"     # read by the login shell, not run
    chown -R "$U:$U" "$H/.config"
    echo "--- sway profile: sway starts after the login on tty1 (~/.config/sway/autostart.sh)"
    # tty2-6 and ssh stay text; ~/.no-sway or a key during the 3 s countdown skips it.
    [ -f "$H/.profile" ] || install -m 644 -o "$U" -g "$U" /etc/skel/.profile "$H/.profile"
    cat >> "$H/.profile" <<'EOT'

# P25T: start sway after the login on tty1 (see that file)
[ -f "$HOME/.config/sway/autostart.sh" ] && . "$HOME/.config/sway/autostart.sh"
EOT
fi

echo "--- enable services"
# Only getty@tty1 is enabled; logind starts tty2-tty6 on demand
# (NAutoVTs=6), as on any Debian.
systemctl enable systemd-networkd.service systemd-resolved.service \
    ssh.service p25t-gadget.service p25t-bootlog.timer \
    getty@tty1.service wpa_supplicant@wlan0.service \
    bluetooth.service p25t-bluetooth.service triggerhappy.service
[ "$PROFILE" = console ] && systemctl enable p25t-console-colors.service consolation.service
# No login on the USB gadget serial port. When no USB host reads ttyGS0
# (no cable, or host mode), systemd's terminal reset before agetty
# blocks for ever while holding the /dev/console lock; every other
# getty then waits on that lock (blinking cursor, no VT logins) and a
# reboot hangs in PID 1. See "Console: one getty on a dead tty" in
# docs/findings.org. SSH (Wi-Fi or usb0) replaces this console.
systemctl mask serial-getty@ttyGS0.service

echo "--- clean up"
apt-get clean
rm -f /var/lib/apt/lists/*_Packages /var/lib/apt/lists/*_Release /var/lib/apt/lists/*_InRelease
echo "setup done ($PROFILE, $HOST)"
