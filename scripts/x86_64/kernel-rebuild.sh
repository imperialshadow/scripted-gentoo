#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Kernel rebuild — run inside a Gentoo chroot.
# Invoked by gentoo-live-chroot.sh; do not run directly from the live environment.
# Usage: kernel-rebuild.sh luks|noluks

set -eo pipefail

if [[ -z "$1" ]]; then
    echo "Usage: $0 luks|noluks"
    exit 1
fi

source /etc/profile

echo "==============================="
echo " Gentoo Kernel Rebuild"
echo "==============================="
echo ""

# Ensure the gentoo-sources symlink is set
KERNEL_ID="$(eselect kernel list | awk '/gentoo/ {print $1}' | head -n1 | tr -d '[]')"
if [[ -z "$KERNEL_ID" ]]; then
    echo "ERROR: No Gentoo kernel source found."
    eselect kernel list
    exit 1
fi
eselect kernel set "$KERNEL_ID"

cat > /tmp/gentoo-extra-kconfig << 'KEOF'
# SELinux MAC security module
CONFIG_SECURITY=y
CONFIG_AUDIT=y
CONFIG_SECURITY_PATH=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_SELINUX_AVC_STATS=y
CONFIG_SECURITY_SELINUX_CHECKREQPROT_VALUE=0

# LSM modules referenced in lsm= kernel cmdline parameter
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LANDLOCK=y
CONFIG_BPF_LSM=y

# Netfilter / iptables — required for UFW firewall
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=m
# nf_tables — modern netfilter core; must precede xtables and compat
CONFIG_NF_TABLES=m
CONFIG_NF_TABLES_INET=y
CONFIG_NF_TABLES_IPV4=y
CONFIG_NF_TABLES_IPV6=y
CONFIG_NFT_COMPAT=m
CONFIG_NFT_FILTER=m
CONFIG_NF_NAT=m
# xtables infrastructure (depends on NF_TABLES in 6.x)
CONFIG_NETFILTER_XTABLES=m
# Gate that unlocks all xt_match/xt_target extension modules below;
# make olddefconfig silently drops XT_MATCH_* if this is not set first
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=m
CONFIG_NETFILTER_XT_MATCH_HL=m
CONFIG_NETFILTER_XT_TARGET_HL=m
CONFIG_NETFILTER_XT_MATCH_LIMIT=m
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=m
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=m
CONFIG_NETFILTER_XT_MATCH_RECENT=m
CONFIG_NETFILTER_XT_MATCH_STATE=m
CONFIG_NETFILTER_XT_MATCH_TCP=m
CONFIG_NETFILTER_XT_MATCH_UDP=m
CONFIG_NETFILTER_XT_TARGET_LOG=m
CONFIG_NETFILTER_XT_TARGET_NFLOG=m
CONFIG_NETFILTER_XT_TARGET_TCPMSS=m
CONFIG_NETFILTER_XT_MATCH_POLICY=m
CONFIG_NETFILTER_XT_TARGET_SECMARK=m
CONFIG_NFT_REJECT=m
CONFIG_IP_NF_NAT=m
CONFIG_IP_NF_TARGET_REJECT=m
CONFIG_IP6_NF_TARGET_REJECT=m
CONFIG_IP6_NF_MATCH_RT=m

# Storage controller drivers — built-in so the disk is visible in the initrd
# before any module loading. As modules, genkernel may not detect them during
# a chroot build and exclude them from the initramfs.
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
# eMMC/MMC/SD storage — required for mmcblk devices (eMMC laptops, SBCs)
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
CONFIG_MMC_SDHCI_ACPI=y
CONFIG_MMC_SDHCI_PLTFM=y
CONFIG_MMC_DW=y

# LUKS/dm-crypt — required to unlock encrypted root partition in the initrd
CONFIG_BLK_DEV_DM=y
CONFIG_DM_CRYPT=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_XTS=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA512=y
CONFIG_CRYPTO_HMAC=y

# DES/3DES — required by iwd for certain WPA-Enterprise/TLS cipher suites;
# without it iwd.service fails to start (kernel crypto self-check at boot)
CONFIG_CRYPTO_DES=m

# GPU DRM drivers — modules so they load after root is mounted and can reach
# /lib/firmware/. Built-in drivers run before root mount and fail to find
# firmware. udev auto-loads the right driver via PCI modalias matching.
CONFIG_DRM=y
CONFIG_DRM_I915=m
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_NOUVEAU=m

# EFI framebuffer console — x86_64_defconfig lacks this; without it the kernel
# has no display output on UEFI systems after GRUB hands off, making the boot
# appear frozen at "loading initial ramdisk"
CONFIG_FB=y
CONFIG_FB_EFI=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FONT_8x16=y

# exFAT filesystem support — required to mount exFAT-formatted USB drives
CONFIG_EXFAT_FS=m
CONFIG_EXFAT_DEFAULT_IOCHARSET="utf8"

# Touchscreen support
# INPUT_TOUCHSCREEN=y enables the touchscreen driver subsystem
CONFIG_INPUT_TOUCHSCREEN=y
# HID multitouch — handles most modern USB/Bluetooth multitouch devices
CONFIG_HID_MULTITOUCH=m
# I2C-HID — covers virtually all modern laptop/tablet internal touchscreens
CONFIG_I2C=y
CONFIG_I2C_HID=m
CONFIG_I2C_HID_ACPI=m
CONFIG_I2C_HID_OF=m
# Intel DesignWare I2C controller — required on Intel Atom/Celeron (Apollo/Gemini Lake)
# Without this the I2C bus never comes up and I2C-HID finds no devices
CONFIG_I2C_DESIGNWARE_CORE=m
CONFIG_I2C_DESIGNWARE_PLATFORM=m
CONFIG_I2C_DESIGNWARE_PCI=m
# Intel GPIO pinctrl — routes I2C touchpad interrupt lines on Intel platforms
CONFIG_PINCTRL_INTEL=m
# Gemini Lake (N4000/N5000) and Apollo Lake (N3350/N4200) platform pinctrl
# Required for I2C interrupt routing on these Intel Celeron/Atom SoCs
CONFIG_PINCTRL_GEMINILAKE=m
CONFIG_PINCTRL_BROXTON=m

# Microsoft Surface tablet support
# N-trig touchscreen — Surface Pro 4 and older Surface devices
CONFIG_HID_NTRIG=m
# Surface Aggregator Module — Surface Serial Hub bus (upstreamed kernel 5.15+)
# Required for touch, Type Cover, battery, and button communication
CONFIG_SURFACE_AGGREGATOR=m
CONFIG_SURFACE_AGGREGATOR_BUS=y
CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=m
CONFIG_SURFACE_HID=m
CONFIG_SURFACE_BUTTON=m
CONFIG_SURFACE_ACPI_NOTIFY=m
CONFIG_SURFACE_HOTPLUG=m
CONFIG_SURFACE_DTX=m
# Intel ITHC — touchscreen controller on newer Surface models
CONFIG_MISC_ITHC=m
# USB touchscreens (external monitors, older devices)
CONFIG_TOUCHSCREEN_USB_COMPOSITE=m
# Common vendor touchscreen drivers
CONFIG_TOUCHSCREEN_ELAN=m
CONFIG_TOUCHSCREEN_GOODIX=m
CONFIG_TOUCHSCREEN_ATMEL_MXT=m
CONFIG_TOUCHSCREEN_SYNAPTICS_I2C_RMI4=m
CONFIG_TOUCHSCREEN_EDT_FT5X06=m

# Signature pad / graphics tablet support
# INPUT_TABLET=y enables the tablet input driver subsystem
CONFIG_INPUT_TABLET=y
# Wacom — covers Wacom signature pads and tablets via HID
CONFIG_HID_WACOM=m
# Wacom older USB tablets and signature pads
CONFIG_TABLET_USB_WACOM=m
# Other tablet vendors (Acecad, GTCO CalComp, etc.)
CONFIG_TABLET_USB_ACECAD=m
CONFIG_TABLET_USB_GTCO=m

# Touchpad support
# INPUT_MOUSE=y enables the mouse/touchpad driver subsystem
CONFIG_INPUT_MOUSE=y
# INPUT_EVDEV=m provides /dev/input/eventX — required by libinput/X11/Wayland
CONFIG_INPUT_EVDEV=m
# PS/2 touchpads (older and mid-range laptops)
CONFIG_MOUSE_PS2=m
CONFIG_MOUSE_PS2_ALPS=y
CONFIG_MOUSE_PS2_SYNAPTICS=y
CONFIG_MOUSE_PS2_ELANTECH=y
CONFIG_MOUSE_PS2_FOCALTECH=y
# Elan I2C touchpad (common on modern laptops)
CONFIG_MOUSE_ELAN_I2C=m
CONFIG_MOUSE_ELAN_I2C_I2C=y
CONFIG_MOUSE_ELAN_I2C_SMBUS=y

# Audio support
# Core ALSA subsystem
CONFIG_SOUND=y
CONFIG_SND=m
CONFIG_SND_TIMER=m
CONFIG_SND_PCM=m
CONFIG_SND_JACK=y
# HDA — covers most Intel, AMD, and NVIDIA audio hardware
CONFIG_SND_HDA_INTEL=m
CONFIG_SND_HDA_CODEC_REALTEK=m
CONFIG_SND_HDA_CODEC_ANALOG=m
CONFIG_SND_HDA_CODEC_SIGMATEL=m
CONFIG_SND_HDA_CODEC_VIA=m
CONFIG_SND_HDA_CODEC_HDMI=m
CONFIG_SND_HDA_CODEC_CONEXANT=m
CONFIG_SND_HDA_GENERIC=m
# USB audio devices
CONFIG_SND_USB_AUDIO=m
# ASoC/SOF — newer Intel and AMD platforms (e.g. Ryzen with SOF firmware)
CONFIG_SND_SOC=m

# TPM — required for gentoo-tpm.sh; without these the TPM device will not enumerate
CONFIG_TCG_TPM=m
CONFIG_TCG_TIS=m
CONFIG_TCG_CRB=m
CONFIG_TCG_TIS_I2C=m

# Userspace crypto API — required by bluez for key exchange
CONFIG_CRYPTO_USER=m
CONFIG_CRYPTO_SHA1=y
# Kernel keyring DH operations — required by keyutils
CONFIG_KEY_DH_OPERATIONS=y

# Hardware crypto acceleration — AES-NI/SSSE3 significantly speeds up LUKS2 disk I/O
CONFIG_CRYPTO_AES_NI_INTEL=m
CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL=m
CONFIG_CRYPTO_SHA256_SSSE3=m
CONFIG_CRYPTO_SHA512_SSSE3=m
CONFIG_CRYPTO_CRC32C_INTEL=m

# Bluetooth
CONFIG_BT=m
CONFIG_BT_HCIBTUSB=m
CONFIG_BT_RFCOMM=m
CONFIG_BT_RFCOMM_TTY=y
CONFIG_BT_BNEP=m
CONFIG_BT_BNEP_MC_FILTER=y
CONFIG_BT_BNEP_PROTO_FILTER=y
CONFIG_BT_HIDP=m
CONFIG_BT_LE=y

# Webcam / USB video (UVC covers virtually all USB webcams)
CONFIG_MEDIA_SUPPORT=m
CONFIG_MEDIA_CAMERA_SUPPORT=y
CONFIG_MEDIA_USB_SUPPORT=y
CONFIG_VIDEO_DEV=m
CONFIG_USB_VIDEO_CLASS=m

# IOMMU — DMA protection; important on a hardened/SELinux system
CONFIG_IOMMU_SUPPORT=y
CONFIG_INTEL_IOMMU=y
CONFIG_AMD_IOMMU=y

# KVM virtualisation
CONFIG_KVM=m
CONFIG_KVM_INTEL=m
CONFIG_KVM_AMD=m
CONFIG_VHOST_NET=m

# Thunderbolt / USB4
CONFIG_THUNDERBOLT=m
CONFIG_USB4=m

# VPN and KVM networking
CONFIG_TUN=m
CONFIG_WIREGUARD=m
CONFIG_VETH=m
CONFIG_BRIDGE=m

# Virtio — paravirtual drivers for running as a VM guest
CONFIG_VIRTIO=m
CONFIG_VIRTIO_PCI=m
CONFIG_VIRTIO_BLK=m
CONFIG_VIRTIO_NET=m
CONFIG_VIRTIO_CONSOLE=m
CONFIG_VIRTIO_INPUT=m

# AMD P-state — modern CPU frequency driver for Ryzen (better than acpi-cpufreq)
CONFIG_X86_AMD_PSTATE=y

# Hardware monitoring
CONFIG_HWMON=m
CONFIG_SENSORS_K10TEMP=m
CONFIG_SENSORS_CORETEMP=m

# Filesystem extras
CONFIG_FUSE_FS=m
CONFIG_NTFS3_FS=m
CONFIG_FANOTIFY=y

# WiFi — core subsystem (required by all WiFi drivers)
CONFIG_WIRELESS=y
CONFIG_WLAN=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_CFG80211_WEXT=y
# Intel WiFi (AX200/AX201/AX210 and older 7xxx/8xxx/9xxx series)
CONFIG_IWLWIFI=m
CONFIG_IWLDVM=m
CONFIG_IWLMVM=m
# Realtek WiFi (RTW88: RTL8822BE/CE, RTL8821CE — very common on modern laptops)
CONFIG_RTW88=m
CONFIG_RTW88_8822BE=m
CONFIG_RTW88_8822CE=m
CONFIG_RTW88_8821CE=m
# Realtek WiFi 6/6E (RTW89: RTL8852AE/BE — newer laptops)
CONFIG_RTW89=m
CONFIG_RTW89_8852AE=m
CONFIG_RTW89_8852BE=m
# Qualcomm/Atheros WiFi
CONFIG_ATH9K=m
CONFIG_ATH10K=m
CONFIG_ATH10K_PCI=m
CONFIG_ATH11K=m
CONFIG_ATH11K_PCI=m
# MediaTek WiFi (MT7921 common on AMD Ryzen platforms)
CONFIG_MT76=m
CONFIG_MT7921E=m
CONFIG_MT7921U=m
# Broadcom WiFi (BCM43xx — Raspberry Pi and some laptops)
CONFIG_BRCMFMAC=m

# Laptop platform drivers
CONFIG_DELL_WMI=m
CONFIG_DELL_LAPTOP=m
CONFIG_ASUS_WMI=m
CONFIG_THINKPAD_ACPI=m
CONFIG_HP_WMI=m

# Container support (Docker/Podman)
CONFIG_OVERLAY_FS=m
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_CGROUP_BPF=y

# USB serial (Arduino, microcontrollers)
CONFIG_USB_SERIAL=m
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
CONFIG_USB_SERIAL_CH341=m

# Network filesystems
CONFIG_NFS_FS=m
CONFIG_CIFS=m

# Game controllers and HID
CONFIG_JOYSTICK_XPAD=m
CONFIG_HID_SONY=m
CONFIG_HID_NINTENDO=m
# UHID — user-space HID driver; required by bluez for Bluetooth HID (gamepads, mice)
CONFIG_UHID=m

# Steam / Proton requirements
# CONFIG_INPUT_UINPUT — virtual input device (Steam controller mapping, uinput)
CONFIG_INPUT_UINPUT=m
# CONFIG_NTSYNC — kernel-level NT sync primitives (required by GE-Proton / Proton 11+)
CONFIG_NTSYNC=m

# USB Ethernet adapters
CONFIG_USB_NET_DRIVERS=m
CONFIG_USB_USBNET=m

# ACPI power management (battery, brightness, fan)
CONFIG_ACPI_BATTERY=m
CONFIG_ACPI_AC=m
CONFIG_ACPI_VIDEO=m
CONFIG_ACPI_FAN=m
CONFIG_ACPI_THERMAL=m
CONFIG_ACPI_BUTTON=m
CONFIG_ACPI_PROCESSOR=m
CONFIG_ACPI_PLATFORM_PROFILE=m

# EFI variables — required by sbctl and efibootmgr for Secure Boot management
CONFIG_EFIVAR_FS=m

# WMI base driver — required by DELL_WMI, ASUS_WMI, HP_WMI
CONFIG_ACPI_WMI=m

# Dell BIOS sensors — fan speed and temperature via SMM calls
CONFIG_SENSORS_DELL_SMM=m

# Motherboard SuperIO sensors (desktops)
CONFIG_SENSORS_NCT6775=m
CONFIG_SENSORS_IT87=m

# Software RAID (mdadm)
CONFIG_MD=y
CONFIG_BLK_DEV_MD=y
CONFIG_MD_RAID0=y
CONFIG_MD_RAID1=y
CONFIG_MD_RAID10=y
CONFIG_MD_RAID456=y
CONFIG_MD_LINEAR=y
# Device Mapper RAID — used by LVM RAID
CONFIG_DM_RAID=y

# Hardware RAID controllers
# LSI/Broadcom MegaRAID SAS (Dell PERC, IBM ServeRAID, HP)
CONFIG_MEGARAID_SAS=y
# HP Smart Array
CONFIG_HPSA=y
# Adaptec AACRAID
CONFIG_AACRAID=y
# LSI MPT Fusion SAS 3.0
CONFIG_MPT3SAS=y
# Intel Volume Management Device (VROC NVMe RAID)
CONFIG_VMD=y
# Asus Prime X399-A (AMD Threadripper / X399 chipset) platform support
# Intel I211-AT dual Gigabit LAN — both onboard NICs use the igb driver
CONFIG_IGB=m
# AMD X399 SMBus — required for hwmon fan/temperature sensors on AMD chipsets
CONFIG_I2C_PIIX4=m
# AMD Platform Security Processor / Cryptographic Co-Processor
# Enables fTPM on Threadripper and provides hardware crypto offload
CONFIG_CRYPTO_DEV_CCP=m
CONFIG_CRYPTO_DEV_CCP_DD=m
# USB host controllers — xHCI (USB 3.x) and eHCI (USB 2.0)
CONFIG_USB_XHCI_HCD=m
CONFIG_USB_XHCI_PCI=m
CONFIG_USB_EHCI_HCD=m
CONFIG_USB_EHCI_PCI=m
# USB storage — USB flash drives and external HDDs
CONFIG_USB_STORAGE=m
# UAS (USB Attached SCSI) — significantly faster protocol for USB 3.x SSDs
CONFIG_USB_UAS=m
# USB Type-C (rear Type-C port on X399-A)
CONFIG_TYPEC=m
# PCIe SR-IOV — enables virtual functions for GPU passthrough (3x PCIe x16 slots)
CONFIG_PCI_IOV=y
# PCIe hotplug — native PCIe slot hotplug support
CONFIG_HOTPLUG_PCI=y
CONFIG_HOTPLUG_PCI_PCIE=y
# Hardware RNG — kernel entropy pool seeding via CPU RDRAND/RDSEED instruction
CONFIG_HW_RANDOM=m
CONFIG_HW_RANDOM_INTEL=m

# Dell PowerEdge T320 / T330 server platform support
# Broadcom BCM5720 dual Gigabit LAN — default onboard NIC on both T320 and T330
# Without this driver the machine boots with no wired network
CONFIG_TIGON3=m
# IPMI / iDRAC — BMC communication, fan control, and system event log
# Without IPMI drivers the iDRAC locks fans at 100% and is unreachable from the OS
CONFIG_IPMI_HANDLER=m
CONFIG_IPMI_DEVICE_INTERFACE=m
CONFIG_IPMI_SI=m
CONFIG_IPMI_SSIF=m
CONFIG_IPMI_WATCHDOG=m
# EDAC — ECC memory error detection and correction reporting
CONFIG_EDAC=m
# Sandy/Ivy Bridge ECC — T320 (Xeon E5-2400 v1/v2, Intel C600 chipset)
CONFIG_EDAC_SB_ECC=m
# Skylake Xeon ECC — T330 (Xeon E3-1200 v5/v6, Intel C232/C236 chipset)
CONFIG_EDAC_SKX=m
# PMBus — PSU power consumption, efficiency, and temperature monitoring
CONFIG_PMBUS=m
CONFIG_SENSORS_PMBUS=m
# Intel TCO hardware watchdog — built into C600/C232/C236 chipsets
CONFIG_ITCO_WDT=m
# NIC bonding — active-backup or LACP teaming of the dual onboard ports
CONFIG_BONDING=m
# iDRAC Direct USB virtual NIC — management interface via USB cable
CONFIG_USB_NET_CDC_NCM=m
# Serial console — iDRAC Serial-over-LAN (SOL) and physical COM1 port
CONFIG_SERIAL_8250=m
CONFIG_SERIAL_8250_PCI=m
CONFIG_SERIAL_8250_CONSOLE=y

KEOF
# Save fragment persistently so autoupdate.sh can re-apply it on future kernel updates
mkdir -p /etc/kernel
cp /tmp/gentoo-extra-kconfig /etc/kernel/gentoo-extra-kconfig

# --kernel-append-config is not supported in genkernel 4.3.x; merge the config
# fragment using the kernel's own tooling before handing off to genkernel
make -C /usr/src/linux defconfig
(cd /usr/src/linux && scripts/kconfig/merge_config.sh -m .config /tmp/gentoo-extra-kconfig)
make -C /usr/src/linux olddefconfig
# Stage outside the kernel tree — genkernel runs make mrproper which deletes
# .config, then copies --kernel-config into place
cp /usr/src/linux/.config /tmp/gentoo-merged-kconfig

if [[ "$1" == "luks" ]]; then
    genkernel --luks --lvm all --kernel-config=/tmp/gentoo-merged-kconfig
else
    genkernel all --kernel-config=/tmp/gentoo-merged-kconfig
fi

# Sync any modules in the updates/ directory to the newly built versions.
# depmod gives updates/ higher priority than kernel/ in its search order, so
# stale pre-rebuild modules in updates/ would shadow the new builds otherwise.
KVER="$(ls /lib/modules/ | sort -V | tail -1)"
UPDATES_DIR="/lib/modules/${KVER}/updates"
if [[ -d "$UPDATES_DIR" ]]; then
    echo "Syncing updates/ modules to new kernel build..."
    for ko in "${UPDATES_DIR}"/*.ko "${UPDATES_DIR}"/*.ko.xz "${UPDATES_DIR}"/*.ko.zst; do
        [[ -e "$ko" ]] || continue
        name="$(basename "$ko")"; name="${name%%.*}.ko"
        new_ko="$(find "/lib/modules/${KVER}/kernel" -name "$name" 2>/dev/null | head -1)"
        if [[ -n "$new_ko" ]]; then
            cp "$new_ko" "$ko"
        else
            # No match in kernel/ — module is now built-in (=y) or dropped.
            # Remove the stale updates/ copy so depmod doesn't load it and
            # cause CRC/vermagic mismatches in dependent modules.
            rm -f "$ko"
        fi
    done
    depmod -a
    echo "updates/ sync complete."
fi

echo ""
echo "Kernel rebuild complete."

# =============================================================================
# Re-sign boot files for Secure Boot
# sbctl tracks the signing database — any file registered with -s is
# re-signed here automatically after each kernel build.
# =============================================================================

if command -v sbctl >/dev/null 2>&1 && [[ -d /var/lib/sbctl/keys ]]; then
    echo ""
    echo "Re-signing boot files for Secure Boot..."

    sign_if_exists() {
        local f="$1"
        [[ -f "$f" ]] && sbctl sign -s "$f"
    }

    sign_if_exists /boot/EFI/Gentoo/grubx64.efi
    sign_if_exists /boot/EFI/BOOT/BOOTX64.EFI
    sign_if_exists /boot/grub/x86_64-efi/grub.efi
    sign_if_exists /boot/grub/x86_64-efi/core.efi

    for f in /boot/vmlinuz /boot/vmlinuz-* /boot/kernel-*; do
        sign_if_exists "$f"
    done

    for f in /boot/*.efi /boot/EFI/Linux/*.efi; do
        sign_if_exists "$f"
    done

    echo "Secure Boot signing complete."
    sbctl verify || true
else
    echo ""
    echo "sbctl not found or no keys enrolled — skipping Secure Boot signing."
fi
