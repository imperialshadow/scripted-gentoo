#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

echo "========================="
echo " Fastfetch Install"
echo "========================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

mkdir -p /etc/portage/package.accept_keywords

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  KEYWORD="~amd64" ;;
    i686)    KEYWORD="~x86" ;;
    aarch64) KEYWORD="~arm64" ;;
    arm*)    KEYWORD="~arm" ;;
    *)       KEYWORD="~${ARCH}" ;;
esac

if ! grep -q 'app-misc/fastfetch' /etc/portage/package.accept_keywords/fastfetch 2>/dev/null; then
    echo "app-misc/fastfetch ${KEYWORD}" >> /etc/portage/package.accept_keywords/fastfetch
fi

emerge --ask=n --verbose app-misc/fastfetch

echo
echo "Fastfetch installed. Run: fastfetch"
