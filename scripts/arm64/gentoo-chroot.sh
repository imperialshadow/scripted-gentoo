#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
exec > >(tee "$LOG_FILE") 2>&1

source /etc/profile
export PS1="(gentoo) ${PS1}"

CREATE_SWAP=true
for arg in "$@"; do
    [[ "$arg" == "--no-swap" ]] && CREATE_SWAP=false
done

# =============================================================================
# Gentoo Chroot Setup
# Runs inside the new Gentoo installation to configure the full system.
# =============================================================================

echo "=============="
echo "Gentoo chroot"
echo "=============="

# =============================================================================
# Portage tree sync
# =============================================================================

# Fetch the latest portage snapshot then update to the absolute latest
emerge-webrsync
emerge --sync || true

# =============================================================================
# Profile selection
# =============================================================================

TARGET_PROFILE="default/linux/arm64/23.0/hardened/selinux/systemd"
if eselect profile list | grep -qF "$TARGET_PROFILE"; then
    eselect profile set "$TARGET_PROFILE"
else
    PROFILE_NUM=$(eselect profile list | grep -E 'linux/arm64/.*23\.0.*selinux.*systemd' | grep -v desktop | awk '{print $1}' | tr -d '[]' | head -n1)
    if [[ -z "$PROFILE_NUM" ]]; then
        echo "ERROR: Could not find a suitable hardened/selinux profile. Available profiles:"
        eselect profile list
        exit 1
    fi
    eselect profile set "$PROFILE_NUM"
fi

# =============================================================================
# GPU detection
# =============================================================================

# Detect CPU thread count for parallel compilation
CPU_JOBS="$(nproc)"
USER_MAKEOPTS="${CPU_JOBS}"

# Read GPU vendor IDs from sysfs — bind-mounted from host, no pciutils needed
# PCI class 0x0300xx = VGA, 0x0302xx = 3D, 0x0380xx = Display
GPU_VENDOR=""
for dev in /sys/bus/pci/devices/*/; do
    cls=$(cat "${dev}class" 2>/dev/null || true)
    case "$cls" in
        0x0300*|0x0302*|0x0380*)
            v=$(cat "${dev}vendor" 2>/dev/null || true)
            GPU_VENDOR="${GPU_VENDOR} ${v}"
            ;;
    esac
done
echo "GPU vendor IDs detected:${GPU_VENDOR}"

if echo "$GPU_VENDOR" | grep -qiE '0x1002'; then
    echo "AMD GPU detected."
    VIDEO_CARDS="amdgpu radeonsi"
    GPU_DRIVER_PKG="x11-drivers/xf86-video-amdgpu"

elif echo "$GPU_VENDOR" | grep -qiE '0x10de'; then
    echo "nVidia GPU detected."
    echo "NVIDIA's proprietary driver does not support aarch64 desktop systems."
    echo "Falling back to the open-source nouveau driver."
    VIDEO_CARDS="nouveau"
    GPU_DRIVER_PKG=""

else
    echo "No supported GPU detected - falling back to modesetting."
    VIDEO_CARDS="modesetting"
    GPU_DRIVER_PKG=""
fi

# =============================================================================
# make.conf
# =============================================================================

# Detect the active Python 3.x version to pin PYTHON_TARGETS, preventing
# stage3/portage-tree Python version slot conflicts during @world
PYTHON_VER=$(python3 -c "import sys; print(f'python{sys.version_info.major}_{sys.version_info.minor}')" 2>/dev/null || echo "python3_14")
echo "Python version detected: ${PYTHON_VER}"

cat > /etc/portage/make.conf << EOF
COMMON_FLAGS="-O3 -pipe -march=native -fstack-protector-strong"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${USER_MAKEOPTS} -l${USER_MAKEOPTS}"
LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="arm64-efi"
VIDEO_CARDS="${VIDEO_CARDS}"
PYTHON_SINGLE_TARGET="${PYTHON_VER}"
PYTHON_TARGETS="${PYTHON_VER}"
USE="X wayland policykit udev dbus pulseaudio pipewire gtk gtk3 opengl vulkan jpeg png svg networkmanager bluetooth ipv6 cups acl threads unicode selinux"
FEATURES="-selinux"
EOF

# =============================================================================
# Timezone and locale
# =============================================================================

ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime

cat > /etc/locale.gen << 'EOF'
en_US.UTF-8 UTF-8
EOF

locale-gen
eselect locale set en_US.utf8 || eselect locale set en_US.UTF-8

cat > /etc/env.d/02locale << 'EOF'
LANG="en_US.UTF-8"
LC_COLLATE="C.UTF-8"
EOF

env-update

source /etc/profile

# Activate swap before @world — LLVM, Clang, Firefox etc. need more memory
# than many machines have available at compile time.
if $CREATE_SWAP; then
    swapon /dev/vg0/swap 2>/dev/null || true
fi

# =============================================================================
# @world emerge
# =============================================================================

# Break the circular dependency between sys-libs/gpm and sys-libs/ncurses:
# ncurses has a gpm USE flag (enabled by the profile) that requires gpm to
# build, but gpm itself requires ncurses. Disable gpm on ncurses first, let
# @world complete, then rebuild ncurses with full gpm support.
mkdir -p /etc/portage/package.use
echo "sys-libs/ncurses -gpm" > /etc/portage/package.use/ncurses

# Update Portage before @world to avoid the stage3 Portage replacing itself mid-emerge,
# which fails with a Python import error when the old and new versions differ.
emerge --ask=n --oneshot sys-apps/portage sys-libs/libselinux sys-apps/policycoreutils

# Pre-populate USE overrides required by the dependency tree
cat > /etc/portage/package.use/world-overrides << 'EOF'
app-text/xmlto text
media-libs/freetype harfbuzz
xfce-base/thunar udisks
gnome-base/gvfs udisks
x11-libs/libdrm video_cards_radeon
media-libs/libcanberra alsa
media-libs/libglvnd X
net-firewall/iptables nftables
sys-apps/systemd cryptsetup
sys-fs/cryptsetup systemd
EOF

# Resolve dep graph with autounmask, writing any additionally needed changes
emerge --ask=n --backtrack=30 --autounmask-write --autounmask-backtrack=y --autounmask-only -vuDNU @world || {
    find /etc/portage -name '._cfg*' 2>/dev/null | while IFS= read -r cfg; do
        dir=$(dirname "$cfg")
        dest="${dir}/$(basename "${cfg}" | sed 's/^\._cfg[0-9]*_//')"
        mv "$cfg" "$dest"
    done
}

emerge --ask=n --backtrack=30 -vuDNU @world

# Re-enable gpm on ncurses and rebuild it now that gpm is installed.
rm /etc/portage/package.use/ncurses
emerge --ask=n --oneshot --verbose sys-libs/ncurses

emerge --ask=n --depclean

# =============================================================================
# System package installation
# =============================================================================

echo "sys-fs/lvm2 lvm" > /etc/portage/package.use/lvm2
emerge --ask=n --verbose \
    app-admin/sudo \
    sys-libs/libselinux \
    sys-apps/policycoreutils \
    app-editors/nano \
    app-portage/gentoolkit \
    app-shells/bash-completion \
    media-fonts/liberation-fonts \
    media-fonts/noto \
    media-libs/mesa \
    media-video/pipewire \
    media-video/wireplumber \
    net-fs/sshfs \
    net-libs/ldns \
    net-misc/networkmanager \
    net-misc/openssh \
    net-wireless/iwd \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-auth/rtkit \
    sys-boot/efibootmgr \
    sys-boot/grub \
    sys-fs/cryptsetup \
    sys-fs/lvm2 \
    sys-fs/e2fsprogs \
    sys-fs/dosfstools \
    sys-kernel/gentoo-sources \
    sys-kernel/genkernel \
    sys-kernel/linux-firmware \
    sys-process/audit \
    x11-base/xorg-server \
    x11-misc/sddm \
    x11-terms/xfce4-terminal \
    x11-themes/adwaita-icon-theme \
    xfce-base/xfce4-meta \
    xfce-extra/xfce4-pulseaudio-plugin \
    media-sound/pavucontrol \
    xfce-base/xfce4-power-manager \
    xfce-extra/xfce4-notifyd \
    xfce-extra/xfce4-screensaver \
    xfce-extra/xfce4-screenshooter \
    xfce-extra/xfce4-taskmanager \
    xfce-extra/thunar-archive-plugin \
    xfce-base/thunar-volman \
    gnome-extra/nm-applet \
    x11-misc/xdg-user-dirs

# Install the GPU driver package if one was detected earlier
if [[ -n "$GPU_DRIVER_PKG" ]]; then
    emerge --ask=n --verbose "$GPU_DRIVER_PKG"
fi

# =============================================================================
# Kernel build
# =============================================================================

KERNEL_ID="$(eselect kernel list | awk '/gentoo/ {print $1}' | head -n1 | tr -d '[]')"
if [[ -z "$KERNEL_ID" ]]; then
    echo "No Gentoo kernel source found."
    eselect kernel list
    exit 1
fi
eselect kernel set "$KERNEL_ID"

# Build kernel and initrd with LUKS, LVM, and systemd support
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

# LSM modules referenced in lsm= kernel cmdline parameter
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LANDLOCK=y
CONFIG_BPF_LSM=y

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

# GPU DRM drivers — modules so they load after root is mounted and can reach
# /lib/firmware/. Built-in drivers run before root mount and fail to find
# firmware. udev auto-loads the right driver via PCI modalias matching.
CONFIG_DRM=y
CONFIG_DRM_I915=m
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_NOUVEAU=m

# EFI framebuffer console — defconfig lacks this; without it the kernel
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

# Game controllers
CONFIG_JOYSTICK_XPAD=m
CONFIG_HID_SONY=m
CONFIG_HID_NINTENDO=m

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
cp /usr/src/linux/.config /tmp/gentoo-merged-kconfig
genkernel --luks --lvm all --kernel-config=/tmp/gentoo-merged-kconfig

# Sync any stale modules in updates/ to the newly built versions.
# depmod gives updates/ higher priority than kernel/ in its search order, so
# Portage-installed modules from @world can shadow the new genkernel build and
# cause module version mismatches at runtime (e.g. UFW xt_* revision errors).
KVER="$(ls /lib/modules/ | sort -V | tail -1)"
UPDATES_DIR="/lib/modules/${KVER}/updates"
if [[ -d "$UPDATES_DIR" ]]; then
    for ko in "${UPDATES_DIR}"/*.ko "${UPDATES_DIR}"/*.ko.xz "${UPDATES_DIR}"/*.ko.zst; do
        [[ -e "$ko" ]] || continue
        name="$(basename "$ko")"; name="${name%%.*}.ko"
        new_ko="$(find "/lib/modules/${KVER}/kernel" -name "$name" 2>/dev/null | head -1)"
        if [[ -n "$new_ko" ]]; then
            cp "$new_ko" "$ko"
        else
            rm -f "$ko"
        fi
    done
    depmod -a
fi

# =============================================================================
# Disk and partition configuration
# =============================================================================

lsblk
while true; do
    read -p "Enter target disk (example: /dev/nvme0n1): " DISK
    if [[ -n "$DISK" && -b "$DISK" ]]; then
        break
    fi
    echo "Invalid disk: '${DISK}'. Enter a valid block device (e.g. /dev/sda or /dev/nvme0n1)."
done

# NVMe disks end in a digit and use p1/p2 partition naming; SATA uses 1/2
if [[ "${DISK}" =~ [0-9]$ ]]; then
    PARTITION="${DISK}p2"
else
    PARTITION="${DISK}2"
fi

# Retrieve the LUKS partition UUID for bootloader and crypttab configuration
CRYPT_UUID=$(blkid -s UUID -o value "${PARTITION}")
if [[ -z "$CRYPT_UUID" ]]; then
    echo "Failed to detect LUKS UUID for ${PARTITION}"
    exit 1
fi

# Retrieve the EFI partition UUID for fstab
if [[ "${DISK}" =~ [0-9]$ ]]; then
    EFI_PART="${DISK}p1"
else
    EFI_PART="${DISK}1"
fi
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
if [[ -z "$EFI_UUID" ]]; then
    echo "Failed to detect EFI UUID for ${EFI_PART}"
    exit 1
fi

# =============================================================================
# fstab
# =============================================================================

cat > /etc/fstab << EOF
UUID=${EFI_UUID}        /boot   vfat    defaults,noatime    0 2
/dev/vg0/root           /       ext4    defaults,noatime    0 1
EOF
if $CREATE_SWAP; then
    echo "/dev/vg0/swap           none    swap    sw                  0 0" >> /etc/fstab
fi

# =============================================================================
# GRUB bootloader
# =============================================================================

# crypt_root instructs genkernel's initrd to unlock the LUKS partition at boot.
# dolvm tells the initrd to activate LVM volumes after unlocking.
cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Gentoo"
GRUB_CMDLINE_LINUX="crypt_root=UUID=${CRYPT_UUID} root=/dev/mapper/vg0-root rw dolvm security=selinux selinux=1 lsm=landlock,lockdown,yama,selinux,bpf gk.preserverun.disabled=1"
EOF

# Register the LUKS device for systemd. genkernel's crypt_root= maps the
# device as /dev/mapper/root; using the same name here prevents systemd
# from attempting a second unlock of an already-open device.
if ! grep -q "UUID=${CRYPT_UUID}" /etc/crypttab 2>/dev/null; then
    echo "root UUID=${CRYPT_UUID} none luks" >> /etc/crypttab
fi

grub-install \
    --target=arm64-efi \
    --efi-directory=/boot \
    --bootloader-id=Gentoo

grub-mkconfig -o /boot/grub/grub.cfg

# =============================================================================
# NetworkManager configuration
# =============================================================================

# Use iwd as the Wi-Fi backend instead of wpa_supplicant
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi_backend.conf << 'EOF'
[device]
wifi.backend=iwd
EOF

# =============================================================================
# Enable systemd services
# =============================================================================

systemctl enable sddm

# =============================================================================
# SDDM — Gentoo theme (installed inline so fresh installs get it without
# needing to run the post-install script separately)
# =============================================================================

mkdir -p /usr/share/sddm/themes/gentoo /etc/sddm.conf.d

# Copy Gentoo logo from GRUB theme
for _logo in /usr/share/grub/themes/gentoo_minimalist/gentoo_logo.png \
             /usr/share/grub/themes/gentoo_frosted/logo_frosted.png \
             /usr/share/grub/themes/gentoo_glass/logo_glass.png; do
    if [[ -f "$_logo" ]]; then
        cp "$_logo" /usr/share/sddm/themes/gentoo/logo.png
        break
    fi
done

# Qt6 SDDM builds rename the greeter binary but theme validation still checks
# the old name — create a compat symlink if needed
if [[ ! -e /usr/bin/sddm-greeter && -e /usr/bin/sddm-greeter-qt6 ]]; then
    ln -sf /usr/bin/sddm-greeter-qt6 /usr/bin/sddm-greeter
fi

cat > /usr/share/sddm/themes/gentoo/metadata.desktop << 'METAEOF'
[SddmGreeterTheme]
Name=Gentoo
Description=Gentoo Linux login theme — dark with Gentoo purple
Author=Imperial-Corsair
License=GPL-3.0+
Type=sddm-theme
Version=1.0
MainScript=Main.qml
METAEOF

cat > /usr/share/sddm/themes/gentoo/Main.qml << 'QMLEOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

Item {
    id: root
    width: Screen.width
    height: Screen.height

    Connections {
        target: sddm
        function onLoginFailed() {
            loginMessage.text = "Login failed — check your credentials."
            password.text = ""
            password.forceActiveFocus()
        }
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#1a1a2e" }
            GradientStop { position: 1.0; color: "#0f0f1e" }
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 380
        height: cardLayout.implicitHeight + 72
        radius: 12
        color: "#252535"

        ColumnLayout {
            id: cardLayout
            anchors {
                top: parent.top; left: parent.left; right: parent.right
                topMargin: 36; leftMargin: 36; rightMargin: 36
            }
            spacing: 14

            Rectangle {
                width: 72; height: 72; radius: 36
                color: "#9f7cda"
                Layout.alignment: Qt.AlignHCenter
                Text {
                    anchors.centerIn: parent
                    text: "g"; color: "white"
                    font.pixelSize: 44; font.bold: true
                }
            }

            Text {
                text: "Gentoo Linux"; color: "#cdd6f4"
                font.pixelSize: 20; font.weight: Font.Medium
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                id: loginMessage
                text: ""; visible: text !== ""; color: "#f38ba8"
                font.pixelSize: 12; wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            TextField {
                id: username
                Layout.fillWidth: true; height: 42
                text: userModel.lastUser; placeholderText: "Username"
                font.pixelSize: 14; color: "#cdd6f4"
                leftPadding: 12; rightPadding: 12
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: username.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                KeyNavigation.tab: password
                Keys.onReturnPressed: password.forceActiveFocus()
            }

            TextField {
                id: password
                Layout.fillWidth: true; height: 42
                placeholderText: "Password"; echoMode: TextInput.Password
                font.pixelSize: 14; color: "#cdd6f4"
                leftPadding: 12; rightPadding: 12
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: password.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                KeyNavigation.tab: sessionBox
                Keys.onReturnPressed: loginBtn.doLogin()
            }

            ComboBox {
                id: sessionBox
                Layout.fillWidth: true; height: 38
                model: sessionModel; textRole: "name"; font.pixelSize: 13
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: sessionBox.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                contentItem: Text {
                    leftPadding: 12; text: sessionBox.displayText
                    color: "#cdd6f4"; font: sessionBox.font
                    verticalAlignment: Text.AlignVCenter
                }
                KeyNavigation.tab: loginBtn
            }

            Button {
                id: loginBtn
                Layout.fillWidth: true; height: 44
                text: "Login"; font.pixelSize: 14; font.weight: Font.Medium
                function doLogin() {
                    loginMessage.text = ""
                    sddm.login(username.text, password.text, sessionBox.currentIndex)
                }
                background: Rectangle {
                    color: loginBtn.pressed ? "#7c5cc4"
                         : loginBtn.hovered ? "#b48de8" : "#9f7cda"
                    radius: 6
                    Behavior on color { ColorAnimation { duration: 100 } }
                }
                contentItem: Text {
                    text: loginBtn.text; font: loginBtn.font; color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: doLogin()
                Keys.onReturnPressed: doLogin()
            }

            Item { Layout.preferredHeight: 4 }
        }
    }

    Row {
        anchors { bottom: parent.bottom; right: parent.right; margins: 20 }
        spacing: 8
        Button {
            id: suspendBtn; text: "Suspend"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: suspendBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: suspendBtn.text; font: suspendBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.suspend()
        }
        Button {
            id: rebootBtn; text: "Reboot"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: rebootBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: rebootBtn.text; font: rebootBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.reboot()
        }
        Button {
            id: shutdownBtn; text: "Shutdown"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: shutdownBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: shutdownBtn.text; font: shutdownBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.powerOff()
        }
    }

    Component.onCompleted: {
        if (username.text === "") username.forceActiveFocus()
        else password.forceActiveFocus()
    }
}
QMLEOF

cat > /etc/sddm.conf.d/theme.conf << 'CONFEOF'
[Theme]
Current=gentoo

[General]
DefaultSession=xfce.desktop

[Wayland]
# Hide Wayland sessions — XFCE Wayland support is not stable
SessionDir=
CONFEOF
systemctl enable lvm2-monitor || true
systemctl enable iwd
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable systemd-timesyncd
systemctl enable auditd

# =============================================================================
# User and hostname creation
# =============================================================================

while true; do
    read -p "Enter username to create: " NEW_USER
    if [[ -n "$NEW_USER" ]]; then
        break
    fi
    echo "Username cannot be empty."
done

while true; do
    read -p "Enter hostname: " HOSTNAME
    if [[ -n "$HOSTNAME" ]]; then
        break
    fi
    echo "Hostname cannot be empty."
done

echo "$HOSTNAME" > /etc/hostname
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

# Ensure plugdev group exists before assigning the user to it
groupadd -f plugdev
useradd -m -G wheel,audio,video,input,plugdev -s /bin/bash "$NEW_USER"

# Map user to staff_u SELinux context — wheel members need staff_u to transition
# to sysadm_r via sudo; without this pam_selinux cannot obtain a valid context at login
semanage login -a -s unconfined_u "$NEW_USER" || true
semanage login -a -s unconfined_u root || true

# =============================================================================
# PipeWire audio stack — enable for $NEW_USER
# =============================================================================

_userd="/home/${NEW_USER}/.config/systemd/user"
mkdir -p "${_userd}/sockets.target.wants" "${_userd}/pipewire.service.wants"
ln -sf /usr/lib/systemd/user/pipewire.socket       "${_userd}/sockets.target.wants/pipewire.socket"
ln -sf /usr/lib/systemd/user/pipewire-pulse.socket "${_userd}/sockets.target.wants/pipewire-pulse.socket"
ln -sf /usr/lib/systemd/user/wireplumber.service   "${_userd}/pipewire.service.wants/wireplumber.service"
ln -sf /usr/lib/systemd/user/wireplumber.service   "${_userd}/pipewire-session-manager.service"
ln -sf /dev/null "${_userd}/pulseaudio.service"
ln -sf /dev/null "${_userd}/pulseaudio.socket"
chown -R "${NEW_USER}:${NEW_USER}" "${_userd}"

# WirePlumber 0.5 does not enable hardware.audio by default in its main profile.
# Copy the system conf to user override and uncomment hardware.audio.
mkdir -p "/home/${NEW_USER}/.config/wireplumber"
cp /usr/share/wireplumber/wireplumber.conf \
    "/home/${NEW_USER}/.config/wireplumber/wireplumber.conf"
sed -i 's/^    #hardware\.audio = required/    hardware.audio = required/' \
    "/home/${NEW_USER}/.config/wireplumber/wireplumber.conf"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.config/wireplumber"

# =============================================================================
# SELinux first-boot relabeling
# =============================================================================

touch /.autorelabel

# =============================================================================
# Passwords and sudo
# =============================================================================

echo "Set password for $NEW_USER"
echo "(If you see password quality suggestions below, they are advisory — your password will be set regardless)"
passwd "$NEW_USER"

# Uncomment the wheel group sudo rule if not already active
if ! grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

# Lock the root account now that the user has sudo access via wheel
passwd -l root

# =============================================================================
# Cleanup and first-boot preparation
# =============================================================================

# Remove this script from the installed system
rm -f /root/gentoo-chroot.sh

exit 0
