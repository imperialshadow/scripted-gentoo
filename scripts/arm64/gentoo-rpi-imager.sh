#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Raspberry Pi Imager via Flatpak (Flathub)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================="
echo " Raspberry Pi Imager Install"
echo "============================="
echo

if ! command -v flatpak &>/dev/null; then
    emerge --ask=n sys-apps/flatpak
fi

if ! flatpak remotes --system | grep -q flathub; then
    flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

flatpak install --system -y flathub org.raspberrypi.rpi-imager

# Desktop integration — symlink so XFCE finds it without relying on
# /etc/profile.d/flatpak.sh being sourced by the display manager
FLATPAK_SHARE=/var/lib/flatpak/exports/share

mkdir -p /usr/local/share/applications
ln -sf "${FLATPAK_SHARE}/applications/org.raspberrypi.rpi-imager.desktop" \
    /usr/local/share/applications/org.raspberrypi.rpi-imager.desktop

ICON_SVG="${FLATPAK_SHARE}/icons/hicolor/scalable/apps/org.raspberrypi.rpi-imager.svg"
ICON_PNG="${FLATPAK_SHARE}/icons/hicolor/256x256/apps/org.raspberrypi.rpi-imager.png"
if [[ -f "$ICON_SVG" ]]; then
    mkdir -p /usr/local/share/icons/hicolor/scalable/apps
    ln -sf "$ICON_SVG" /usr/local/share/icons/hicolor/scalable/apps/org.raspberrypi.rpi-imager.svg
elif [[ -f "$ICON_PNG" ]]; then
    mkdir -p /usr/local/share/icons/hicolor/256x256/apps
    ln -sf "$ICON_PNG" /usr/local/share/icons/hicolor/256x256/apps/org.raspberrypi.rpi-imager.png
fi

update-desktop-database /usr/local/share/applications/ 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

echo
echo "Raspberry Pi Imager installed."
echo "Launch from Applications menu or run: flatpak run org.raspberrypi.rpi-imager"
