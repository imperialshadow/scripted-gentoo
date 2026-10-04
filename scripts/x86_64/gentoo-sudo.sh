#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Harden sudo — secure defaults, session logging, and tight sudoers rules
set -eo pipefail

echo "============================="
echo " Gentoo sudo Hardening"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n app-admin/sudo

# =============================================================================
# Validate that visudo is available before touching sudoers
# =============================================================================

if ! command -v visudo >/dev/null 2>&1; then
    echo "ERROR: visudo not found after install."
    exit 1
fi

# =============================================================================
# Ensure base sudoers includes drop-in directory
# Gentoo's default /etc/sudoers does not ship with #includedir /etc/sudoers.d
# unlike Debian/Ubuntu. Without this line, drop-in files are silently ignored.
# =============================================================================

if ! grep -q '^#includedir /etc/sudoers.d' /etc/sudoers; then
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
    visudo -c || { echo "ERROR: sudoers invalid after adding includedir."; exit 1; }
    echo "Added #includedir /etc/sudoers.d to /etc/sudoers."
fi

# =============================================================================
# /etc/sudoers.d/hardening
#
# Drop-in file so the base /etc/sudoers is left untouched and can be updated
# by Portage without conflict. Drop-ins are included via #includedir at the
# end of the default sudoers file.
# =============================================================================

mkdir -p /etc/sudoers.d
tee /etc/sudoers.d/hardening > /dev/null << 'EOF'
# =============================================================================
# Secure defaults
# =============================================================================

# Reset environment to a known-safe state; prevents injecting malicious
# variables (e.g. LD_PRELOAD) through the caller's environment
Defaults env_reset

# Explicit safe PATH; prevents PATH hijacking when running sudo commands
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Require sudo to be invoked from a real TTY; prevents privilege escalation
# from cron jobs, web processes, or other non-interactive contexts
Defaults requiretty

# Allocate a pseudo-terminal for the command; prevents sudo from being used
# as a detached escalation vector (e.g. from a backgrounded process)
Defaults use_pty

# Invalidate password cache immediately after each sudo session ends
# rather than leaving it valid for the default 15-minute window
Defaults timestamp_timeout=0

# Give the user 1 attempt to enter the correct password before failing
Defaults passwd_tries=1

# Abort if password is not entered within 30 seconds
Defaults passwd_timeout=0.5

# =============================================================================
# Logging — route to both syslog (journald) and a dedicated log file
# =============================================================================

Defaults syslog=auth
Defaults logfile=/var/log/sudo.log

# Record the full input and output of every sudo session
Defaults log_input
Defaults log_output

# Store I/O logs under a path that includes the username and session ID
Defaults iolog_dir=/var/log/sudo-io/%{user}

# =============================================================================
# Wheel group rule
# ALL:(ALL:ALL) — any host, any target user, any target group
# Requires password (no NOPASSWD); password entry already covered by timestamp_timeout=0
# =============================================================================

%wheel ALL=(ALL:ALL) ALL
EOF

# =============================================================================
# Validate the drop-in before leaving it in place
# =============================================================================

if ! visudo -c -f /etc/sudoers.d/hardening; then
    echo "ERROR: /etc/sudoers.d/hardening failed validation — removing."
    rm -f /etc/sudoers.d/hardening
    exit 1
fi

chmod 0440 /etc/sudoers.d/hardening

# =============================================================================
# Ensure the base sudoers wheel rule is commented out so the drop-in is the
# sole authority. The default Gentoo sudoers has the wheel rule commented;
# if a previous script uncommented it we need to re-comment it to avoid
# having two conflicting wheel rules.
# =============================================================================

if grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sed -i 's/^%wheel ALL=(ALL:ALL) ALL/# %wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    echo "Commented out base sudoers wheel rule (managed by drop-in)."
fi

# =============================================================================
# I/O log directory
# =============================================================================

mkdir -p /var/log/sudo-io
chmod 700 /var/log/sudo-io

# =============================================================================
# logrotate config for sudo logs
# =============================================================================

tee /etc/logrotate.d/sudo > /dev/null << 'EOF'
/var/log/sudo.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

echo
echo "sudo hardened."
echo
echo "Active settings:"
echo "  requiretty     — sudo only from a real terminal"
echo "  use_pty        — allocates a PTY, blocks detached escalation"
echo "  timestamp_timeout=0 — no credential caching between invocations"
echo "  passwd_tries=1 — one password attempt before failure"
echo "  log_input/output — full session recording in /var/log/sudo-io/"
echo "  logfile        — /var/log/sudo.log"
echo "  syslog=auth    — also logged via journald"
echo
echo "Drop-in: /etc/sudoers.d/hardening"
echo "I/O logs: /var/log/sudo-io/<user>/"
