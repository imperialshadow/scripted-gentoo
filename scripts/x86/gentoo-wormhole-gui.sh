#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install wormhole-gui (GTK3 frontend for magic-wormhole)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================================"
echo " Wormhole GUI"
echo "============================================"
echo

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUI_SRC="${SCRIPT_DIR}/../wormhole-gui.py"

if [[ ! -f "$GUI_SRC" ]]; then
    echo "ERROR: wormhole-gui.py not found at ${GUI_SRC}"
    exit 1
fi

echo "Ensuring PyGObject is installed..."
emerge --ask=n --noreplace dev-python/pygobject

echo "Installing wormhole-gui..."
install -Dm 755 "$GUI_SRC" /usr/local/lib/wormhole-gui/wormhole-gui.py

cat > /usr/local/bin/wormhole-gui << 'EOF'
#!/bin/bash
exec python3 /usr/local/lib/wormhole-gui/wormhole-gui.py "$@"
EOF
chmod 755 /usr/local/bin/wormhole-gui

echo "Installing desktop entry..."
cat > /usr/share/applications/wormhole-gui.desktop << 'EOF'
[Desktop Entry]
Name=Wormhole
Comment=Secure peer-to-peer file transfer
Exec=wormhole-gui
Icon=network-transmit-receive
Terminal=false
Type=Application
Categories=Network;FileTransfer;
EOF

echo
echo "Wormhole GUI installed."
echo "Launch: wormhole-gui  (or from your application menu under Network)"
