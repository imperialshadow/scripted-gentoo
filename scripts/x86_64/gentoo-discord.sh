#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Discord via Flatpak (Flathub)
set -eo pipefail

echo "============================="
echo " Discord Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# Flatpak
# =============================================================================

if ! command -v flatpak &>/dev/null; then
    emerge --ask=n sys-apps/flatpak
fi

if ! flatpak remotes --system | grep -q flathub; then
    flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

flatpak install --system -y flathub com.discordapp.Discord

# =============================================================================
# Desktop integration — symlink into /usr/local/share so XFCE finds Discord
# without depending on the display manager sourcing /etc/profile.d/flatpak.sh
# =============================================================================

FLATPAK_SHARE=/var/lib/flatpak/exports/share

mkdir -p /usr/local/share/applications
ln -sf "${FLATPAK_SHARE}/applications/com.discordapp.Discord.desktop" \
    /usr/local/share/applications/com.discordapp.Discord.desktop

ICON_SVG="${FLATPAK_SHARE}/icons/hicolor/scalable/apps/com.discordapp.Discord.svg"
ICON_PNG="${FLATPAK_SHARE}/icons/hicolor/256x256/apps/com.discordapp.Discord.png"
if [[ -f "$ICON_SVG" ]]; then
    mkdir -p /usr/local/share/icons/hicolor/scalable/apps
    ln -sf "$ICON_SVG" /usr/local/share/icons/hicolor/scalable/apps/com.discordapp.Discord.svg
elif [[ -f "$ICON_PNG" ]]; then
    mkdir -p /usr/local/share/icons/hicolor/256x256/apps
    ln -sf "$ICON_PNG" /usr/local/share/icons/hicolor/256x256/apps/com.discordapp.Discord.png
fi

update-desktop-database /usr/local/share/applications/ 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

# =============================================================================
# UFW — outgoing ports for Discord
#
# TCP 80 and 443 are already opened by gentoo-ufw.sh (API, CDN, fallback).
# UDP 3478 is already opened by gentoo-steam.sh (STUN — shared with Steam SDR).
#   3479/udp         — Discord STUN secondary port
#   50000-65535/udp  — Discord RTC voice and video media
# =============================================================================

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow out proto udp to any port 3479          comment 'Discord STUN'
    ufw allow out proto udp to any port 50000:65535   comment 'Discord RTC'
    echo "UFW: Discord ports opened."
else
    echo "UFW not active — skipping firewall rules."
fi

echo
echo "Discord installed."
echo "Launch from Applications menu or run: flatpak run com.discordapp.Discord"
