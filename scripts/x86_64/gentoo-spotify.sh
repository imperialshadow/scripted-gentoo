#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Spotify natively via Portage (media-sound/spotify)
set -eo pipefail

echo "============================="
echo " Spotify Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# media-sound/spotify repackages Spotify's own official .deb (patchelf'd for
# Gentoo's library names) and runs unsandboxed. The Flatpak build
# (com.spotify.Client via Flathub) is NOT officially supported by Spotify --
# only .deb and Snap are -- and its bundled CEF runtime has a known,
# version-matched "BootstrapTimeoutError" bug (confirmed on Spotify's own
# community forum) where the content renderer never initializes and the
# window is stuck on a blank loading splash with no retry. Updating the
# Flatpak app and its runtime to the latest available build did not fix it.
# This native package sidesteps the Flatpak sandbox entirely.
# =============================================================================

# Remove the old broken Flatpak install and its desktop-integration symlinks
# if present, so there's no stale/duplicate launcher left behind.
if command -v flatpak &>/dev/null && flatpak list --app 2>/dev/null | grep -q com.spotify.Client; then
    echo "Removing old Flatpak Spotify install..."
    flatpak uninstall --system -y com.spotify.Client 2>/dev/null || true
fi
rm -f /usr/local/share/applications/com.spotify.Client.desktop
rm -f /usr/local/share/icons/hicolor/scalable/apps/com.spotify.Client.svg
rm -f /usr/local/share/icons/hicolor/256x256/apps/com.spotify.Client.png

mkdir -p /etc/portage/package.use
if ! grep -q "^media-sound/spotify" /etc/portage/package.use/spotify 2>/dev/null; then
    echo "media-sound/spotify libnotify local-playback pulseaudio" >> /etc/portage/package.use/spotify
fi

emerge --ask=n media-sound/spotify

update-desktop-database /usr/share/applications/ 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

# =============================================================================
# UFW — outgoing ports for Spotify
#
# TCP 80 and 443 are already opened by gentoo-ufw.sh (Spotify uses them for
# auth API and as a streaming fallback).
#   4070/tcp+udp — Spotify streaming protocol
#   57621/udp    — Spotify Connect local device discovery
# =============================================================================

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow out proto tcp to any port 4070  comment 'Spotify'
    ufw allow out proto udp to any port 4070  comment 'Spotify'
    ufw allow out proto udp to any port 57621 comment 'Spotify Connect'
    echo "UFW: Spotify ports opened."
else
    echo "UFW not active — skipping firewall rules."
fi

echo
echo "Spotify installed."
echo "Launch from Applications menu or run: spotify"
