#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Winetricks — Wine helper for installing components and workarounds
set -eo pipefail

echo "============================="
echo " Winetricks Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

if ! command -v wine >/dev/null 2>&1 && ! command -v wine64 >/dev/null 2>&1; then
    echo "WARNING: Wine does not appear to be installed."
    echo "Run gentoo-wine.sh first, then rerun this script."
    exit 1
fi

emerge --ask=n app-emulation/winetricks

echo
echo "Winetricks installed."
echo "Run as your normal user: winetricks <component>"
echo "Example: winetricks corefonts vcrun2019"
