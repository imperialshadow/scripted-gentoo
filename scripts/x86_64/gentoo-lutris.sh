#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Lutris gaming platform with Vulkan/DXVK support for
# Windows games via Wine
set -eo pipefail

echo "============================="
echo " Lutris Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Lutris and a few of its optional-but-commonly-needed companions are
# ~amd64 (~x86 too, but this project's Lutris support is x86_64-only --
# Lutris has no arm/arm64 keyword at all, not even unstable, so it can't be
# installed there regardless of accept_keywords).
#
#   games-util/lutris    the launcher itself
#   dev-util/vulkan-tools vulkaninfo/vkcube -- verifies the GPU's Vulkan
#                          driver is actually working, which DXVK depends on
#   gui-wm/gamescope      Valve's micro-compositor; optional per-game launch
#                          wrapper for fullscreen/resolution handling
#
# app-emulation/dxvk has a stable (non-tilde) version already, so it needs
# no keyword acceptance. virtual/wine resolves via the wine-vanilla
# ~amd64 acceptance gentoo-wine.sh already sets up.
#
# dev-python/pypresence (Lutris's optional Discord Rich Presence support)
# and dev-python/moddb (Lutris's ModDB integration) only have ~amd64
# builds for the python3_14 slot -- without accepting both, portage can't
# use current Lutris releases (0.5.20+) and silently falls back to the
# old 0.5.19 release, which only supports python3_12/13 and fails
# REQUIRED_USE on a python3_14-only system.
# =============================================================================

mkdir -p /etc/portage/package.accept_keywords
cat > /etc/portage/package.accept_keywords/lutris << 'EOF'
games-util/lutris ~amd64
dev-util/vulkan-tools ~amd64
gui-wm/gamescope ~amd64
dev-python/pypresence ~amd64
dev-python/moddb ~amd64
EOF

emerge --ask=n --verbose \
    games-util/lutris \
    virtual/wine \
    app-emulation/dxvk \
    dev-util/vulkan-tools \
    gui-wm/gamescope

echo
echo "=============================="
echo " Verifying the setup"
echo "=============================="

echo "Vulkan driver check (DXVK/gamescope both need this working):"
if vulkaninfo --summary >/tmp/lutris-vulkaninfo.log 2>&1; then
    grep -A3 "deviceName" /tmp/lutris-vulkaninfo.log | head -8
else
    echo "WARNING: vulkaninfo failed -- see /tmp/lutris-vulkaninfo.log"
    echo "Games needing DXVK or gamescope won't run correctly until this is fixed."
fi
rm -f /tmp/lutris-vulkaninfo.log

echo
echo "Wine check:"
wine --version 2>&1 || echo "WARNING: wine --version failed"

echo
echo "Lutris installed."
echo "Run as a regular (non-root) user: lutris"
echo "First launch downloads Lutris's own runtime/wine-ge builds — this can"
echo "take a while depending on connection speed."
