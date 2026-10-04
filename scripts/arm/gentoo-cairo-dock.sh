#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Cairo-Dock desktop dock with plugin suite
set -eo pipefail

echo "============================="
echo " Cairo-Dock Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Overlay setup — Cairo-Dock is not in the main portage tree.
# pingwho-overlay provides cairo-dock 3.5.1 for amd64/x86/arm64.
# =============================================================================

emerge --ask=n --noreplace app-eselect/eselect-repository dev-vcs/git

if ! eselect repository list -i | grep -q 'pingwho-overlay'; then
    eselect repository enable pingwho-overlay
fi
emaint sync -r pingwho-overlay

# =============================================================================
# Portage configuration
# =============================================================================

mkdir -p /etc/portage/package.accept_keywords

# Packages are keyworded ~amd64
cat > /etc/portage/package.accept_keywords/cairo-dock << 'EOF'
x11-misc/cairo-dock ~amd64
x11-plugins/cairo-dock-plugins ~amd64
EOF

# =============================================================================
# Installation
# =============================================================================

emerge --ask=n --verbose \
    x11-misc/cairo-dock \
    x11-plugins/cairo-dock-plugins

# =============================================================================
# Autostart — write per-user XDG autostart entry
# =============================================================================

PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1)
PRIMARY_HOME=$(getent passwd 1000 | cut -d: -f6)

if [[ -n "$PRIMARY_USER" && -n "$PRIMARY_HOME" ]]; then
    AUTOSTART_DIR="${PRIMARY_HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/cairo-dock.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Cairo Dock
Comment=Cairo Dock desktop dock
Exec=cairo-dock --opengl -f
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "$AUTOSTART_DIR"
    echo "Autostart entry written for ${PRIMARY_USER}: ${AUTOSTART_DIR}/cairo-dock.desktop"
else
    echo "WARNING: Could not determine primary user (UID 1000) — autostart not configured."
    echo "         Manually create ~/.config/autostart/cairo-dock.desktop with:"
    echo "         Exec=cairo-dock --opengl -f"
fi

echo
echo "Cairo-Dock installed."
echo "It will auto-start on next login with OpenGL enabled."
