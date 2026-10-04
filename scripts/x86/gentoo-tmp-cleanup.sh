#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Set up daily cleanup of temporary files older than 2 days
set -eo pipefail

echo "============================="
echo " Gentoo Temp Cleanup Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# tmp-cleanup: removes files older than 2 days from /tmp and /var/tmp.
# Independent of package updates — just routine housekeeping.
# =============================================================================

tee /usr/local/sbin/tmp-cleanup.sh > /dev/null << 'EOF'
#!/bin/bash
exec 9>/var/lock/tmp-cleanup.lock
if ! flock -n 9; then
    echo "tmp-cleanup already running — exiting" >&2
    exit 1
fi
find /tmp /var/tmp -mindepth 1 -mtime +2 -delete 2>/dev/null || true
EOF
chmod 700 /usr/local/sbin/tmp-cleanup.sh

tee /etc/systemd/system/tmp-cleanup.service > /dev/null << 'EOF'
[Unit]
Description=Remove temporary files older than 2 days

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/tmp-cleanup.sh
EOF

tee /etc/systemd/system/tmp-cleanup.timer > /dev/null << 'EOF'
[Unit]
Description=Remove temporary files older than 2 days

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now tmp-cleanup.timer

echo
echo "Temp cleanup configured — runs daily at 04:30."
echo "Removes files older than 2 days from /tmp and /var/tmp."
