#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

echo "=========================="
echo " Steam Installer"
echo "=========================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# Steam requires 32-bit multilib — verify both make.conf and the active profile
if eselect profile show 2>/dev/null | grep -q 'no-multilib'; then
    echo "ERROR: Steam cannot be installed on a no-multilib profile."
    echo "Current profile: $(eselect profile show 2>/dev/null | tail -1 | xargs)"
    echo "Switch to a multilib profile first:"
    echo "  eselect profile list"
    echo "  eselect profile set <multilib-profile-number>"
    echo "  emerge --ask=n --update --deep --newuse @world"
    exit 1
fi

if ! grep -q 'ABI_X86.*32' /etc/portage/make.conf 2>/dev/null; then
    echo "ERROR: 32-bit multilib support not found in make.conf."
    echo "Steam requires ABI_X86=\"64 32\". Ensure the chroot setup ran correctly,"
    echo "then run: emerge --ask=n --update --deep --newuse @world"
    echo "before retrying this script."
    exit 1
fi

# =============================================================================
# Steam overlay repository
# =============================================================================

emerge --ask=n --noreplace app-eselect/eselect-repository dev-vcs/git

if ! eselect repository list | grep -q 'steam-overlay'; then
    eselect repository enable steam-overlay
    emaint sync -r steam-overlay
fi

# =============================================================================
# Portage configuration
# =============================================================================

mkdir -p /etc/portage/package.use
mkdir -p /etc/portage/package.license
mkdir -p /etc/portage/package.accept_keywords

# Accept the Steam proprietary license
cat > /etc/portage/package.license/steam << 'EOF'
games-util/steam-launcher ValveSteamLicense
EOF

# Accept keywords for steam-overlay packages
cat > /etc/portage/package.accept_keywords/steam << 'EOF'
*/*::steam-overlay
games-util/game-device-udev-rules
sys-libs/libudev-compat
EOF

# Enable 32-bit support for steam-launcher
cat > /etc/portage/package.use/steam << 'EOF'
games-util/steam-launcher abi_x86_32
EOF

# =============================================================================
# System limits required by Steam / Proton
# =============================================================================

# Memory mapping limit — Steam and Proton games routinely exceed the default
cat > /etc/sysctl.d/steam.conf << 'EOF'
vm.max_map_count = 1048576
EOF
sysctl -p /etc/sysctl.d/steam.conf

# File descriptor limit -- must sort after gentoo-pam.sh's 99-hardening.conf
# (pam_limits applies limits.d files in filename order and later entries for
# the same type+item win) or hardening's nofile=65536 silently overrides this.
rm -f /etc/security/limits.d/26-steam-nofile.conf
cat > /etc/security/limits.d/99-steam-nofile.conf << 'EOF'
*  hard  nofile  524288
EOF

# Shared memory tmpfs — required by Steam runtime
if ! grep -q '/dev/shm' /etc/fstab; then
    echo 'shm  /dev/shm  tmpfs  nodev,nosuid,noexec  0 0' >> /etc/fstab
    mount -a 2>/dev/null || true
fi

# =============================================================================
# Package installation
# =============================================================================

emerge --ask=n --verbose \
    games-util/steam-launcher \
    games-util/game-device-udev-rules \
    sys-libs/libudev-compat

# =============================================================================
# UFW — outgoing ports required for Steam
#
# Store browsing and game downloads use 443/80 (already open).
# The following are additionally required for the Steam client, multiplayer,
# and content delivery servers:
#   27015-27036/tcp+udp — Steam game servers, content delivery, matchmaking
#   3478/udp            — Steam datagram relay (SDR) / STUN
#   4380/udp            — Steam datagram relay (SDR)
# =============================================================================
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow out proto tcp to any port 27015:27036 comment 'Steam'
    ufw allow out proto udp to any port 27015:27036 comment 'Steam'
    ufw allow out proto udp to any port 3478 comment 'Steam SDR'
    ufw allow out proto udp to any port 4380 comment 'Steam SDR'
    echo "UFW: Steam ports opened."
else
    echo "UFW not active — skipping firewall rules."
fi

echo
echo "Steam installed successfully."
echo
echo "Run as a regular (non-root) user: steam"
echo "Steam will download and set up the Steam runtime on first launch."
