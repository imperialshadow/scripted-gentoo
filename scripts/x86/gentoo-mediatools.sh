#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install HandBrake (GUI, GStreamer) and MakeMKV (GUI, unmasked
# via ~x86 + EULA acceptance) for disc ripping/transcoding
set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

add_line() {
    local file="$1" line="$2"
    mkdir -p "$(dirname "$file")"
    grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

echo "==> Unmasking HandBrake (~x86 keyword -- only amd64 is stable upstream)"
add_line /etc/portage/package.accept_keywords/handbrake "media-video/handbrake ~x86"

echo "==> Configuring HandBrake USE flags (gui, gstreamer)"
add_line /etc/portage/package.use/handbrake "media-video/handbrake gui"
add_line /etc/portage/package.use/handbrake ">=gui-libs/gtk-4.18.6-r1 gstreamer"

echo "==> Building HandBrake with GUI support"
emerge --changed-use media-video/handbrake

echo "==> Unmasking MakeMKV (~x86 keyword + EULA license acceptance)"
add_line /etc/portage/package.accept_keywords/makemkv "media-video/makemkv ~x86"
add_line /etc/portage/package.license/makemkv "media-video/makemkv MakeMKV-EULA"

MAKEMKV_EBUILD=$(find /var/db/repos/gentoo/media-video/makemkv -name '*.ebuild' | sort -V | tail -1)
MAKEMKV_PV=$(basename "$MAKEMKV_EBUILD" .ebuild | sed 's/^makemkv-//')
DISTDIR=$(portageq distdir)

echo "==> Fetching MakeMKV ${MAKEMKV_PV} sources over HTTPS (upstream's http:// URL is blocked by Cloudflare with a 403)"
for pkg in "makemkv-oss-${MAKEMKV_PV}" "makemkv-bin-${MAKEMKV_PV}"; do
    dest="${DISTDIR}/${pkg}.tar.gz"
    if [ ! -f "$dest" ]; then
        wget -q --user-agent="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0" \
            "https://www.makemkv.com/download/${pkg}.tar.gz" -O "$dest"
    fi
done

echo "==> Installing MakeMKV"
emerge --changed-use media-video/makemkv

echo "==> Done."
echo "    HandBrake GUI: $(command -v ghb || echo 'not found')"
echo "    MakeMKV:       $(command -v makemkvcon || echo 'not found')"
