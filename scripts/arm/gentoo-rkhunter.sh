#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure rkhunter rootkit scanner
set -eo pipefail

echo "============================="
echo " Gentoo rkhunter Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Install
# app-forensics/rkhunter requires sys-process/lsof built with USE=rpc.
# =============================================================================

mkdir -p /etc/portage/package.use
if ! grep -q "sys-process/lsof rpc" /etc/portage/package.use/rkhunter 2>/dev/null; then
    echo "sys-process/lsof rpc" >> /etc/portage/package.use/rkhunter
fi

echo "Installing rkhunter..."
if ! emerge --ask=n app-forensics/rkhunter; then
    echo
    echo "NOTE: app-forensics/rkhunter failed to install — see the emerge"
    echo "output above for the actual reason (USE flags, masks, etc.)."
    echo "Skipping rkhunter. AIDE (installed by gentoo-aide.sh) provides"
    echo "equivalent file integrity monitoring."
    exit 0
fi

mkdir -p /var/log/rkhunter

# =============================================================================
# Configure /etc/rkhunter.conf
# Sets a key=value pair, adding the line if not already present
# =============================================================================

set_conf() {
    local key="$1" val="$2" file="/etc/rkhunter.conf"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# Mirror and update settings
set_conf UPDATE_MIRRORS    1
set_conf MIRRORS_MODE      0
set_conf WEB_CMD           '"/usr/bin/curl"'

# Gentoo uses Portage — no native rkhunter integration, use its own propupd db
set_conf PKGMGR            NONE

# Logging
set_conf LOGFILE           /var/log/rkhunter/rkhunter.log
set_conf APPEND_LOG        1
set_conf COPY_LOG_ON_ERROR 1

# Warn if OS-level changes are detected between runs but do not auto-accept them
set_conf WARN_ON_OS_CHANGE 1
set_conf UPDT_ON_OS_CHANGE 0

# SSH hardening expectations — must match sshd_config
# Root login should be disabled on a hardened Gentoo install
set_conf ALLOW_SSH_ROOT_USER no
# Protocol 1 is obsolete and must not be allowed
set_conf ALLOW_SSH_PROT_V1   0

# =============================================================================
# Initialise the file properties database
# This snapshots all monitored binaries in their current (trusted) state.
# Re-run manually after package updates: rkhunter --propupd
# =============================================================================

echo "Updating rkhunter mirror list and signatures..."
rkhunter --update || true

echo "Initialising file properties database..."
rkhunter --propupd

echo
echo "Running initial scan..."
rkhunter --check --sk --rwo || true

# =============================================================================
# rkhunter-scan: independent daily rootkit scan (signature update + check).
# Exit code reflects rkhunter's own result, so warnings show up as a failed
# systemd unit (systemctl --failed / journalctl -u rkhunter-scan.service).
# =============================================================================

tee /usr/local/sbin/rkhunter-scan.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/rkhunter.lock
if ! flock -n 9; then
    echo "rkhunter-scan/rkhunter-propupd already running — exiting" >&2
    exit 1
fi
rkhunter --update
rkhunter --check --sk
EOF
chmod 700 /usr/local/sbin/rkhunter-scan.sh

tee /etc/systemd/system/rkhunter-scan.service > /dev/null << 'EOF'
[Unit]
Description=rkhunter rootkit scan

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/rkhunter-scan.sh
EOF

tee /etc/systemd/system/rkhunter-scan.timer > /dev/null << 'EOF'
[Unit]
Description=rkhunter rootkit scan

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# =============================================================================
# rkhunter-propupd: refreshes the file-properties baseline after package
# updates change binaries system-wide. No timer of its own -- triggered by
# autoupdate.sh right after @world via
# 'systemctl start --wait rkhunter-propupd.service', so the baseline always
# reflects intentional changes before the next rkhunter-scan run, rather
# than flagging every updated binary as a false positive.
# =============================================================================

tee /usr/local/sbin/rkhunter-propupd.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/rkhunter.lock
if ! flock -n 9; then
    echo "rkhunter-scan/rkhunter-propupd already running — exiting" >&2
    exit 1
fi
rkhunter --propupd
EOF
chmod 700 /usr/local/sbin/rkhunter-propupd.sh

tee /etc/systemd/system/rkhunter-propupd.service > /dev/null << 'EOF'
[Unit]
Description=rkhunter file-properties baseline refresh

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/rkhunter-propupd.sh
EOF

systemctl daemon-reload
systemctl enable --now rkhunter-scan.timer

echo
echo "rkhunter configured."
echo "rkhunter-scan.timer runs a signature update + scan daily at 03:30"
echo "(log: /var/log/rkhunter/rkhunter.log; warnings show as a failed"
echo "systemd unit). rkhunter-propupd.service refreshes the baseline after"
echo "each autoupdate.sh run — it has no timer of its own, autoupdate.sh"
echo "triggers it directly."
