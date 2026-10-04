#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Installs a per-user watcher that saves/restores window
# positions across a screen lock, working around an AMDGPU/Xorg DPMS bug
# (Xorg.0.log: "drmmode_do_crtc_dpms cannot get last vblank counter"
# during DPMS transitions) that can reflow windows onto one monitor when
# the screens wake/unlock. XFCE + xfce4-screensaver specific (listens for
# org.xfce.ScreenSaver's ActiveChanged dbus signal).
set -eo pipefail

echo "================================="
echo " Window Lock Memory Install"
echo "================================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Dependencies
# =============================================================================

emerge --ask=n --noreplace \
    x11-misc/xdotool \
    x11-misc/wmctrl

# =============================================================================
# Per-user files
# =============================================================================

PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1)
PRIMARY_HOME=$(getent passwd 1000 | cut -d: -f6)

if [[ -z "$PRIMARY_USER" || -z "$PRIMARY_HOME" ]]; then
    echo "ERROR: Could not determine primary user (UID 1000) — aborting."
    exit 1
fi

BIN_DIR="${PRIMARY_HOME}/bin"
UNIT_DIR="${PRIMARY_HOME}/.config/systemd/user"
WANTS_DIR="${UNIT_DIR}/graphical-session.target.wants"

mkdir -p "$BIN_DIR" "$WANTS_DIR"

cat > "${BIN_DIR}/window-monitor-memory.sh" << 'EOF'
#!/bin/bash
# Saves/restores window positions (and maximized state) across a screen
# lock. Works around an AMDGPU/Xorg DPMS bug (Xorg.0.log:
# "drmmode_do_crtc_dpms cannot get last vblank counter" during DPMS
# transitions) that reflows windows onto one monitor when the screens
# wake/unlock.
#
# Maximized windows need special handling: a maximized window's position
# is locked by the WM (moving it is silently ignored), so restoring one
# means unmaximize -> move -> re-maximize, which snaps it back to
# whichever monitor it's now positioned on.
#
# Usage: window-monitor-memory.sh save|restore
set -uo pipefail

STATE_FILE="$HOME/.cache/window-monitor-memory.state"
mkdir -p "$(dirname "$STATE_FILE")"

is_normal_window() {
    # Only snapshot/restore real application windows -- skip panels,
    # docks, and the desktop (xfce4-panel, cairo-dock, xfdesktop, etc.)
    local id="$1"
    xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null | grep -q "_NET_WM_WINDOW_TYPE_NORMAL"
}

is_maximized() {
    local id="$1"
    xprop -id "$id" _NET_WM_STATE 2>/dev/null | grep -q "_NET_WM_STATE_MAXIMIZED_HORZ"
}

save() {
    : > "$STATE_FILE"
    local id x y maxed
    for id in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -oE '0x[0-9a-f]+'); do
        is_normal_window "$id" || continue
        eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)" || continue
        [ -n "${X:-}" ] && [ -n "${Y:-}" ] || continue
        maxed=0
        is_maximized "$id" && maxed=1
        echo "$id $X $Y $maxed" >> "$STATE_FILE"
    done
}

restore() {
    [ -f "$STATE_FILE" ] || return 0
    local id x y maxed
    while read -r id x y maxed; do
        [ -n "$id" ] || continue
        # Skip windows that no longer exist (closed while locked)
        xdotool getwindowgeometry "$id" >/dev/null 2>&1 || continue

        if [ "$maxed" = "1" ]; then
            # Moving a maximized window is ignored by the WM -- drop the
            # maximize state, move it onto the right monitor, then
            # re-maximize (which snaps to whatever monitor it's now on).
            wmctrl -i -r "$id" -b remove,maximized_vert,maximized_horz 2>/dev/null
            wmctrl -i -r "$id" -e "0,$x,$y,-1,-1" 2>/dev/null
            wmctrl -i -r "$id" -b add,maximized_vert,maximized_horz 2>/dev/null
        else
            wmctrl -i -r "$id" -e "0,$x,$y,-1,-1" 2>/dev/null
        fi
    done < "$STATE_FILE"
}

case "${1:-}" in
    save) save ;;
    restore) restore ;;
    *) echo "Usage: $0 save|restore" >&2; exit 1 ;;
esac
EOF

cat > "${BIN_DIR}/window-lock-watcher.sh" << 'EOF'
#!/bin/bash
# Listens for xfce4-screensaver's lock/unlock dbus signal and triggers
# window-monitor-memory.sh save/restore accordingly.
set -uo pipefail

SCRIPT="$HOME/bin/window-monitor-memory.sh"

dbus-monitor --session \
    "type='signal',interface='org.xfce.ScreenSaver',member='ActiveChanged'" |
while read -r line; do
    case "$line" in
        *"boolean true"*)
            "$SCRIPT" save
            ;;
        *"boolean false"*)
            # Give xfwm4 a moment to finish whatever reflow it's going
            # to do on wake before we reassert positions.
            sleep 1
            "$SCRIPT" restore
            ;;
    esac
done
EOF

chmod 755 "${BIN_DIR}/window-monitor-memory.sh" "${BIN_DIR}/window-lock-watcher.sh"

cat > "${UNIT_DIR}/window-lock-watcher.service" << EOF
[Unit]
Description=Save/restore window positions across screen lock
After=graphical-session.target

[Service]
Type=simple
ExecStart=${PRIMARY_HOME}/bin/window-lock-watcher.sh
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

# Enable by symlink directly (systemctl --user enable needs a live user
# session/bus, which won't exist during post-install) -- this is exactly
# what `systemctl --user enable` would create. In theory this alone takes
# effect next login via graphical-session.target, but XFCE's session
# manager never actually signals systemd that a graphical session is
# up -- graphical-session.target sits permanently inactive here even
# though several things nominally WantedBy= it end up running anyway
# (started some other way: D-Bus activation, XDG autostart, etc). Relying
# on the target alone means this unit silently never autostarts. Add an
# XFCE autostart .desktop entry as the real trigger -- confirmed to work
# on this system (cairo-dock, streamdeck-ui already autostart this way).
ln -sf "../window-lock-watcher.service" "${WANTS_DIR}/window-lock-watcher.service"

AUTOSTART_DIR="${PRIMARY_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "${AUTOSTART_DIR}/window-lock-watcher.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Window Lock Watcher
Comment=Starts the window-lock-watcher systemd user service
Exec=systemctl --user start window-lock-watcher.service
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "$BIN_DIR" "${PRIMARY_HOME}/.config/systemd" "$AUTOSTART_DIR"

echo
echo "Window lock memory installed for ${PRIMARY_USER}."
echo "Enabled for next login. To start it now without logging out, run as"
echo "${PRIMARY_USER}: systemctl --user start window-lock-watcher.service"
