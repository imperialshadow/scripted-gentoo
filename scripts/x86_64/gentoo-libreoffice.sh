#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install LibreOffice office suite (built from source)
set -eo pipefail

echo "============================="
echo " LibreOffice Install"
echo "============================="
echo
echo "NOTE: LibreOffice compiles from source. This will take a very long time."
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

mkdir -p /etc/portage/package.accept_keywords
if ! grep -q 'app-office/libreoffice' /etc/portage/package.accept_keywords/libreoffice 2>/dev/null; then
    echo 'app-office/libreoffice ~amd64' >> /etc/portage/package.accept_keywords/libreoffice
fi

mkdir -p /etc/portage/package.use
cat > /etc/portage/package.use/libreoffice << 'EOF'
sys-libs/zlib minizip
dev-libs/xmlsec nss
media-libs/harfbuzz icu
EOF

emerge --ask=n app-office/libreoffice

echo
echo "LibreOffice installed."
