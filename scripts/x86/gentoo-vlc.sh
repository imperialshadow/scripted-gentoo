#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install VLC media player
set -eo pipefail

echo "============================="
echo " VLC Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# USE flags — VLC's Qt6 GUI requires qml on two KDE framework deps
# =============================================================================

mkdir -p /etc/portage/package.use
cat > /etc/portage/package.use/vlc << 'EOF'
>=dev-qt/qt5compat-6.11.1 qml
>=kde-frameworks/sonnet-6.25.0 qml
EOF

# =============================================================================
# Install
# =============================================================================

echo "Installing VLC..."
emerge --noreplace media-video/vlc

echo
echo "VLC installed."
