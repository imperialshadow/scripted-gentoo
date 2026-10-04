#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install HPLIP (HP Linux Imaging and Printing)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================================"
echo " HPLIP — HP Printing & Scanning"
echo "============================================"
echo

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  KW="~amd64" ;;
    i686)    KW="~x86" ;;
    aarch64) KW="~arm64" ;;
    arm*)    KW="~arm" ;;
    *)       KW="~${ARCH}" ;;
esac

mkdir -p /etc/portage/package.accept_keywords /etc/portage/package.use

cat > /etc/portage/package.accept_keywords/hplip << EOF
net-print/hplip ${KW}
net-print/cups ${KW}
EOF

cat > /etc/portage/package.use/hplip << 'EOF'
net-print/hplip X snmp
net-dns/avahi python
EOF

FAILED=0
run() {
    echo "--- $* ---"
    emerge --ask=n --noreplace "$@" || { echo "WARNING: Failed to install $* — skipping"; FAILED=$((FAILED+1)); }
}

run net-print/cups
run net-print/cups-filters
run net-print/hplip
run dev-python/pyqt6

echo
echo "Enabling and starting CUPS..."
systemctl enable cups.service 2>/dev/null && systemctl start cups.service 2>/dev/null \
    || echo "NOTE: Could not start CUPS — start manually after reboot: systemctl enable --now cups"

echo
if (( FAILED > 0 )); then
    echo "${FAILED} package(s) failed — see warnings above."
else
    echo "HPLIP installed."
    echo
    echo "Next steps:"
    echo "  hp-setup          — detect and configure your HP printer"
    echo "  hp-toolbox        — HP Device Manager GUI"
    echo "  http://localhost:631  — CUPS web interface"
fi
