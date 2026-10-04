#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install GUFW graphical firewall manager (UFW frontend)
set -eo pipefail

echo "============================="
echo " GUFW Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

if ! emerge --ask=n net-firewall/gufw; then
    echo
    echo "NOTE: net-firewall/gufw is not in the portage tree."
    echo "GUFW has been removed from Gentoo's main portage tree."
    echo "UFW (CLI) is already configured by gentoo-ufw.sh."
    exit 0
fi

echo
echo "GUFW installed."
echo "Launch from your application menu, or run: pkexec gufw"
