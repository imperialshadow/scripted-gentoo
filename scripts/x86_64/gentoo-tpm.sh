#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Enroll TPM2 auto-unlock for LUKS using PCRs 0+7 (requires Secure Boot)
set -eo pipefail

echo "======================================"
echo " Gentoo TPM2 LUKS Auto-Unlock Setup"
echo "======================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

if ! grep -qE '^[^#]' /etc/crypttab 2>/dev/null; then
    echo "ERROR: No LUKS configuration found in /etc/crypttab."
    echo "TPM auto-unlock is only meaningful on LUKS-encrypted installs."
    echo "This system appears to be an unencrypted (noluks) install."
    exit 1
fi

secure_boot_enabled() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        return 1
    fi

    local secure_boot_file
    secure_boot_file="$(find /sys/firmware/efi/efivars -name 'SecureBoot-*' 2>/dev/null | head -n1)"

    if [[ -z "$secure_boot_file" ]]; then
        return 1
    fi

    local secure_boot_value
    # EFI variable files have a 4-byte attribute header before the data; skip it
    secure_boot_value="$(od -An -j4 -N1 -t u1 "$secure_boot_file" | tr -d ' \n')"

    [[ "$secure_boot_value" == "1" ]]
}

secure_boot_setup_mode_active() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        return 1
    fi

    local setup_mode_file
    setup_mode_file="$(find /sys/firmware/efi/efivars -name 'SetupMode-*' 2>/dev/null | head -n1)"

    if [[ -z "$setup_mode_file" ]]; then
        return 1
    fi

    local setup_mode_value
    # EFI variable files have a 4-byte attribute header before the data; skip it
    setup_mode_value="$(od -An -j4 -N1 -t u1 "$setup_mode_file" | tr -d ' \n')"

    [[ "$setup_mode_value" == "1" ]]
}

# Install a Portage bashrc.d hook that re-signs all sbctl-registered EFI files
# after any sys-kernel package install. genkernel runs inside pkg_postinst, so
# post_pkg_postinst fires after the new kernel and initramfs are already on disk.
setup_portage_signing_hook() {
    local hook_dir="/etc/portage/bashrc.d"
    local hook_file="${hook_dir}/sbctl-sign.sh"

    mkdir -p "$hook_dir"

    if [[ -f "$hook_file" ]]; then
        echo "Portage signing hook already exists at $hook_file"
        return 0
    fi

    cat > "$hook_file" << 'EOF'
post_pkg_postinst() {
    [[ "${CATEGORY}" == "sys-kernel" ]] || return 0
    command -v sbctl >/dev/null 2>&1 || return 0
    echo ">>> Kernel updated: re-signing EFI binaries with sbctl..."
    sbctl sign-all || echo "WARNING: sbctl sign-all failed — verify Secure Boot signing"
}
EOF

    chmod 644 "$hook_file"
    echo "Installed Portage signing hook at $hook_file"
}

# Update /etc/crypttab to add tpm2-device=auto for the given LUKS UUID.
# Adds the option to an existing entry or appends a new entry if none is found.
update_crypttab() {
    local uuid="$1"
    local tmpfile
    tmpfile="$(mktemp)"
    local found=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# || -z "${line//[[:space:]]/}" ]]; then
            printf '%s\n' "$line"
            continue
        fi

        read -ra fields <<< "$line"
        if [[ "${fields[1]}" == "UUID=$uuid" ]]; then
            found=1
            local opts="${fields[3]:-}"
            if [[ -z "$opts" || "$opts" == "-" || "$opts" == "none" ]]; then
                opts="tpm2-device=auto,tpm2-pcrs=0+7"
            elif [[ "$opts" != *"tpm2-device"* ]]; then
                opts="$opts,tpm2-device=auto,tpm2-pcrs=0+7"
            fi
            printf '%s\t%s\t%s\t%s\n' "${fields[0]}" "UUID=$uuid" "${fields[2]:-none}" "$opts"
        else
            printf '%s\n' "$line"
        fi
    done < /etc/crypttab > "$tmpfile"

    if [[ "$found" -eq 0 ]]; then
        printf 'cryptroot\tUUID=%s\tnone\ttpm2-device=auto,tpm2-pcrs=0+7\n' "$uuid" >> "$tmpfile"
    fi

    cp /etc/crypttab /etc/crypttab.bak
    mv "$tmpfile" /etc/crypttab
    echo "Updated /etc/crypttab (backup saved to /etc/crypttab.bak)"
}

echo "Checking UEFI environment..."

if [[ ! -d /sys/firmware/efi ]]; then
    echo "ERROR: System is not booted in UEFI mode."
    echo "TPM + Secure Boot auto-unlock setup requires UEFI."
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "ERROR: EFI variables are unavailable."
    echo "Make sure efivarfs is mounted."
    exit 1
fi

if secure_boot_setup_mode_active; then
    echo "ERROR: Secure Boot is still in Setup Mode."
    echo "Enable Secure Boot first, boot successfully, then rerun this script."
    exit 1
fi

if ! secure_boot_enabled; then
    echo "ERROR: Secure Boot is not currently enabled."
    echo "This script requires Secure Boot to be active before binding to PCR 7."
    exit 1
fi

echo "Secure Boot is enabled and Setup Mode is not active."
echo

echo "Checking TPM2 support..."

if [[ ! -d /sys/class/tpm ]]; then
    echo "ERROR: No TPM device detected."
    exit 1
fi

if ! compgen -G "/dev/tpmrm*" > /dev/null && ! compgen -G "/dev/tpm*" > /dev/null; then
    echo "ERROR: No TPM character device found."
    exit 1
fi

if ! command -v systemd-cryptenroll >/dev/null 2>&1; then
    echo "ERROR: systemd-cryptenroll was not found."
    echo "Make sure this Gentoo install is using a systemd profile."
    exit 1
fi

echo "Detected block devices:"
lsblk -f
echo

read -rp "Enter encrypted LUKS partition, example /dev/nvme0n1p2 or /dev/sda2: " LUKS_PARTITION

if [[ -z "$LUKS_PARTITION" ]]; then
    echo "ERROR: No partition entered."
    exit 1
fi

if [[ ! -b "$LUKS_PARTITION" ]]; then
    echo "ERROR: $LUKS_PARTITION is not a valid block device."
    exit 1
fi

if ! cryptsetup isLuks "$LUKS_PARTITION"; then
    echo "ERROR: $LUKS_PARTITION is not a LUKS device."
    exit 1
fi

LUKS_UUID="$(blkid -s UUID -o value "$LUKS_PARTITION")"
if [[ -z "$LUKS_UUID" ]]; then
    echo "ERROR: Could not determine UUID for $LUKS_PARTITION"
    exit 1
fi

echo
echo "LUKS device confirmed: $LUKS_PARTITION (UUID=$LUKS_UUID)"
echo

echo "Current LUKS token/slot information:"
cryptsetup luksDump "$LUKS_PARTITION" | grep -Ei 'Version:|Keyslots:|Tokens:|systemd-tpm2|tpm2' || true
echo

read -rp "Enroll TPM2 auto-unlock using PCRs 0+7 for $LUKS_PARTITION? [y/N]: " CONFIRM

case "$CONFIRM" in
    [yY]|[yY][eE][sS])
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

echo
echo "Installing TPM2 support packages if needed..."

emerge --ask=n --verbose \
    app-crypt/tpm2-tools \
    app-crypt/tpm2-tss

echo
echo "Updating /etc/crypttab for TPM2 auto-unlock..."
update_crypttab "$LUKS_UUID"
echo

echo "Enrolling TPM2 unlock token (PCRs 0+7)..."
echo "You may be asked for your current LUKS passphrase."
echo

systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=0+7 \
    "$LUKS_PARTITION"

echo
echo "TPM2 enrollment complete."
echo

echo "Rebuilding initramfs..."
if command -v genkernel >/dev/null 2>&1; then
    genkernel --luks --lvm all
elif command -v dracut >/dev/null 2>&1; then
    dracut -f --kver "$(uname -r)"
else
    echo "WARNING: No initramfs builder found. Rebuild manually before rebooting."
fi

echo
echo "Regenerating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Signing updated EFI boot files if sbctl is installed..."

if command -v sbctl >/dev/null 2>&1; then
    for efi in \
        /boot/EFI/Gentoo/grubx64.efi \
        /boot/EFI/BOOT/BOOTX64.EFI; do
        [[ -f "$efi" ]] && sbctl sign -s "$efi"
    done

    for efi in /boot/*.efi /boot/EFI/Linux/*.efi; do
        [[ -f "$efi" ]] && sbctl sign -s "$efi"
    done

    sbctl verify || true
else
    echo "sbctl not found. Skipping Secure Boot re-signing."
fi

echo
echo "Installing Portage hook for automatic re-signing on kernel updates..."
setup_portage_signing_hook

echo
echo "======================================"
echo " TPM2 LUKS Auto-Unlock Setup Complete"
echo "======================================"
echo
echo "PCRs 0+7 measure firmware and Secure Boot state — kernel updates do not"
echo "change them, so your TPM binding will survive 'emerge --vuDU @world'."
echo "The Portage hook in /etc/portage/bashrc.d/sbctl-sign.sh will re-sign"
echo "new EFI files automatically whenever a kernel package is installed."
echo
echo "Reboot and test TPM unlock."
echo "Keep your LUKS passphrase available as recovery."
echo
