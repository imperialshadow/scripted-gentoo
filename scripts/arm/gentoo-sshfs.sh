#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install sshfs — mount remote filesystems over SSH via FUSE
set -eo pipefail

echo "============================="
echo " SSHFS Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n net-fs/sshfs

echo
echo "sshfs installed."
echo "Usage: sshfs user@host:/remote/path /local/mountpoint"
echo "Unmount: fusermount -u /local/mountpoint"
