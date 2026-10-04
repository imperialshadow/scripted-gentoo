#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install parted command-line disk partitioning tool
set -eo pipefail

echo "============================="
echo " Parted Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n sys-block/parted

echo
echo "parted installed."
echo "Usage: parted /dev/sdX"
