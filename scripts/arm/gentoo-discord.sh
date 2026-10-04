#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install Discord — not supported on 32-bit ARM
set -eo pipefail

echo "============================="
echo " Discord Install"
echo "============================="
echo

echo "ERROR: Discord does not support 32-bit ARM (armv7/arm)."
echo "Discord is only available for x86_64 and arm64 (aarch64)."
exit 1
