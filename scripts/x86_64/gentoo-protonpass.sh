#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

echo "============================="
echo " Proton Pass Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

emerge --ask=n --verbose sys-apps/flatpak

# Add Flathub system-wide remote if not already present
if ! flatpak remotes --system | grep -q flathub; then
    flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

flatpak install --system -y flathub me.proton.Pass

# Symlink .desktop file and icon into /usr/local/share so XFCE finds Proton Pass
# without depending on the display manager sourcing /etc/profile.d/flatpak.sh
# (which would otherwise add /var/lib/flatpak/exports/share to XDG_DATA_DIRS).
FLATPAK_SHARE=/var/lib/flatpak/exports/share

mkdir -p /usr/local/share/applications
ln -sf "${FLATPAK_SHARE}/applications/me.proton.Pass.desktop" \
    /usr/local/share/applications/me.proton.Pass.desktop

mkdir -p /usr/local/share/icons/hicolor/scalable/apps
ln -sf "${FLATPAK_SHARE}/icons/hicolor/scalable/apps/me.proton.Pass.svg" \
    /usr/local/share/icons/hicolor/scalable/apps/me.proton.Pass.svg

update-desktop-database /usr/local/share/applications/ 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

echo
echo "Proton Pass installed."
echo "Launch from Applications > Utility > Proton Pass, or run: flatpak run me.proton.Pass"
