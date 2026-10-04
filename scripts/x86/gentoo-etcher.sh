#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Balena Etcher via zip (latest GitHub release, x86_64 only)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================="
echo " Balena Etcher Install"
echo "============================="
echo

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    echo "NOTE: Balena Etcher has no Linux release for ${ARCH} — skipping."
    exit 0
fi

if ! command -v curl &>/dev/null; then
    emerge --ask=n --noreplace net-misc/curl
fi
if ! command -v unzip &>/dev/null; then
    emerge --ask=n --noreplace app-arch/unzip
fi

echo "Fetching latest Etcher release info..."
RELEASE_JSON=$(curl -sSL https://api.github.com/repos/balena-io/etcher/releases/latest)
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | \
    grep -o "https://[^\"]*balenaEtcher-linux-x64[^\"]*\.zip" | head -1)

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "ERROR: Could not find Linux x64 zip in latest release."
    exit 1
fi

echo "Downloading: ${DOWNLOAD_URL}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
curl -fL --progress-bar -o "${TMPDIR}/etcher.zip" "$DOWNLOAD_URL"

echo "Extracting..."
rm -rf /opt/etcher
unzip -q "${TMPDIR}/etcher.zip" -d /opt/etcher.tmp
mv /opt/etcher.tmp/balenaEtcher-linux-x64 /opt/etcher
rm -rf /opt/etcher.tmp

chmod -R a+rX /opt/etcher/
chmod +x /opt/etcher/balena-etcher
# chrome-sandbox must be owned by root and setuid for Electron to work
chown root:root /opt/etcher/chrome-sandbox
chmod 4755 /opt/etcher/chrome-sandbox

cat > /usr/local/bin/etcher << 'EOF'
#!/bin/bash
exec /opt/etcher/balena-etcher "$@"
EOF
chmod 755 /usr/local/bin/etcher

echo "Installing desktop entry..."
cat > /usr/share/applications/etcher.desktop << 'EOF'
[Desktop Entry]
Name=Balena Etcher
Comment=Flash OS images to SD cards and USB drives
Exec=/opt/etcher/balena-etcher
Icon=media-removable
Terminal=false
Type=Application
Categories=Utility;
EOF

update-desktop-database /usr/share/applications/
xdg-desktop-menu forceupdate 2>/dev/null || true

echo
echo "Balena Etcher installed."
echo "Launch from Applications menu or run: etcher"
