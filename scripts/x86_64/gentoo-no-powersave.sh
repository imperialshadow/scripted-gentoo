#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ -z "${GENTOO_POSTINSTALL}" ]]; then
    LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
    exec > >(tee "$LOG_FILE") 2>&1
fi

echo "================================"
echo " Disable All Power Saving"
echo "================================"
echo ""

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Audio — disable HDA Intel and AC97 power saving via modprobe options
# =============================================================================

cat > /etc/modprobe.d/no-powersave.conf << 'EOF'
options snd_hda_intel power_save=0 power_save_controller=N
options snd_ac97_codec power_save=0
EOF

# =============================================================================
# USB — disable autosuspend for all USB devices
# =============================================================================

cat > /etc/udev/rules.d/01-no-usb-autosuspend.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
EOF

# =============================================================================
# PCI devices — disable runtime power management
# =============================================================================

cat > /etc/udev/rules.d/02-no-pci-powersave.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="on"
EOF

# =============================================================================
# SATA — maximum performance link power management
# =============================================================================

cat > /etc/udev/rules.d/03-no-sata-powersave.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"
EOF

# =============================================================================
# NVMe — disable autonomous power state transitions
# =============================================================================

cat > /etc/udev/rules.d/04-no-nvme-powersave.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="nvme", ATTR{power/control}="on"
EOF

# =============================================================================
# CPU — performance governor via systemd service
# =============================================================================

cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU scaling governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$f" ] && echo performance > "$f"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cpu-performance.service

# =============================================================================
# WiFi — disable power saving via NetworkManager configuration
# wifi.powersave = 2 means disabled (3 = enabled, 1 = default)
# =============================================================================

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF

# =============================================================================
# Kernel parameters — USB autosuspend and PCIe ASPM via GRUB cmdline
# =============================================================================

GRUB_CONF="/etc/default/grub"
if ! grep -q "usbcore.autosuspend" "$GRUB_CONF"; then
    sed -i 's/\(GRUB_CMDLINE_LINUX=".*\)"/\1 usbcore.autosuspend=-1 pcie_aspm=off"/' "$GRUB_CONF"
    grub-mkconfig -o /boot/grub/grub.cfg
    echo "GRUB updated — reboot for USB and PCIe ASPM kernel parameters to take effect."
fi

# Apply udev rules immediately without rebooting
udevadm control --reload-rules
udevadm trigger

echo ""
echo "Done. Power saving disabled for audio, USB, PCI, SATA, NVMe, CPU, and WiFi."
echo "Reboot to activate kernel parameters (usbcore.autosuspend, pcie_aspm)."
