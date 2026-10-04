#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Spotify — not supported on 32-bit ARM
set -eo pipefail

echo "============================="
echo " Spotify Install"
echo "============================="
echo

echo "ERROR: Spotify does not support 32-bit ARM (armv7/arm)."
echo "Spotify is only available for x86_64 and arm64 (aarch64)."
exit 1
