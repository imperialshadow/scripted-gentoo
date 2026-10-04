#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/theme.conf << 'EOF'
[Theme]
Current=gentoo

[General]
DefaultSession=xfce.desktop

[Wayland]
SessionDir=
EOF

echo "SDDM session config written."
echo "DefaultSession=xfce.desktop, Wayland sessions hidden."
echo "Restart SDDM to apply: systemctl restart sddm"
