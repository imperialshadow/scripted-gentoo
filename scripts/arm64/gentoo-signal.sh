#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Signal Desktop private messenger via GURU overlay
set -eo pipefail

echo "============================="
echo " Signal Desktop Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Signal Desktop is in the GURU community overlay
# =============================================================================

# git is required for syncing git-type overlays like GURU
emerge --ask=n app-eselect/eselect-repository dev-vcs/git

if [[ ! -d /var/db/repos/guru ]]; then
    eselect repository add guru git https://github.com/gentoo-mirror/guru.git
fi

emerge --sync guru

# signal-desktop-bin is in ~amd64
mkdir -p /etc/portage/package.accept_keywords
if ! grep -q 'net-im/signal-desktop-bin' /etc/portage/package.accept_keywords/signal 2>/dev/null; then
    echo 'net-im/signal-desktop-bin ~amd64' >> /etc/portage/package.accept_keywords/signal
fi

emerge --ask=n net-im/signal-desktop-bin

echo
echo "Signal Desktop installed."
