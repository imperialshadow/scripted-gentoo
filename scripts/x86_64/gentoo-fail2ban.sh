#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure fail2ban with UFW integration and escalating bans
set -eo pipefail

echo "================================"
echo " Gentoo fail2ban Setup"
echo "================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "Installing fail2ban..."
USE="systemd" emerge --ask=n net-analyzer/fail2ban

mkdir -p /etc/fail2ban/jail.d

# =============================================================================
# Global defaults
# =============================================================================

tee /etc/fail2ban/jail.d/local.conf > /dev/null << 'EOF'
[DEFAULT]
# Never ban localhost
ignoreip = 127.0.0.1/8 ::1

# Initial ban: 15 minutes, detection window: 1 hour, threshold: 3 failures
bantime  = 15m
findtime = 1h
maxretry = 3

# Escalating bans: doubles each offence, capped at 1 year
# bantime.overalljails counts failures across all jails for the same IP
bantime.increment    = true
bantime.factor       = 2
bantime.max          = 52w
bantime.overalljails = true

# Read logs from journald (systemd backend — no logpath needed)
backend = systemd

# Ban via UFW rather than raw iptables since UFW manages the firewall
banaction          = ufw
banaction_allports = ufw
EOF

# =============================================================================
# SSH jail
# =============================================================================

tee /etc/fail2ban/jail.d/sshd.conf > /dev/null << 'EOF'
[sshd]
enabled = true
port    = ssh
EOF

# =============================================================================
# Enable and start
# =============================================================================

echo "Enabling fail2ban service..."
systemctl enable --now fail2ban.service

echo
echo "fail2ban status:"
fail2ban-client status || true

echo
echo "SSH jail status:"
fail2ban-client status sshd || true

echo
echo "fail2ban configured and enabled."
