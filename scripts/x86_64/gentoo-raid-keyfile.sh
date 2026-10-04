#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Add a keyfile to the RAID LUKS volume for automatic decryption at boot
set -eo pipefail

echo "============================="
echo " RAID LUKS Keyfile Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo -i bash $0"
    exit 1
fi

LUKS_NAME="raid_crypt"
KEYFILE_DIR="/etc/cryptsetup-keys.d"
KEYFILE="${KEYFILE_DIR}/${LUKS_NAME}.key"

# =============================================================================
# Locate the RAID device
# =============================================================================

MD_DEV=$(ls /dev/md/[0-9]* /dev/md[0-9]* 2>/dev/null | grep -v 'p[0-9]' | head -n1 || true)
if [[ -z "$MD_DEV" ]]; then
    echo "ERROR: No RAID device found. Is the array assembled?"
    echo "Run: mdadm --assemble --scan"
    exit 1
fi

FS_TYPE=$(blkid -s TYPE -o value "$MD_DEV" 2>/dev/null || true)
if [[ "$FS_TYPE" != "crypto_LUKS" ]]; then
    echo "ERROR: ${MD_DEV} is not a LUKS device (type: ${FS_TYPE:-unknown})."
    exit 1
fi

LUKS_UUID=$(blkid -s UUID -o value "$MD_DEV")
MD_UUID=$(mdadm --detail "$MD_DEV" 2>/dev/null | awk '/UUID/{print $3}' | head -n1)
echo "RAID device : ${MD_DEV}"
echo "RAID UUID   : ${MD_UUID}"
echo "LUKS UUID   : ${LUKS_UUID}"
echo "Keyfile     : ${KEYFILE}"
echo

# =============================================================================
# mdadm.conf — ensure ARRAY entry exists for reliable boot-time assembly
# Without this, udev may assemble the array with a different name or timing
# =============================================================================

MDADM_CONF="/etc/mdadm.conf"
if [[ -n "$MD_UUID" ]] && ! grep -q "^ARRAY.*${MD_UUID}" "$MDADM_CONF" 2>/dev/null; then
    echo "Adding ARRAY entry to ${MDADM_CONF}..."
    echo "ARRAY ${MD_DEV} UUID=${MD_UUID}" >> "$MDADM_CONF"
    echo "Added: ARRAY ${MD_DEV} UUID=${MD_UUID}"
    echo
else
    echo "mdadm.conf ARRAY entry already present."
    echo
fi

# =============================================================================
# Generate keyfile
# =============================================================================

if [[ -f "$KEYFILE" ]]; then
    echo "Keyfile already exists at ${KEYFILE}."
    echo "To regenerate it you must remove the old key slot manually first:"
    echo "  cryptsetup luksDump ${MD_DEV}   # find the key slot number"
    echo "  cryptsetup luksKillSlot ${MD_DEV} <slot>"
    echo "  rm ${KEYFILE}"
    echo "Then re-run this script."
else
    mkdir -p "$KEYFILE_DIR"
    chmod 700 "$KEYFILE_DIR"

    echo "Generating 512-byte random keyfile..."
    dd if=/dev/urandom of="$KEYFILE" bs=512 count=1 status=none
    chmod 400 "$KEYFILE"
    echo "Keyfile generated."
    echo

    # =============================================================================
    # Add keyfile as a new LUKS key slot
    # Requires the existing passphrase to authorise the new slot.
    # =============================================================================

    echo "Adding keyfile to LUKS key slot..."
    echo "(You will be prompted for your existing LUKS passphrase.)"
    echo
    cryptsetup luksAddKey "$MD_DEV" "$KEYFILE"
    echo "Keyfile added to LUKS."
    echo
fi

# =============================================================================
# Update /etc/crypttab to use the keyfile
# =============================================================================

if grep -q "^${LUKS_NAME}" /etc/crypttab; then
    sed -i "s|^${LUKS_NAME}.*|${LUKS_NAME}  UUID=${LUKS_UUID}  ${KEYFILE}  luks|" /etc/crypttab
else
    echo "${LUKS_NAME}  UUID=${LUKS_UUID}  ${KEYFILE}  luks" >> /etc/crypttab
fi

echo "Updated /etc/crypttab:"
grep "$LUKS_NAME" /etc/crypttab
echo

# Reload systemd so the updated crypttab is picked up
systemctl daemon-reload

echo "RAID LUKS keyfile configured."
echo "The RAID volume will decrypt automatically on next boot."
echo
echo "To verify the key slot was added:"
echo "  cryptsetup luksDump ${MD_DEV} | grep -A2 'Key Slot'"
