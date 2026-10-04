#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install magic-wormhole (secure peer-to-peer file transfer)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================================"
echo " Magic Wormhole"
echo "============================================"
echo

VENV=/opt/wormhole

echo "Creating venv at ${VENV}..."
python3 -m venv "$VENV"

echo "Installing magic-wormhole..."
"${VENV}/bin/pip" install --quiet magic-wormhole

echo "Linking wormhole to /usr/local/bin..."
ln -sf "${VENV}/bin/wormhole" /usr/local/bin/wormhole

echo
echo "Magic Wormhole installed: $(wormhole --version 2>/dev/null || echo 'ok')"
echo
echo "Usage:"
echo "  Send:    wormhole send <file>"
echo "  Receive: wormhole receive <code>"
