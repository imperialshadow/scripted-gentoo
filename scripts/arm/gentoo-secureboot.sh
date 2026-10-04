#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Configure Secure Boot key enrollment (requires Setup Mode) and sign boot files
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================="
echo " Gentoo Secure Boot Setup"
echo "============================="
echo

if [[ ! -d /sys/firmware/efi ]]; then
    echo "Not booted in UEFI mode. Skipping Secure Boot setup."
    exit 0
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "EFI variables not available. Skipping Secure Boot setup."
    exit 0
fi

emerge --ask=n --noreplace app-crypt/sbctl

echo "Secure Boot status:"
sbctl status || true
echo

# =============================================================================
# Key enrollment — only possible when firmware is in Setup Mode
# =============================================================================

setup_mode_file="$(find /sys/firmware/efi/efivars -name 'SetupMode-*' 2>/dev/null | head -n1)"
# EFI variable files have a 4-byte attribute header before the data
setup_mode_value="$(od -An -j4 -N1 -t u1 "${setup_mode_file:-/dev/null}" 2>/dev/null | tr -d ' \n')"

if [[ "$setup_mode_value" == "1" ]]; then
    echo "Setup Mode detected — enrolling keys..."
    if [[ ! -d /var/lib/sbctl/keys ]]; then
        sbctl create-keys
    else
        echo "sbctl keys already exist; skipping key creation."
    fi
    sbctl enroll-keys -m
    echo "Keys enrolled."
    echo
else
    echo "Setup Mode not active (value=${setup_mode_value:-unknown}) — skipping key enrollment."
    echo "Keys must already be enrolled, or enter Setup Mode in UEFI firmware first."
    echo
fi

# =============================================================================
# Reinstall GRUB with all modules embedded into the EFI binary.
# GRUB .mod files on disk are not PE binaries and cannot be signed by sbctl.
# When Secure Boot is active, GRUB's own shim verifier blocks unsigned .mod
# files, causing "prohibited by secure boot policy" and rescue mode.
# Embedding modules at install time avoids all external module loading.
# =============================================================================

echo "Reinstalling GRUB with embedded modules for Secure Boot..."
grub-install \
    --efi-directory=/boot \
    --bootloader-id=Gentoo \
    --modules="part_gpt part_msdos fat ext2 lvm luks luks2 cryptodisk \
mdraid09 mdraid1x linux normal loadenv all_video video_bochs video_cirrus \
efi_gop efi_uga gfxterm gfxmenu echo search search_fs_uuid search_label \
regexp test true png jpeg"
echo "GRUB reinstalled."

# Copy to the EFI fallback path so the firmware can boot even if its boot
# entries are cleared (e.g. after a CMOS reset or firmware update)
mkdir -p /boot/EFI/BOOT
cp /boot/EFI/Gentoo/grubx64.efi /boot/EFI/BOOT/BOOTX64.EFI
echo "Copied grubx64.efi to BOOTX64.EFI fallback."
echo

# =============================================================================
# Sign boot files — runs every time regardless of Setup Mode
# =============================================================================

if [[ ! -d /var/lib/sbctl/keys ]]; then
    echo "No sbctl keys found — cannot sign files."
    echo "Enter Setup Mode in UEFI firmware and re-run this script."
    exit 1
fi

sign_if_exists() {
    local f="$1"
    if [[ -f "$f" ]]; then
        echo "  Signing: $f"
        sbctl sign -s "$f"
    fi
}

echo "Signing EFI boot files..."

# GRUB EFI loaders
sign_if_exists /boot/EFI/Gentoo/grubx64.efi
sign_if_exists /boot/EFI/BOOT/BOOTX64.EFI
sign_if_exists /boot/grub/x86_64-efi/grub.efi
sign_if_exists /boot/grub/x86_64-efi/core.efi

# Kernels — genkernel uses vmlinuz* names without .efi extension
for f in /boot/vmlinuz /boot/vmlinuz-* /boot/kernel-*; do
    sign_if_exists "$f"
done

# EFI stubs with explicit .efi extension (unified kernel images, etc.)
for f in /boot/*.efi /boot/EFI/Linux/*.efi; do
    sign_if_exists "$f"
done

echo
echo "Verifying signed files..."
sbctl verify || true

echo
echo "Secure Boot setup complete."
echo "Enable Secure Boot in UEFI firmware if not already enabled."
