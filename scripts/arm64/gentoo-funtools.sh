#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

echo "============================================"
echo " Fun & Eye-Candy Terminal Tools"
echo "============================================"
echo
echo "Installing: lolcat, sl, cmatrix, cowsay"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  KW="~amd64" ;;
    i686)    KW="~x86" ;;
    aarch64) KW="~arm64" ;;
    arm*)    KW="~arm" ;;
    *)       KW="~${ARCH}" ;;
esac

# =============================================================================
# Keywords
# =============================================================================
mkdir -p /etc/portage/package.accept_keywords

cat > /etc/portage/package.accept_keywords/funtools << EOF
app-misc/sl ${KW}
app-misc/cmatrix ${KW}
games-misc/lolcat ${KW}
EOF

# =============================================================================
# Installation
# =============================================================================
FAILED=0
run() {
    echo
    echo "--- $* ---"
    emerge --ask=n --verbose "$@" || { echo "WARNING: Failed to install $* — skipping"; FAILED=$((FAILED+1)); }
}

run app-misc/sl
run games-misc/cowsay
run app-misc/cmatrix
run games-misc/lolcat

echo
echo "================================================================"
echo " Results"
echo "================================================================"
echo
if (( FAILED > 0 )); then
    echo "${FAILED} package(s) failed — see warnings above."
else
    echo "All fun tools installed successfully."
fi
echo
echo "Note: hollywood is not available on Gentoo (chaoslab overlay is private/dead)."
