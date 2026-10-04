#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure AIDE file integrity monitoring with daily checks
set -eo pipefail

echo "============================="
echo " Gentoo AIDE Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Install
# =============================================================================

emerge --ask=n app-forensics/aide

mkdir -p /var/lib/aide /var/log/aide

# =============================================================================
# Configure
# =============================================================================

tee /etc/aide/aide.conf > /dev/null << 'EOF'
# AIDE configuration for Gentoo

database_in  = file:/var/lib/aide/aide.db
database_out = file:/var/lib/aide/aide.db.new
database_new = file:/var/lib/aide/aide.db.new
gzip_dbout   = yes
report_url   = file:/var/log/aide/aide.log
report_url   = stdout

# =============================================================================
# Attribute groups
# =============================================================================

# Full check: permissions, inode, owner, group, size, mtime, ctime, sha256, sha512
FULL = p+i+n+u+g+s+m+c+sha256+sha512+xattrs+acl

# Standard: permissions, inode, owner, group, size, ctime, sha256
NORMAL = p+i+n+u+g+s+c+sha256

# Directory: permissions, inode, owner, group only (no content hash)
DIR = p+i+n+u+g

# Log files: owner/group/permissions only — content changes are expected
LOG = p+n+u+g

# =============================================================================
# Monitored paths
# =============================================================================

# Bootloader and kernel — critical; any change is suspicious
/boot FULL

# Core system binaries and libraries
/bin    FULL
/sbin   FULL
/lib    FULL
/lib64  FULL

/usr/bin    FULL
/usr/sbin   FULL
/usr/lib    FULL
/usr/lib64  FULL

# System configuration
/etc NORMAL

# Root's home directory
/root DIR

# Cron jobs
/var/spool/cron NORMAL

# SSH host keys and config
/etc/ssh FULL

# Portage configuration — changes should be intentional
/etc/portage NORMAL

# =============================================================================
# Exclusions — volatile paths that change legitimately during normal operation
# =============================================================================

!/etc/aide
!/etc/mtab
!/etc/ld.so.cache
!/etc/resolv.conf

!/var/log
!/var/lib/clamav
!/var/lib/aide
!/var/lib/rkhunter
!/var/lib/portage
!/var/lib/systemd
!/var/cache
!/var/tmp
!/var/run
!/var/spool/postfix

!/tmp
!/proc
!/sys
!/dev
!/run
EOF

# =============================================================================
# Initialise the database
# This snapshots the current state of all monitored paths as trusted baseline.
# Re-run 'aide --update && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db'
# after intentional system changes (package updates, config edits).
# =============================================================================

if [[ -f /var/lib/aide/aide.db ]]; then
    echo "AIDE database already exists — skipping init to preserve baseline."
    echo "To rebuild: aide --update && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
else
    echo "Initialising AIDE database (this may take a while)..."
    aide --init
    mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    echo "AIDE database initialised at /var/lib/aide/aide.db"
fi

# =============================================================================
# aide-check: independent daily integrity scan. Reads the existing db only
# (aide --check) -- exit code reflects aide's own result (0 clean, 1
# differences found), so a non-clean run shows up as a failed systemd unit
# (systemctl --failed / journalctl -u aide-check.service), same as any other
# monitoring check.
# =============================================================================

tee /usr/local/sbin/aide-check.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/aide.lock
if ! flock -n 9; then
    echo "aide-check/aide-update already running — exiting" >&2
    exit 1
fi
aide --check
EOF
chmod 700 /usr/local/sbin/aide-check.sh

tee /etc/systemd/system/aide-check.service > /dev/null << 'EOF'
[Unit]
Description=AIDE integrity check

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/aide-check.sh
EOF

tee /etc/systemd/system/aide-check.timer > /dev/null << 'EOF'
[Unit]
Description=AIDE integrity check

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# =============================================================================
# aide-update: refreshes the baseline after package updates change files
# system-wide. No timer of its own -- triggered by autoupdate.sh right after
# @world via 'systemctl start --wait aide-update.service', so the baseline
# always reflects intentional changes before the next aide-check run, rather
# than flagging every updated binary as a false positive.
# =============================================================================

tee /usr/local/sbin/aide-update.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/aide.lock
if ! flock -n 9; then
    echo "aide-check/aide-update already running — exiting" >&2
    exit 1
fi
aide --update
if [[ -f /var/lib/aide/aide.db.new ]]; then
    mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    echo "AIDE database updated."
else
    echo "AIDE update produced no new database." >&2
    exit 1
fi
EOF
chmod 700 /usr/local/sbin/aide-update.sh

tee /etc/systemd/system/aide-update.service > /dev/null << 'EOF'
[Unit]
Description=AIDE database baseline refresh

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/aide-update.sh
EOF

systemctl daemon-reload
systemctl enable --now aide-check.timer

echo
echo "AIDE configured."
echo "aide-check.timer runs an integrity scan daily at 04:00 (results in"
echo "/var/log/aide/aide.log; a non-clean run shows as a failed systemd unit)."
echo "aide-update.service refreshes the baseline after each autoupdate.sh"
echo "run — it has no timer of its own, autoupdate.sh triggers it directly."
