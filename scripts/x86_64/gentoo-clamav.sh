#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure ClamAV antivirus with scheduled definition updates
set -eo pipefail

echo "============================="
echo " Gentoo ClamAV Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Install
# =============================================================================

echo "Installing ClamAV..."
emerge --ask=n app-antivirus/clamav

# =============================================================================
# Configure freshclam (definition updater)
# =============================================================================

mkdir -p /var/log/clamav /var/lib/clamav /var/quarantine/clamav
chown -R clamav:clamav /var/log/clamav /var/lib/clamav /var/quarantine/clamav

tee /etc/clamav/freshclam.conf > /dev/null << 'EOF'
DatabaseDirectory /var/lib/clamav
UpdateLogFile /var/log/clamav/freshclam.log
LogTime yes
LogRotate yes
# 4 checks per day (every 6 hours) — ClamAV mirrors request no more than 4/day
Checks 4
DatabaseMirror database.clamav.net
NotifyClamd /etc/clamav/clamd.conf
EOF

# =============================================================================
# Configure clamd (scanner daemon)
# =============================================================================

tee /etc/clamav/clamd.conf > /dev/null << 'EOF'
LocalSocket /run/clamav/clamd.sock
LocalSocketMode 660
FixStaleSocket yes
User clamav

LogFile /var/log/clamav/clamd.log
LogTime yes
LogRotate yes
LogFileMaxSize 10M

# Scan limits
MaxScanSize 500M
MaxFileSize 100M
MaxRecursion 16
MaxFiles 15000

# Detection
DetectPUA yes
HeuristicAlerts yes

# Exclude virtual and device filesystems
ExcludePath ^/proc/
ExcludePath ^/sys/
ExcludePath ^/dev/
ExcludePath ^/run/
EOF

# =============================================================================
# Enable services and run initial definition update
# =============================================================================

echo "Enabling ClamAV services..."
# Service name changed in recent Gentoo — clamd.service is the current name
if systemctl list-unit-files | grep -q 'clamav-clamd.service'; then
    systemctl enable clamav-freshclam.service clamav-clamd.service
    echo "Running initial definition update..."
    freshclam
    systemctl start clamav-freshclam.service clamav-clamd.service
elif systemctl list-unit-files | grep -q 'clamd.service'; then
    systemctl enable clamav-freshclam.service clamd.service
    echo "Running initial definition update..."
    freshclam
    systemctl start clamav-freshclam.service clamd.service
else
    echo "WARNING: Could not find ClamAV service unit. Run 'systemctl list-unit-files | grep clam' to check."
    echo "Running initial definition update..."
    freshclam || true
fi

mkdir -p /var/quarantine/clamav

# =============================================================================
# clamav-scan: independent daily definition update + filesystem scan.
# clamav-freshclam.service already updates defs continuously in the
# background (4x/day per freshclam.conf), but this forces one immediately
# before the scan for a guaranteed-fresh run. Exit code reflects clamscan's
# own result (1 = infection found), so a non-clean run shows up as a failed
# systemd unit (systemctl --failed / journalctl -u clamav-scan.service).
# =============================================================================

tee /usr/local/sbin/clamav-scan.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/clamav-scan.lock
if ! flock -n 9; then
    echo "clamav-scan already running — exiting" >&2
    exit 1
fi

systemctl stop clamav-freshclam.service 2>/dev/null || true
freshclam
systemctl start clamav-freshclam.service 2>/dev/null || true
systemctl restart clamav-clamd.service 2>/dev/null || systemctl restart clamd.service 2>/dev/null || true

mkdir -p /var/quarantine/clamav
: > /var/log/clamav/scan.log
# Wine/Proton's own bundled system32/syswow64 DLLs (and the GE-Proton/umu
# runtime installs they're copied from) routinely false-positive heuristic
# PUA.Win.Packer signatures -- they ARE packed PE binaries, that's just how
# Wine builds them. Without these exclusions, --move=... silently yanks
# kernel32.dll etc. out of every Wine prefix on the nightly scan, breaking
# Lutris/Steam games until someone notices and restores them from quarantine.
clamscan --recursive \
    --infected \
    --detect-pua=yes \
    --heuristic-alerts=yes \
    --max-filesize=100M \
    --max-scansize=500M \
    --move=/var/quarantine/clamav \
    --log=/var/log/clamav/scan.log \
    --exclude-dir='/\.local/share/Steam/compatibilitytools\.d' \
    --exclude-dir='/\.local/share/umu' \
    --exclude-dir='/drive_c/windows/(system32|syswow64)' \
    /etc /home /root /tmp /var/tmp /opt /srv /boot
EOF
chmod 700 /usr/local/sbin/clamav-scan.sh

tee /etc/systemd/system/clamav-scan.service > /dev/null << 'EOF'
[Unit]
Description=ClamAV definition update and filesystem scan

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/usr/local/sbin/clamav-scan.sh
EOF

tee /etc/systemd/system/clamav-scan.timer > /dev/null << 'EOF'
[Unit]
Description=ClamAV definition update and filesystem scan

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now clamav-scan.timer

echo
echo "ClamAV configured and enabled."
echo "clamav-scan.timer runs a definition update + full scan daily at 03:00"
echo "(scan log: /var/log/clamav/scan.log; an infection shows as a failed"
echo "systemd unit). Quarantine directory: /var/quarantine/clamav"
echo "Freshclam log: /var/log/clamav/freshclam.log"
