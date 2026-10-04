#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Gentoo live-USB chroot helper
# Mounts an installed Gentoo system from the live environment, then either
# rebuilds the kernel (using kernel-rebuild.sh) or opens an interactive
# rescue shell for manual recovery work.
#
# Run as root from the live USB alongside kernel-rebuild.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/mnt/gentoo"

echo "=============================="
echo " Gentoo Live Chroot Helper"
echo "=============================="
echo ""

# =============================================================================
# Encryption type
# =============================================================================

echo "Is the target system using LUKS disk encryption?"
echo "  1) Yes — LUKS + LVM"
echo "  2) No  — unencrypted"
echo ""
while true; do
    read -p "Enter 1 or 2: " CHOICE
    case "$CHOICE" in
        1) DISK_TYPE="luks";   break ;;
        2) DISK_TYPE="noluks"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

# =============================================================================
# Disk selection
# =============================================================================

echo ""
lsblk
echo ""
while true; do
    read -p "Enter target disk (example: /dev/nvme0n1): " DISK
    if [[ -n "$DISK" && -b "$DISK" ]]; then
        break
    fi
    echo "Invalid disk: '${DISK}'. Enter a valid block device."
done

if [[ "${DISK}" =~ [0-9]$ ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# =============================================================================
# Mount setup with automatic cleanup on exit
# =============================================================================

cleanup() {
    echo ""
    echo "Cleaning up mounts..."
    umount -R "$MOUNT_POINT" 2>/dev/null || true
    if [[ "$DISK_TYPE" == "luks" ]]; then
        vgchange -an 2>/dev/null || true
        cryptsetup luksClose root 2>/dev/null || true
    fi
    echo "Done."
}
trap cleanup EXIT

mkdir -p "$MOUNT_POINT"

if [[ "$DISK_TYPE" == "luks" ]]; then
    echo ""
    echo "Opening LUKS device $ROOT_PART ..."
    cryptsetup luksOpen "$ROOT_PART" root
    vgchange -ay
    mount /dev/mapper/vg0-root "$MOUNT_POINT"
else
    echo ""
    echo "Mounting $ROOT_PART ..."
    mount "$ROOT_PART" "$MOUNT_POINT"
fi

echo "Setting up bind mounts..."
mount "$EFI_PART" "$MOUNT_POINT/boot"
mount --bind /dev  "$MOUNT_POINT/dev"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys  "$MOUNT_POINT/sys"
if [[ -d /sys/firmware/efi/efivars ]]; then
    mount --bind /sys/firmware/efi/efivars "$MOUNT_POINT/sys/firmware/efi/efivars"
fi

echo ""
echo "System mounted at $MOUNT_POINT."

# =============================================================================
# Action menu
# =============================================================================

echo ""
echo "What would you like to do?"
echo "  1) Rebuild kernel (runs kernel-rebuild.sh)"
echo "  2) Open a rescue shell in the chroot"
echo ""
while true; do
    read -p "Enter 1 or 2: " ACTION
    case "$ACTION" in
        1|2) break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

echo ""

if [[ "$ACTION" == "1" ]]; then
    if [[ ! -f "$SCRIPT_DIR/kernel-rebuild.sh" ]]; then
        echo "ERROR: kernel-rebuild.sh not found at $SCRIPT_DIR/kernel-rebuild.sh"
        exit 1
    fi
    cp "$SCRIPT_DIR/kernel-rebuild.sh" "$MOUNT_POINT/root/kernel-rebuild.sh"
    chmod +x "$MOUNT_POINT/root/kernel-rebuild.sh"
    echo "Entering chroot to rebuild kernel..."
    echo ""
    chroot "$MOUNT_POINT" /bin/bash /root/kernel-rebuild.sh "$DISK_TYPE"
    rm -f "$MOUNT_POINT/root/kernel-rebuild.sh"
    echo ""
    echo "Kernel rebuilt. Remove the live USB and reboot."
else
    echo "Opening rescue shell. The installed system is at /."
    echo "Type 'exit' when done — mounts will be cleaned up automatically."
    echo ""
    chroot "$MOUNT_POINT" /bin/bash --login
fi
