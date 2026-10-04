#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install common archive/compression utilities
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================================"
echo " Archive & Compression Tools"
echo "============================================"
echo

FAILED=0
run() {
    echo "--- $* ---"
    emerge --ask=n --noreplace "$@" || { echo "WARNING: Failed to install $* — skipping"; FAILED=$((FAILED+1)); }
}

run app-arch/unzip
run app-arch/bzip2
run app-arch/gzip

echo
if (( FAILED > 0 )); then
    echo "${FAILED} package(s) failed — see warnings above."
else
    echo "Archive tools installed: unzip, bzip2, gzip"
fi
