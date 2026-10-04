#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install ClamTK graphical frontend for ClamAV
set -eo pipefail

echo "============================="
echo " ClamTK Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n app-antivirus/clamtk

echo
echo "ClamTK installed."
echo "Note: ClamTK uses the same ClamAV daemon configured by gentoo-clamav.sh."
