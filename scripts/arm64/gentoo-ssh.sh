#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Harden OpenSSH — modern host keys, strong ciphers, and locked-down sshd_config
set -eo pipefail

echo "============================="
echo " Gentoo SSH Hardening"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n net-misc/openssh

# =============================================================================
# Host keys — regenerate using only modern algorithms
# Remove DSA (1024-bit, broken) and ECDSA (NIST curves, trust concerns)
# =============================================================================

echo "Regenerating host keys..."
rm -f /etc/ssh/ssh_host_dsa_key* \
      /etc/ssh/ssh_host_ecdsa_key* \
      /etc/ssh/ssh_host_ed25519_key* \
      /etc/ssh/ssh_host_rsa_key*

ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
ssh-keygen -t rsa     -b 4096 -f /etc/ssh/ssh_host_rsa_key     -N "" -q

# =============================================================================
# DH moduli — remove groups smaller than 3072 bits
# Logjam attack exploits small DH groups used during key exchange
# Column 5 in /etc/ssh/moduli is the group size in bits
# =============================================================================

echo "Filtering weak DH moduli..."
awk '$5 >= 3072' /etc/ssh/moduli > /etc/ssh/moduli.tmp
mv /etc/ssh/moduli.tmp /etc/ssh/moduli

# =============================================================================
# sshd_config
# =============================================================================

tee /etc/ssh/sshd_config > /dev/null << 'EOF'
# =============================================================================
# Network
# =============================================================================
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# =============================================================================
# Host keys — Ed25519 first (preferred), RSA 4096 for compatibility
# DSA and ECDSA keys have been removed
# =============================================================================
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# =============================================================================
# Ciphers and algorithms
# Only modern authenticated ciphers, ETM MACs, and safe KEX algorithms
# Excludes: CBC ciphers, MD5/SHA1 MACs, DH group1/14, NIST EC curves
# =============================================================================
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com

# =============================================================================
# Authentication
# =============================================================================
LoginGraceTime 30
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
MaxSessions 5

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Password authentication is enabled — fail2ban handles brute force attempts
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# Keep PAM for account locking, session setup, and limits
UsePAM yes

IgnoreRhosts yes
HostbasedAuthentication no

# =============================================================================
# Idle timeout
# Sends a keepalive every 5 minutes; disconnects after 2 missed responses
# (10 minutes total idle time before disconnect)
# =============================================================================
ClientAliveInterval 300
ClientAliveCountMax 2

# =============================================================================
# Forwarding — disabled; enable individually if needed
# =============================================================================
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# =============================================================================
# Logging
# VERBOSE logs the fingerprint of keys used for each authentication — useful
# for detecting key misuse via auditd/journald
# =============================================================================
SyslogFacility AUTH
LogLevel VERBOSE

# =============================================================================
# Misc
# =============================================================================
PrintLastLog yes
UseDNS no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
EOF

# =============================================================================
# Validate config then enable and restart
# =============================================================================

echo "Validating sshd configuration..."
sshd -t

echo "Enabling sshd service..."
systemctl enable --now sshd.service

echo "Restarting sshd..."
systemctl restart sshd.service

# =============================================================================
# User SSH key generation
# Generate an ed25519 key pair for every non-system account (UID >= 1000)
# that has a real login shell. The private key stays on this machine;
# copy ~/.ssh/id_ed25519 to the client to enable key-based login.
# =============================================================================

while IFS=: read -r USERNAME _ USER_UID _ _ HOME SHELL; do
    [[ "$USER_UID" -lt 1000 ]] && continue
    [[ "$SHELL" == */nologin || "$SHELL" == */false ]] && continue

    SSH_DIR="${HOME}/.ssh"
    KEY="${SSH_DIR}/id_ed25519"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "$SSH_DIR"
    touch "$AUTH_KEYS"

    if [[ -f "$KEY" ]]; then
        echo "Key already exists for ${USERNAME}, skipping."
        continue
    fi

    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${USERNAME}@$(hostname)" -q
    echo "Generated ed25519 key pair for ${USERNAME}."

    # Add this user's public key to their own authorized_keys if not already present
    if ! grep -qF "$(cat "${KEY}.pub")" "$AUTH_KEYS" 2>/dev/null; then
        cat "${KEY}.pub" >> "$AUTH_KEYS"
        echo "Public key added to authorized_keys for ${USERNAME}."
    fi

    chmod 700 "$SSH_DIR"
    chmod 600 "$KEY" "$AUTH_KEYS"
    chmod 644 "${KEY}.pub"
    chown -R "${USERNAME}:$(id -gn "$USERNAME")" "$SSH_DIR"

done < /etc/passwd

echo
echo "SSH hardening complete."
echo
echo "Host key fingerprints:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub
echo
echo "To enable key-based login from a client, copy the private key:"
echo "  scp <user>@<host>:~/.ssh/id_ed25519 ~/.ssh/id_ed25519_<host>"
