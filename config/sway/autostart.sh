# autostart.sh - start sway after the login on tty1 (stage 5, item 5).
# Repo: config/sway/autostart.sh, installed as ~/.config/sway/autostart.sh.
# Read (sourced, not run) by the login shell, through this line at the end
# of ~/.profile (added by tools/install_user_config.sh, or by the build):
#
#     [ -f "$HOME/.config/sway/autostart.sh" ] && . "$HOME/.config/sway/autostart.sh"
#
# sway starts only when all of these hold:
#   - the login is on tty1: tty2-6 and ssh stay plain text consoles
#   - no sway runs in this login already (WAYLAND_DISPLAY is unset)
#   - the file ~/.no-sway does not exist (touch ~/.no-sway stops the
#     autostart, rm ~/.no-sway brings it back)
#   - no key is pressed during the 3 s countdown (a key = text console)
# When sway ends you are back at the tty1 prompt, still logged in:
# "sway" starts it again, "exit" logs out.
# sway's messages go to ~/.local/state/sway.log (the start before that:
# sway.log.old), for problem reports.

if [ -n "${BASH_VERSION:-}" ] && [ "$(tty)" = /dev/tty1 ] \
   && [ -z "${WAYLAND_DISPLAY:-}" ] && [ ! -e "$HOME/.no-sway" ]; then
    echo
    echo "sway starts in 3 s - press any key to stay in the text console."
    if read -r -s -n 1 -t 3 _p25t_key; then
        echo "sway not started. Start it with: sway"
    else
        _p25t_log=$HOME/.local/state/sway.log
        mkdir -p "${_p25t_log%/*}"
        [ -f "$_p25t_log" ] && mv -f "$_p25t_log" "$_p25t_log.old"
        sway > "$_p25t_log" 2>&1
        echo "sway ended (exit code $?). Its messages: $_p25t_log"
        echo "Start it again with: sway      Log out with: exit"
    fi
    unset _p25t_key _p25t_log
fi
