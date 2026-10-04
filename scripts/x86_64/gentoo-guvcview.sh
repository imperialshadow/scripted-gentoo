#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install guvcview webcam viewer (GTK3, XFCE-friendly)
set -eo pipefail

echo "============================="
echo " guvcview Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n --verbose media-video/guvcview

# Ensure the primary user is in the video group for /dev/video* access
PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1)
if [[ -n "$PRIMARY_USER" ]]; then
    usermod -aG video "$PRIMARY_USER"
    echo "Added ${PRIMARY_USER} to the video group (re-login required to take effect)."
fi

echo
echo "guvcview installed."
echo "Launch from your application menu or run: guvcview"
