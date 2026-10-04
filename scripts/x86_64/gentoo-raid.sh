#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# RAID array setup — installs mdadm, assembles existing array, handles LUKS if present,
# mounts and persists via mdadm.conf + crypttab + fstab.
# Run as root after first boot.

set -eo pipefail

# =============================================================================
# Configuration — adjust before running
# =============================================================================

MOUNT_POINT="/mnt/raid"
MOUNT_OPTS="defaults,nofail,x-systemd.device-timeout=60"
# Name for the LUKS mapper device (appears as /dev/mapper/$LUKS_NAME)
LUKS_NAME="raid_crypt"

# =============================================================================
# Install mdadm
# =============================================================================

echo "=== Installing mdadm ==="
if ! command -v mdadm &>/dev/null; then
    emerge --ask=n sys-fs/mdadm
else
    echo "  mdadm already installed."
fi

# =============================================================================
# Assemble array from superblocks
# =============================================================================

echo ""
echo "=== Assembling RAID array ==="
mkdir -p /etc/mdadm

mdadm --assemble --scan --verbose || true
sleep 2

MD_DEV=$(ls /dev/md/[0-9]* /dev/md[0-9]* 2>/dev/null | grep -v 'p[0-9]' | head -n1 || true)
if [[ -z "$MD_DEV" ]]; then
    echo "ERROR: No md device found after assembly."
    echo "  Check that the member disks are present: lsblk -o NAME,TYPE,FSTYPE"
    exit 1
fi
echo "Using: $MD_DEV"

# =============================================================================
# Show array details and persist mdadm.conf
# =============================================================================

echo ""
echo "=== Array details ==="
mdadm --detail "$MD_DEV"

echo ""
echo "=== Writing /etc/mdadm/mdadm.conf ==="
mdadm --detail --scan > /etc/mdadm/mdadm.conf
echo "  Done."

# =============================================================================
# Detect what's on the array
# =============================================================================

echo ""
echo "=== Detecting array content ==="
FS_TYPE=$(blkid -s TYPE -o value "$MD_DEV" || true)
echo "  Type on ${MD_DEV}: ${FS_TYPE:-<none>}"

# =============================================================================
# Handle LUKS layer (if present)
# =============================================================================

if [[ "$FS_TYPE" == "crypto_LUKS" ]]; then
    echo ""
    echo "=== Opening LUKS volume on $MD_DEV ==="
    LUKS_UUID=$(blkid -s UUID -o value "$MD_DEV")
    echo "  LUKS UUID: $LUKS_UUID"

    if [[ -e "/dev/mapper/${LUKS_NAME}" ]]; then
        echo "  /dev/mapper/${LUKS_NAME} already open — skipping cryptsetup."
    else
        cryptsetup luksOpen "$MD_DEV" "$LUKS_NAME"
    fi

    DATA_DEV="/dev/mapper/${LUKS_NAME}"
    FS_TYPE=$(blkid -s TYPE -o value "$DATA_DEV" || true)
    echo "  Filesystem inside LUKS: ${FS_TYPE:-<none>}"

    # Add to /etc/crypttab for auto-open at boot
    echo ""
    echo "=== Updating /etc/crypttab ==="
    CRYPTTAB_LINE="${LUKS_NAME}  UUID=${LUKS_UUID}  none  luks"
    if grep -q "$LUKS_UUID" /etc/crypttab 2>/dev/null; then
        echo "  Entry already present — skipping."
    else
        echo "$CRYPTTAB_LINE" >> /etc/crypttab
        echo "  Added: $CRYPTTAB_LINE"
    fi

else
    DATA_DEV="$MD_DEV"
    LUKS_UUID=""
fi

# =============================================================================
# Handle missing filesystem
# =============================================================================

if [[ -z "$FS_TYPE" ]]; then
    echo ""
    echo "No filesystem found on ${DATA_DEV}."
    echo "Create one with (choose one):"
    echo "  mkfs.ext4 -L raid $DATA_DEV"
    echo "  mkfs.xfs  -L raid $DATA_DEV"
    echo ""
    echo "Then re-run this script to complete fstab/mount setup."
    echo "(mdadm.conf and crypttab are already written.)"
    exit 0
fi

DATA_UUID=$(blkid -s UUID -o value "$DATA_DEV")
echo "  Data UUID: $DATA_UUID"

# =============================================================================
# Mount
# =============================================================================

echo ""
echo "=== Mounting ${DATA_DEV} at ${MOUNT_POINT} ==="
mkdir -p "$MOUNT_POINT"
if mountpoint -q "$MOUNT_POINT"; then
    echo "  Already mounted — skipping."
else
    mount "$DATA_DEV" "$MOUNT_POINT"
    echo "  Mounted. Contents:"
    ls "$MOUNT_POINT" | head -20
fi

# =============================================================================
# Add to /etc/fstab
# =============================================================================

echo ""
echo "=== Updating /etc/fstab ==="

if [[ -n "$LUKS_UUID" ]]; then
    # Mount by mapper name (stable after crypttab opens it)
    FSTAB_LINE="/dev/mapper/${LUKS_NAME}  ${MOUNT_POINT}  ${FS_TYPE}  ${MOUNT_OPTS}  0  2"
    FSTAB_KEY="/dev/mapper/${LUKS_NAME}"
else
    FSTAB_LINE="UUID=${DATA_UUID}  ${MOUNT_POINT}  ${FS_TYPE}  ${MOUNT_OPTS}  0  2"
    FSTAB_KEY="$DATA_UUID"
fi

if grep -qF "$FSTAB_KEY" /etc/fstab 2>/dev/null; then
    echo "  Entry already present — skipping."
else
    echo "" >> /etc/fstab
    echo "# RAID array (${MD_DEV}${LUKS_UUID:+ → LUKS → }${LUKS_UUID:+/dev/mapper/${LUKS_NAME}})" >> /etc/fstab
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "  Added: $FSTAB_LINE"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Done ==="
echo "  RAID device:  $MD_DEV"
[[ -n "$LUKS_UUID" ]] && echo "  LUKS UUID:    $LUKS_UUID" && echo "  Mapper:       /dev/mapper/${LUKS_NAME}"
echo "  Filesystem:   $FS_TYPE"
echo "  Mount point:  $MOUNT_POINT"
echo ""
echo "Boot sequence: mdadm assembles array → cryptsetup opens LUKS → fstab mounts."
echo "To check array status: mdadm --detail $MD_DEV"
