#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Configure logrotate for all custom log files written by postinstall scripts
set -eo pipefail

echo "============================="
echo " Gentoo logrotate Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

emerge --ask=n app-admin/logrotate

# =============================================================================
# Auto-update log
# =============================================================================

tee /etc/logrotate.d/autoupdate > /dev/null << 'EOF'
/var/log/autoupdate.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}

/var/log/pending-configs-discarded.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# =============================================================================
# ClamAV
# clamd and freshclam have LogRotate yes in their configs, which signals the
# daemon to reopen the log file after rotation. No postrotate needed.
# =============================================================================

tee /etc/logrotate.d/clamav > /dev/null << 'EOF'
/var/log/clamav/clamd.log
/var/log/clamav/freshclam.log
/var/log/clamav/scan.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 clamav clamav
}
EOF

# =============================================================================
# rkhunter
# =============================================================================

tee /etc/logrotate.d/rkhunter > /dev/null << 'EOF'
/var/log/rkhunter/rkhunter.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# =============================================================================
# AIDE
# =============================================================================

tee /etc/logrotate.d/aide > /dev/null << 'EOF'
/var/log/aide/aide.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# =============================================================================
# auditd — note: auditd manages its own rotation via auditd.conf (max_log_file,
# num_logs, max_log_file_action). This entry only catches anything that falls
# outside auditd's built-in rotation.
# =============================================================================

tee /etc/logrotate.d/audit > /dev/null << 'EOF'
/var/log/audit/audit.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl kill --signal=USR1 auditd.service 2>/dev/null || true
    endscript
}
EOF

# =============================================================================
# Enable systemd logrotate timer (replaces cron-based daily rotation)
# =============================================================================

systemctl enable --now logrotate.timer

echo
echo "logrotate configured."
echo "logrotate.timer runs daily; configs use weekly rotation."
echo
echo "Configs written to /etc/logrotate.d/:"
ls /etc/logrotate.d/
