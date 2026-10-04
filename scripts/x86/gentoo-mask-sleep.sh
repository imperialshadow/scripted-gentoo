#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ -z "${GENTOO_POSTINSTALL}" ]]; then
    LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
    exec > >(tee "$LOG_FILE") 2>&1
fi

echo "=============================="
echo " Mask Sleep and Hibernate"
echo "=============================="
echo ""

# Mask all sleep/suspend/hibernate systemd targets so nothing can activate them
systemctl mask \
    sleep.target \
    suspend.target \
    hibernate.target \
    hybrid-sleep.target \
    suspend-then-hibernate.target

# Tell logind to ignore lid close and sleep/hibernate key presses rather than
# delegating them to the now-masked targets
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-sleep.conf << 'EOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

systemctl restart systemd-logind

echo ""
echo "Done. Sleep and hibernate are masked."
echo "Power button and reboot are unaffected."
