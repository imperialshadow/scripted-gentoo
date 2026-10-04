#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Must be run as root."
    exit 1
fi

KVER=$(uname -r)
UPDATES_DIR="/lib/modules/${KVER}/updates"

if [[ ! -d "$UPDATES_DIR" ]]; then
    echo "No updates/ directory found for kernel ${KVER} — nothing to sync."
    exit 0
fi

echo "Syncing /lib/modules/${KVER}/updates/ to current kernel builds..."
SYNCED=0
REMOVED=0

for ko in "${UPDATES_DIR}"/*.ko "${UPDATES_DIR}"/*.ko.xz "${UPDATES_DIR}"/*.ko.zst; do
    [[ -e "$ko" ]] || continue
    name="$(basename "$ko")"; name="${name%%.*}.ko"
    new="$(find /lib/modules/${KVER}/kernel -name "$name" 2>/dev/null | head -1)"
    if [[ -n "$new" ]]; then
        cp "$new" "$ko"
        echo "  synced:  $name"
        (( SYNCED++ )) || true
    else
        # No match in kernel/ — the module was either dropped or is now
        # built-in (=y). Either way the updates/ copy is stale and will be
        # loaded instead of the built-in, causing CRC/vermagic mismatches
        # in any module that depends on it. Remove it so depmod falls through
        # to the kernel/ version (or the built-in symbols).
        rm -f "$ko"
        echo "  removed: $name (not in kernel/ — now built-in or dropped)"
        (( REMOVED++ )) || true
    fi
done

depmod -a
echo "Done. $SYNCED synced, $REMOVED removed. depmod -a applied."
