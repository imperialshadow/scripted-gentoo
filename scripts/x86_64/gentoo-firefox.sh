#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Firefox web browser (built from source)
set -eo pipefail

echo "============================="
echo " Firefox Install"
echo "============================="
echo
echo "NOTE: Firefox compiles from source. This will take a while."
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

mkdir -p /etc/portage/package.accept_keywords
if ! grep -q 'www-client/firefox' /etc/portage/package.accept_keywords/firefox 2>/dev/null; then
    echo 'www-client/firefox ~amd64' >> /etc/portage/package.accept_keywords/firefox
fi

# Firefox's transitive deps occasionally lag behind its own ~arch keyword:
# nss (>=3.128 required, only unstable), dav1d (AV1 decode, no stable
# keyword yet), and firefox-l10n (hard RDEPEND since the "rapid" release
# split -- not required by older ESR-style installs)
if ! grep -q 'dev-libs/nss' /etc/portage/package.accept_keywords/firefox 2>/dev/null; then
    echo 'dev-libs/nss ~amd64' >> /etc/portage/package.accept_keywords/firefox
fi
if ! grep -q 'media-libs/dav1d' /etc/portage/package.accept_keywords/firefox 2>/dev/null; then
    echo 'media-libs/dav1d ~amd64' >> /etc/portage/package.accept_keywords/firefox
fi
if ! grep -q 'www-client/firefox-l10n' /etc/portage/package.accept_keywords/firefox 2>/dev/null; then
    echo 'www-client/firefox-l10n ~amd64' >> /etc/portage/package.accept_keywords/firefox
fi

mkdir -p /etc/portage/package.use
if ! grep -q 'media-libs/libvpx' /etc/portage/package.use/firefox 2>/dev/null; then
    echo 'media-libs/libvpx postproc' >> /etc/portage/package.use/firefox
fi

emerge --ask=n www-client/firefox

echo
echo "Firefox installed."
