#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
exec > >(tee "$LOG_FILE") 2>&1

# Ensure the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# Configuration
# =============================================================================

CRYPT_NAME="cryptroot"
VG_NAME="vg0"
ROOT_SIZE="100%FREE"
MOUNT_POINT="/mnt/gentoo"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHROOT_SCRIPT_SOURCE="${SCRIPT_DIR}/gentoo-chroot.sh"
CHROOT_SCRIPT_TARGET="${MOUNT_POINT}/root/gentoo-chroot.sh"
GENTOO_MIRROR="https://distfiles.gentoo.org/releases/x86/autobuilds"

# =============================================================================
# Cleanup trap
# Runs on any exit (success or failure) to leave the system in a clean state
# =============================================================================

cleanup() {
    umount -R "$MOUNT_POINT" 2>/dev/null || true
    swapoff "/dev/${VG_NAME}/swap" 2>/dev/null || true
    vgchange -an "$VG_NAME" 2>/dev/null || true
    cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# Disable sleep and screen blanking in the live environment
# =============================================================================

setterm --blank 0 --powerdown 0 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1; then
    systemctl mask --now sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
fi

# =============================================================================
# Preflight checks
# =============================================================================

# Verify the chroot script is present before doing anything destructive
if [[ ! -f "$CHROOT_SCRIPT_SOURCE" ]]; then
    echo "Could not find chroot script at: $CHROOT_SCRIPT_SOURCE"
    echo "Make sure gentoo-chroot.sh is in the same directory as this installer script."
    exit 1
fi

# Fetch the latest stage3 info before touching the disk so network failures
# are caught early and no data has been destroyed yet
echo "Fetching latest Gentoo stage3 info..."
# Try SELinux-hardened stage3 first; fall back to standard systemd stage3 if unavailable
SELINUX_INDEX_URL="${GENTOO_MIRROR}/latest-stage3-i686-hardened-selinux-systemd.txt"
FALLBACK_INDEX_URL="${GENTOO_MIRROR}/latest-stage3-i686-systemd.txt"
STAGE3_INDEX=$(wget -qO- "$SELINUX_INDEX_URL" 2>/dev/null) && {
    STAGE3_INDEX_URL="$SELINUX_INDEX_URL"
    echo "Using SELinux-hardened stage3 (i686)."
} || {
    echo "NOTE: SELinux stage3 not available for i686 — falling back to standard systemd stage3."
    echo "SELinux will still be configured via kernel and profile settings."
    STAGE3_INDEX=$(wget -qO- "$FALLBACK_INDEX_URL") || {
        echo "Failed to fetch stage3 index."
        echo "Check network connectivity and mirror availability."
        exit 1
    }
    STAGE3_INDEX_URL="$FALLBACK_INDEX_URL"
}
STAGE3_PATH=$(grep -E '^[0-9]{8}T[0-9]{6}Z/' <<< "$STAGE3_INDEX" | awk '{print $1; exit}')
if [[ -z "$STAGE3_PATH" ]]; then
    echo "Failed to parse stage3 path from index. Unexpected format:"
    echo "$STAGE3_INDEX" | head -5
    exit 1
fi
STAGE3_FILENAME=$(basename -- "$STAGE3_PATH")
STAGE3_URL="${GENTOO_MIRROR}/${STAGE3_PATH}"
STAGE3_TARGET="${MOUNT_POINT}/${STAGE3_FILENAME}"
echo "Latest stage3: ${STAGE3_FILENAME}"

echo "===================="
echo "Gentoo Linux Install"
echo "===================="
echo

# =============================================================================
# Disk selection
# =============================================================================

while true; do
    lsblk
    read -p "Enter target disk (example: /dev/sda or /dev/nvme0n1): " DISK
    if [[ -b "$DISK" ]]; then
        break
    fi
    echo "Invalid disk: $DISK"
    echo "Please enter a valid block device."
    echo
done

# NVMe disks end in a digit and use p1/p2 partition naming; SATA uses 1/2
if [[ "${DISK}" =~ [0-9]$ ]]; then
    PART1="${DISK}p1"
    LUKS_PARTITION="${DISK}p2"
else
    PART1="${DISK}1"
    LUKS_PARTITION="${DISK}2"
fi

# =============================================================================
# Boot mode detection
# =============================================================================

if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
else
    BOOT_MODE="bios"
fi
echo "Boot mode: ${BOOT_MODE^^}"

# =============================================================================
# Swap size (auto-calculated from system RAM)
# =============================================================================

RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
echo -n "System RAM: "
awk '/MemTotal/ {printf "%.2f GiB\n", $2/1024/1024}' /proc/meminfo

SWAP_GB=$(( (RAM_KB + 1048575) / 1048576 ))
SWAP_SIZE="${SWAP_GB}G"
echo "Swap size: ${SWAP_SIZE}"

read -rp "Create swap space? [Y/n]: " SWAP_CHOICE
case "${SWAP_CHOICE,,}" in
    n|no) CREATE_SWAP=false ;;
    *)    CREATE_SWAP=true  ;;
esac

# =============================================================================
# Destructive operations warning
# =============================================================================

echo "WARNING: THIS WILL DESTROY ALL DATA ON ${DISK}"
echo " Press CTRL+C within 10 seconds to cancel"
sleep 10

# =============================================================================
# Partitioning
# =============================================================================

# UEFI: 1 GiB FAT32 ESP then LUKS.
# BIOS: 1 MiB raw bios_grub partition for GRUB stage2 then LUKS.
parted -s "$DISK" mklabel gpt
if [[ "$BOOT_MODE" == "uefi" ]]; then
    parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary 1025MiB 100%
else
    parted -s "$DISK" mkpart biosboot 1MiB 2MiB
    parted -s "$DISK" set 1 bios_grub on
    parted -s "$DISK" mkpart primary 2MiB 100%
fi

# Wait for the kernel and udev to register the new partition table
partprobe "$DISK"
udevadm settle
sleep 2

if [[ ! -b "$PART1" || ! -b "$LUKS_PARTITION" ]]; then
    echo "Partition creation failed."
    echo "Missing one of: $PART1 $LUKS_PARTITION"
    exit 1
fi

# =============================================================================
# Encryption and LVM setup
# =============================================================================

if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.vfat -F32 "$PART1"
fi

# Format with LUKS2; --batch-mode suppresses the confirmation prompt
# but still requires interactive passphrase entry
cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PARTITION"
cryptsetup open "$LUKS_PARTITION" "$CRYPT_NAME"

# Create LVM physical volume and volume group inside the LUKS container
pvcreate "/dev/mapper/${CRYPT_NAME}"
vgcreate "$VG_NAME" "/dev/mapper/${CRYPT_NAME}"

# Create swap and root logical volumes
if $CREATE_SWAP; then
    lvcreate -L "$SWAP_SIZE" "$VG_NAME" -n swap
fi
lvcreate -l "$ROOT_SIZE" "$VG_NAME" -n root

mkfs.ext4 "/dev/${VG_NAME}/root"
if $CREATE_SWAP; then
    mkswap "/dev/${VG_NAME}/swap"
    swapon "/dev/${VG_NAME}/swap"
fi

# =============================================================================
# Mount filesystems
# =============================================================================

mkdir -p "$MOUNT_POINT"
mount "/dev/${VG_NAME}/root" "$MOUNT_POINT"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p "${MOUNT_POINT}/boot"
    mount "$PART1" "${MOUNT_POINT}/boot"
fi
cd "$MOUNT_POINT"

# =============================================================================
# Stage3 download and extraction
# =============================================================================

echo
echo "=============="
echo "Gentoo Stage 3"
echo "=============="
echo

wget -O "$STAGE3_TARGET" "$STAGE3_URL"
wget -qO "${STAGE3_TARGET}.sha256" "${STAGE3_URL}.sha256" || {
    echo "Failed to download stage3 checksum from: ${STAGE3_URL}.sha256"
    exit 1
}
# Verify GPG signature of the stage3 tarball (Gentoo Release Engineering key)
if command -v gpg >/dev/null 2>&1; then
    gpg --keyserver hkps://keys.openpgp.org --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910 2>/dev/null || \
    gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910 2>/dev/null || {
        echo "WARNING: Could not fetch Gentoo release key from keyservers."
    }
    if wget -qO "${STAGE3_TARGET}.asc" "${STAGE3_URL}.asc" 2>/dev/null; then
        gpg --verify "${STAGE3_TARGET}.asc" "${STAGE3_TARGET}" || {
            echo "Stage3 GPG signature verification failed — aborting."
            exit 1
        }
        echo "Stage3 GPG signature verified."
    else
        echo "WARNING: No GPG signature file found for this stage3 — skipping GPG verification."
    fi
else
    echo "WARNING: gpg not available — skipping GPG verification (SHA256 only)"
fi

# Verify SHA256 integrity; sha256sum resolves the filename in the
# checksum file relative to the working directory, so run it from MOUNT_POINT
( cd "$MOUNT_POINT" && sha256sum -c "${STAGE3_FILENAME}.sha256" ) || {
    echo "Stage3 checksum verification failed."
    exit 1
}
tar xpvf "${STAGE3_TARGET}" --xattrs-include='*.*' --numeric-owner

# =============================================================================
# Chroot preparation
# =============================================================================

# Copy host DNS config so the chroot has network access for emerge
cp --dereference /etc/resolv.conf "${MOUNT_POINT}/etc/"

mkdir -p "${MOUNT_POINT}/root"
cp "$CHROOT_SCRIPT_SOURCE" "$CHROOT_SCRIPT_TARGET"
chmod +x "$CHROOT_SCRIPT_TARGET"

# Bind-mount virtual filesystems required inside the chroot
mount --types proc /proc "${MOUNT_POINT}/proc"
mount --rbind /sys "${MOUNT_POINT}/sys"
mount --make-rslave "${MOUNT_POINT}/sys"
mount --rbind /dev "${MOUNT_POINT}/dev"
mount --make-rslave "${MOUNT_POINT}/dev"
mount --bind /run "${MOUNT_POINT}/run"
mount --make-slave "${MOUNT_POINT}/run"

# =============================================================================
# Enter chroot
# =============================================================================

SWAP_ARGS=()
$CREATE_SWAP || SWAP_ARGS=("--no-swap")
[[ "$BOOT_MODE" == "bios" ]] && SWAP_ARGS+=("--bios")
chroot "$MOUNT_POINT" /bin/bash /root/gentoo-chroot.sh "${SWAP_ARGS[@]}"

# Remove the stage3 tarball now that extraction is complete
rm -f "${STAGE3_TARGET}" "${STAGE3_TARGET}.sha256" "${STAGE3_TARGET}.asc"

echo
echo "===================="
echo "==Install Complete=="
echo "===================="
exit 0
