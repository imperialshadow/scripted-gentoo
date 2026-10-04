#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install qBittorrent
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================="
echo " qBittorrent Install"
echo "============================="
echo

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  KW="~amd64" ;;
    i686)    KW="~x86" ;;
    aarch64) KW="~arm64" ;;
    arm*)    KW="~arm" ;;
    *)       KW="~${ARCH}" ;;
esac

mkdir -p /etc/portage/package.accept_keywords

cat > /etc/portage/package.accept_keywords/qbittorrent << EOF
net-p2p/qbittorrent ${KW}
EOF

FAILED=0
run() {
    echo "--- $* ---"
    emerge --ask=n --noreplace "$@" || { echo "WARNING: Failed to install $* — skipping"; FAILED=$((FAILED+1)); }
}

run net-p2p/qbittorrent

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow in proto tcp to any port 6881:6889  comment 'qBittorrent incoming'
    ufw allow in proto udp to any port 6881:6889  comment 'qBittorrent DHT/uTP'
    echo "UFW: qBittorrent ports opened."
else
    echo "UFW not active — skipping firewall rules."
fi

echo
if (( FAILED > 0 )); then
    echo "${FAILED} package(s) failed — see warnings above."
else
    echo "qBittorrent installed."
    echo "Launch: qbittorrent"
fi
