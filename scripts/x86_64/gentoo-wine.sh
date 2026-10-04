#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Wine for running Windows applications
set -eo pipefail

echo "============================="
echo " Wine Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Wine USE flags
# X, opengl, vulkan: graphics support
# alsa, pulseaudio: audio support
# fontconfig: font rendering
# Note: staging patches are only available via app-emulation/wine-staging
# =============================================================================

mkdir -p /etc/portage/package.use
tee /etc/portage/package.use/wine > /dev/null << 'EOF'
app-emulation/wine-vanilla X opengl vulkan alsa pulseaudio fontconfig wow64 -abi_x86_32
media-libs/libsdl2 gles2
EOF

# wine-vanilla is in ~amd64
mkdir -p /etc/portage/package.accept_keywords
if ! grep -q 'app-emulation/wine-vanilla' /etc/portage/package.accept_keywords/wine 2>/dev/null; then
    echo 'app-emulation/wine-vanilla ~amd64' >> /etc/portage/package.accept_keywords/wine
fi

emerge --ask=n app-emulation/wine-vanilla

echo
echo "Wine installed with WoW64 support."
echo "wow64 enables 32-bit Windows application support without 32-bit system libraries."
echo "Test with: wine --version"
