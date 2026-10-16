#!/bin/bash
# install_user_config.sh - install the repo's sway and foot config for the
# current user on the tablet. Run as the normal user (no sudo), with sway
# running on the tablet:
#
#     bash install_user_config.sh <CONFIG-DIR>
#
# <CONFIG-DIR> is a copy of the repo's config/ folder (scp -r). Existing
# files are kept as <file>.pre-<date>.
#
# It also adds one line to the login profile (~/.profile, or ~/.bash_profile
# if that exists) that runs ~/.config/sway/autostart.sh: sway then starts by
# itself after the login on tty1 (stage 5, item 5). Added once, only after
# sway accepted the new config.
#
# The sway config is checked by reloading the running sway: if sway reports
# an error, the previous files are put back and sway reloaded again.
# (sway --validate is no use here: sway 1.10 still opens a seat for it,
# which an ssh session cannot - found 2026-10-15.)
set -eu
SRC=${1:?usage: bash install_user_config.sh CONFIG-DIR}
STAMP=$(date +%Y%m%d-%H%M%S)
die() { echo "ABORT: $*" >&2; exit 1; }

[ -f "$SRC/sway/config" ] || die "$SRC/sway/config missing"
[ -f "$SRC/foot/foot.ini" ] || die "$SRC/foot/foot.ini missing"
[ -f "$SRC/sway/autorotate.sh" ] || die "$SRC/sway/autorotate.sh missing"
[ -f "$SRC/fuzzel/fuzzel.ini" ] || die "$SRC/fuzzel/fuzzel.ini missing"
[ -f "$SRC/sway/status.sh" ] || die "$SRC/sway/status.sh missing"
[ -f "$SRC/sway/brightness.sh" ] || die "$SRC/sway/brightness.sh missing"
[ -f "$SRC/sway/powerkey.sh" ] || die "$SRC/sway/powerkey.sh missing"
[ -f "$SRC/gtk-3.0/settings.ini" ] || die "$SRC/gtk-3.0/settings.ini missing"
[ -f "$SRC/zathura/zathurarc" ] || die "$SRC/zathura/zathurarc missing"
[ -f "$SRC/mimeapps.list" ] || die "$SRC/mimeapps.list missing"
[ -f "$SRC/sway/autostart.sh" ] || die "$SRC/sway/autostart.sh missing"

SOCK=""
for f in /run/user/"$(id -u)"/sway-ipc.*.sock; do
    [ -S "$f" ] && SOCK=$f
done
[ -n "$SOCK" ] || die "sway is not running on the tablet - start it first (it is needed to check the config)"
export SWAYSOCK=$SOCK

UNDO=()   # lines "target|backup" (backup "-" = there was no file before)
put() {   # put <source> <target> [<mode>]
    mkdir -p "$(dirname "$2")"
    if [ -f "$2" ]; then
        if cmp -s "$1" "$2"; then echo "unchanged: $2"; return; fi
        cp -p "$2" "$2.pre-$STAMP"
        UNDO+=("$2|$2.pre-$STAMP")
        echo "old copy kept: $2.pre-$STAMP"
    else
        UNDO+=("$2|-")
    fi
    cp "$1" "$2"
    [ -n "${3:-}" ] && chmod "$3" "$2"
    cmp -s "$1" "$2" || die "$2 differs from $1 after copying"
    echo "installed: $2  $(sha256sum "$2" | cut -c1-12)"
}
put "$SRC/sway/config"   "$HOME/.config/sway/config"
put "$SRC/foot/foot.ini" "$HOME/.config/foot/foot.ini"
put "$SRC/sway/autorotate.sh" "$HOME/.config/sway/autorotate.sh" 755
put "$SRC/fuzzel/fuzzel.ini" "$HOME/.config/fuzzel/fuzzel.ini"
put "$SRC/sway/status.sh" "$HOME/.config/sway/status.sh" 755
put "$SRC/sway/brightness.sh" "$HOME/.config/sway/brightness.sh" 755
put "$SRC/sway/powerkey.sh" "$HOME/.config/sway/powerkey.sh" 755
put "$SRC/gtk-3.0/settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
put "$SRC/zathura/zathurarc" "$HOME/.config/zathura/zathurarc"
put "$SRC/mimeapps.list" "$HOME/.config/mimeapps.list"
put "$SRC/sway/autostart.sh" "$HOME/.config/sway/autostart.sh" 644

# The line that runs autostart.sh at login. bash reads the first of
# ~/.bash_profile, ~/.bash_login, ~/.profile that exists.
add_autostart_line() {
    local p="" f
    for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        [ -f "$f" ] && { p=$f; break; }
    done
    if [ -z "$p" ]; then
        p=$HOME/.profile
        cp /etc/skel/.profile "$p"
        echo "created: $p (Debian's default)"
    fi
    if grep -qF '.config/sway/autostart.sh' "$p"; then
        echo "unchanged: $p (autostart line there already)"
        return
    fi
    cp -p "$p" "$p.pre-$STAMP"
    cat >> "$p" <<'EOT'

# P25T: start sway after the login on tty1 (see that file)
[ -f "$HOME/.config/sway/autostart.sh" ] && . "$HOME/.config/sway/autostart.sh"
EOT
    echo "autostart line added: $p  (old copy: $p.pre-$STAMP)"
}

echo "--- reloading sway (this checks the new config)"
if swaymsg reload; then
    echo "OK: sway reloaded with the new config"
    add_autostart_line
    echo "new windows (foot, fuzzel, zathura, GTK programs) use the new settings; open ones keep the old"
    echo "lines with exec (brightness at start, swayidle, power key guard) start at the next sway start"
    echo "sway starts by itself from the next login on tty1 (touch ~/.no-sway to stop that)"
    exit 0
fi

echo "sway reported an error - putting the previous files back" >&2
for u in "${UNDO[@]}"; do
    t=${u%%|*}; b=${u#*|}
    if [ "$b" = "-" ]; then rm -f "$t"; echo "removed: $t" >&2
    else cp -p "$b" "$t"; echo "restored: $t" >&2
    fi
done
swaymsg reload >/dev/null 2>&1 || true
die "new config not installed (see sway's message above)"
