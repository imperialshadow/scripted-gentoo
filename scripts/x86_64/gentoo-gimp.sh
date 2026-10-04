#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install GIMP image editor
set -eo pipefail

echo "============================="
echo " GIMP Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

mkdir -p /etc/portage/package.use
cat > /etc/portage/package.use/gimp << 'EOF'
app-text/poppler cairo
media-libs/babl lcms
media-libs/gegl lcms cairo
EOF

emerge --ask=n media-gfx/gimp

echo
echo "GIMP installed."
