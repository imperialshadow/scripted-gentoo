#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Raspberry Pi 4/400/CM4 UEFI firmware installer (pftf/RPi4).
#
# The Pi 4 has no native UEFI: its boot ROM only understands the Broadcom
# start4.elf/config.txt boot process. GRUB's arm64-efi target (installed by
# gentoo-chroot*.sh) needs a UEFI environment to run in, so the pftf/RPi4
# project's EDK2 build (RPI_EFI.fd) has to sit on the same FAT32 partition as
# start4.elf/fixup4.dat, acting as the "armstub" the boot ROM loads. Once that
# firmware is running, standard UEFI removable-media boot finds GRUB at
# efi/boot/bootaa64.efi on the same partition and chainloads it.
#
# Two ways to use this script:
#   1. Post-install: point it at the ESP the installer already created
#      (e.g. /dev/sda1 or /dev/mmcblk0p1) so the Pi can boot the installed
#      system directly, no separate media required.
#   2. A separate live-boot USB/SD card: format one FAT32 partition on it
#      first (parted -s /dev/sdX mklabel gpt; parted -s /dev/sdX mkpart ESP
#      fat32 1MiB 513MiB; parted -s /dev/sdX set 1 esp on; mkfs.vfat -F32
#      /dev/sdX1), then run this script against it, then add a live Linux
#      distro's own efi/boot/bootaa64.efi alongside for it to boot into.
#
# Safe to re-run: any existing config.txt is backed up once before being
# replaced with the upstream pftf default. GRUB's own EFI/ directory is left
# untouched — pftf's files live at the partition root, GRUB's do not.

set -eo pipefail

LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
exec > >(tee "$LOG_FILE") 2>&1

# Ensure the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

RELEASES_API="https://api.github.com/repos/pftf/RPi4/releases/latest"
WORK_DIR=""
MOUNT_POINT=""
MOUNTED_HERE=false

# =============================================================================
# Cleanup trap
# =============================================================================

cleanup() {
    if $MOUNTED_HERE; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    [[ -n "$MOUNT_POINT" ]] && rmdir "$MOUNT_POINT" 2>/dev/null || true
    [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# =============================================================================
# Preflight checks
# =============================================================================

if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: unzip is required but not found."
    echo "Install it first, e.g.: emerge app-arch/unzip"
    exit 1
fi

# =============================================================================
# Target partition selection
# =============================================================================

echo "======================================"
echo " Raspberry Pi 4 UEFI Firmware Install"
echo "======================================"
echo
echo "This writes the pftf/RPi4 UEFI firmware (RPI_EFI.fd) and the matching"
echo "Broadcom boot files (start4.elf, fixup4.dat, config.txt, overlays) onto"
echo "an existing FAT32 partition — the ESP created by gentoo-install-*.sh,"
echo "or a partition you've formatted yourself for a separate boot medium."
echo

while true; do
    lsblk
    read -rp "Enter target partition (example: /dev/sda1 or /dev/mmcblk0p1): " TARGET_PART
    if [[ -b "$TARGET_PART" ]]; then
        break
    fi
    echo "Invalid partition: $TARGET_PART"
    echo "Please enter a valid block device (a partition, not a whole disk)."
    echo
done

FSTYPE="$(blkid -s TYPE -o value "$TARGET_PART" 2>/dev/null || true)"
if [[ "$FSTYPE" != "vfat" ]]; then
    echo "Error: $TARGET_PART is not formatted as FAT32 (detected: ${FSTYPE:-unknown})."
    echo "Format it first, e.g.: mkfs.vfat -F32 $TARGET_PART"
    exit 1
fi

# =============================================================================
# Mount target (reuse an existing mount if there is one, e.g. /mnt/gentoo/boot)
# =============================================================================

EXISTING_MOUNT="$(findmnt -n -o TARGET "$TARGET_PART" 2>/dev/null || true)"
if [[ -n "$EXISTING_MOUNT" ]]; then
    MOUNT_POINT="$EXISTING_MOUNT"
    echo "Using existing mount: $TARGET_PART is mounted at $MOUNT_POINT"
else
    MOUNT_POINT="$(mktemp -d /mnt/rpi4-firmware.XXXXXX)"
    mount "$TARGET_PART" "$MOUNT_POINT"
    MOUNTED_HERE=true
    echo "Mounted $TARGET_PART at $MOUNT_POINT"
fi

# =============================================================================
# Fetch latest pftf/RPi4 UEFI firmware release
# =============================================================================

echo
echo "Fetching latest pftf/RPi4 firmware release info..."
RELEASE_JSON=$(wget -qO- "$RELEASES_API") || {
    echo "Failed to reach $RELEASES_API"
    echo "Check network connectivity."
    exit 1
}
FIRMWARE_VERSION=$(grep -m1 '"tag_name"' <<< "$RELEASE_JSON" | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
FIRMWARE_URL=$(grep -o '"browser_download_url": *"[^"]*\.zip"' <<< "$RELEASE_JSON" | sed -E 's/.*"(https:[^"]+)"/\1/' | head -n1)
if [[ -z "$FIRMWARE_VERSION" || -z "$FIRMWARE_URL" ]]; then
    echo "Failed to parse release info from GitHub API response."
    exit 1
fi
echo "Latest firmware: $FIRMWARE_VERSION"

WORK_DIR="$(mktemp -d)"
FIRMWARE_ZIP="${WORK_DIR}/rpi4-uefi.zip"
wget -O "$FIRMWARE_ZIP" "$FIRMWARE_URL"
unzip -q -o "$FIRMWARE_ZIP" -d "${WORK_DIR}/extracted"

# =============================================================================
# Install firmware files onto the target partition
# =============================================================================

if [[ -f "${MOUNT_POINT}/config.txt" ]]; then
    echo "Existing config.txt found — backing up to config.txt.bak"
    cp "${MOUNT_POINT}/config.txt" "${MOUNT_POINT}/config.txt.bak"
fi

echo "Copying firmware files to ${MOUNT_POINT} ..."
cp "${WORK_DIR}/extracted/RPI_EFI.fd" "$MOUNT_POINT/"
cp "${WORK_DIR}/extracted/start4.elf" "$MOUNT_POINT/"
cp "${WORK_DIR}/extracted/fixup4.dat" "$MOUNT_POINT/"
cp "${WORK_DIR}/extracted/config.txt" "$MOUNT_POINT/"
cp "${WORK_DIR}/extracted"/*.dtb "$MOUNT_POINT/"
cp -r "${WORK_DIR}/extracted/overlays" "$MOUNT_POINT/"
cp -r "${WORK_DIR}/extracted/firmware" "$MOUNT_POINT/"

sync

echo
echo "===================="
echo "==Firmware Installed=="
echo "===================="
echo
echo "IMPORTANT — Raspberry Pi 4 8GB (and 4GB) boards:"
echo "  This firmware enforces a 3 GB RAM limit by default, to work around a"
echo "  DMA hardware bug, unless the OS is known to patch it (Linux 5.8+ does)."
echo "  Gentoo's kernel is recent enough, but you must disable the cap manually:"
echo "    On first boot, press Esc at the rainbow/Pi logo screen to enter"
echo "    firmware setup, then: Device Manager -> Raspberry Pi Configuration"
echo "    -> Advanced Configuration -> Limit RAM to 3 GB -> Disabled."
echo
echo "Also note:"
echo "  - Booting from USB or from this ESP (rather than a plain SD card boot"
echo "    partition) requires a recent Pi 4 EEPROM. If the board doesn't boot,"
echo "    update it from another machine: https://github.com/raspberrypi/rpi-eeprom"
echo "  - Ethernet needs a kernel >= 5.7, SD/Wi-Fi need >= 5.12 — the gentoo-chroot"
echo "    scripts already build a current kernel, so this is normally a non-issue."
exit 0
