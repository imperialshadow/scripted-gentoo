#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install pavucontrol (PulseAudio/PipeWire volume control GUI)
set -eo pipefail

echo "============================="
echo " pavucontrol Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# Install
# =============================================================================

echo "Installing pavucontrol..."
emerge --noreplace media-sound/pavucontrol

echo
echo "pavucontrol installed."
echo "The PulseAudio XFCE plugin 'Open Mixer' button will now work."
