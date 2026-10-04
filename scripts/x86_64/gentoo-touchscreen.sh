#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
#
# gentoo-touchscreen.sh — must be run as root
#
# Maps a touchscreen input device (any brand) to a specific monitor output,
# for an XFCE desktop session on Gentoo. The mapping is persisted in the
# target user's xfconf "pointers" channel, the same mechanism XFCE itself
# uses to remember per-device pointer settings (acceleration, handedness,
# etc). Because xfsettingsd re-applies that channel whenever it sees the
# device (login, reboot, or a real USB disconnect/reconnect — e.g. a
# touchscreen that drops its USB connection when the monitor sleeps), the
# mapping survives all of those without any extra udev rules or services.
#
# Requires an active XFCE (xfsettingsd) session for the target user, and a
# systemd system (loginctl / systemctl --user) to discover that session's
# DISPLAY and XAUTHORITY.
#
# Usage:
#   gentoo-touchscreen.sh [username]
#
# If no username is given, the script auto-detects the single active X11
# login session. If there is more than one, it asks you to name one.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

if ! command -v loginctl >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    echo "This script requires systemd (loginctl/systemctl) to locate the target" >&2
    echo "user's X session. It won't work on an OpenRC/eudev-only system." >&2
    exit 1
fi

# ---- Resolve target user --------------------------------------------------

TARGET_USER="${1:-}"

if [ -z "$TARGET_USER" ]; then
    CANDIDATES=()
    while read -r session_id; do
        [ -z "$session_id" ] && continue
        type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)
        state=$(loginctl show-session "$session_id" -p State --value 2>/dev/null || true)
        name=$(loginctl show-session "$session_id" -p Name --value 2>/dev/null || true)
        if [ "$type" = "x11" ] && [ "$state" = "active" ] && [ -n "$name" ]; then
            CANDIDATES+=("$name")
        fi
    done < <(loginctl list-sessions --no-legend | awk '{print $1}')

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        echo "No active X11 session found. Pass the username explicitly:" >&2
        echo "  $0 <username>" >&2
        exit 1
    elif [ "${#CANDIDATES[@]}" -gt 1 ]; then
        echo "Multiple active X11 sessions found: ${CANDIDATES[*]}" >&2
        echo "Pass the username explicitly:" >&2
        echo "  $0 <username>" >&2
        exit 1
    fi
    TARGET_USER="${CANDIDATES[0]}"
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' does not exist." >&2
    exit 1
fi

echo "Target user: $TARGET_USER"

# ---- Ensure dependencies ---------------------------------------------------

declare -A PKG_FOR=(
    [xrandr]="x11-apps/xrandr"
    [xinput]="x11-apps/xinput"
    [xfconf-query]="xfce-base/xfconf"
)

MISSING_PKGS=()
for bin in "${!PKG_FOR[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        MISSING_PKGS+=("${PKG_FOR[$bin]}")
    fi
done

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    echo "Installing missing dependencies: ${MISSING_PKGS[*]}"
    emerge --oneshot "${MISSING_PKGS[@]}"
fi

if ! runuser -u "$TARGET_USER" -- pgrep -x xfsettingsd >/dev/null 2>&1; then
    echo "xfsettingsd is not running for $TARGET_USER." >&2
    echo "This script requires an active XFCE session for that user." >&2
    exit 1
fi

# ---- Discover the target user's X session environment ---------------------

USER_UID=$(id -u "$TARGET_USER")
export XDG_RUNTIME_DIR="/run/user/$USER_UID"

ENV_OUTPUT=$(runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user show-environment 2>/dev/null || true)
X_DISPLAY=$(echo "$ENV_OUTPUT" | sed -n 's/^DISPLAY=//p')
X_XAUTHORITY=$(echo "$ENV_OUTPUT" | sed -n 's/^XAUTHORITY=//p')

if [ -z "$X_DISPLAY" ]; then
    echo "Could not determine DISPLAY for $TARGET_USER's session." >&2
    exit 1
fi

run_as_user() {
    runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY="$X_DISPLAY" XAUTHORITY="$X_XAUTHORITY" "$@"
}

# ---- Detect touchscreen input devices (brand-agnostic) --------------------

declare -A TOUCH_DEVICES  # event path -> udev NAME

for evpath in /dev/input/event*; do
    [ -e "$evpath" ] || continue
    props=$(udevadm info --query=property --name="$evpath" 2>/dev/null || true)
    if echo "$props" | grep -q '^ID_INPUT_TOUCHSCREEN=1'; then
        evname=$(basename "$evpath")
        name=$(cat "/sys/class/input/$evname/device/name" 2>/dev/null || true)
        [ -n "$name" ] && TOUCH_DEVICES["$evpath"]="$name"
    fi
done

if [ "${#TOUCH_DEVICES[@]}" -eq 0 ]; then
    echo "No touchscreen devices detected (checked udev ID_INPUT_TOUCHSCREEN property)." >&2
    exit 1
fi

echo
echo "Detected touchscreen device(s):"
declare -A INDEX_TO_EVPATH
i=1
while read -r evpath; do
    echo "  [$i] ${TOUCH_DEVICES[$evpath]}  ($evpath)"
    INDEX_TO_EVPATH[$i]="$evpath"
    i=$((i + 1))
done < <(printf '%s\n' "${!TOUCH_DEVICES[@]}" | sort)

read -rp "Select touchscreen to configure [1-$((i - 1))]: " SEL
SELECTED_EVPATH="${INDEX_TO_EVPATH[$SEL]:-}"
if [ -z "$SELECTED_EVPATH" ]; then
    echo "Invalid selection." >&2
    exit 1
fi
SELECTED_NAME="${TOUCH_DEVICES[$SELECTED_EVPATH]}"
echo "Selected: $SELECTED_NAME"

# Resolve the device as X/xinput sees it (should match the udev NAME).
XINPUT_NAME=$(run_as_user xinput list --name-only | grep -F "$SELECTED_NAME" | head -1 || true)
if [ -z "$XINPUT_NAME" ]; then
    echo "Could not find '$SELECTED_NAME' in xinput's device list." >&2
    echo "Is it attached to this X server?" >&2
    exit 1
fi

# ---- List outputs ----------------------------------------------------------

echo
echo "Detected display outputs:"
mapfile -t OUTPUTS < <(run_as_user xrandr --listmonitors | awk 'NR>1{print $NF}')

if [ "${#OUTPUTS[@]}" -eq 0 ]; then
    echo "No display outputs detected via xrandr." >&2
    exit 1
fi

j=1
for out in "${OUTPUTS[@]}"; do
    echo "  [$j] $out"
    j=$((j + 1))
done

read -rp "Select the output this touchscreen should map to [1-$((j - 1))]: " OSEL
SELECTED_OUTPUT="${OUTPUTS[$((OSEL - 1))]:-}"
if [ -z "$SELECTED_OUTPUT" ]; then
    echo "Invalid selection." >&2
    exit 1
fi
echo "Selected output: $SELECTED_OUTPUT"

echo
read -rp "Map '$XINPUT_NAME' to '$SELECTED_OUTPUT' for user $TARGET_USER? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ---- Apply live mapping and read back the resulting matrix -----------------

run_as_user xinput map-to-output "$XINPUT_NAME" "$SELECTED_OUTPUT"

MATRIX_STR=$(run_as_user xinput list-props "$XINPUT_NAME" | grep "Coordinate Transformation Matrix" | sed -E 's/.*\):[[:space:]]*//')
if [ -z "$MATRIX_STR" ]; then
    echo "Failed to read back the coordinate transformation matrix." >&2
    exit 1
fi

read -r -a MATRIX <<<"$(echo "$MATRIX_STR" | tr -d ',')"
if [ "${#MATRIX[@]}" -ne 9 ]; then
    echo "Unexpected matrix format: $MATRIX_STR" >&2
    exit 1
fi

echo "Computed transform: ${MATRIX[*]}"

# ---- Persist via xfconf so xfsettingsd re-applies it on hotplug -----------
#
# xfsettingsd stores per-device pointer settings under a sanitized version
# of the device's X name: non-alphanumeric/underscore characters are
# dropped, then runs of spaces become a single underscore (verified against
# entries xfsettingsd itself already creates, e.g. Acceleration/Threshold).

MANGLED=$(echo "$XINPUT_NAME" | sed -E 's/[^A-Za-z0-9_ ]//g; s/ +/_/g')
PROPERTY="/${MANGLED}/Properties/Coordinate_Transformation_Matrix"

if run_as_user xfconf-query -c pointers -l 2>/dev/null | grep -q "^/${MANGLED}/"; then
    echo "Confirmed existing xfconf entry for this device at /${MANGLED}/"
else
    echo "Warning: no existing xfconf entry found at /${MANGLED}/ — proceeding" >&2
    echo "with the derived name anyway; verify with 'xfconf-query -c pointers -l'" >&2
    echo "afterward if the mapping doesn't survive a reconnect." >&2
fi

XFCONF_ARGS=(-c pointers -p "$PROPERTY" -n -a)
for v in "${MATRIX[@]}"; do
    XFCONF_ARGS+=(-t double -s "$v")
done

run_as_user xfconf-query "${XFCONF_ARGS[@]}"

echo
echo "Done. '$XINPUT_NAME' is mapped to $SELECTED_OUTPUT and persisted in the"
echo "xfconf 'pointers' channel for $TARGET_USER. xfsettingsd will reapply it"
echo "on login, reboot, and USB hotplug/reconnect."
echo
echo "Now physically touch the target screen to confirm it tracks correctly"
echo "before considering this done."
