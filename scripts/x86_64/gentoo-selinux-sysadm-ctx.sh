#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

selinuxtype=$(awk -F= '/^SELINUXTYPE/{gsub(/"/, "", $2); print $2; exit}' \
    /etc/selinux/config 2>/dev/null)
selinuxtype=${selinuxtype:-targeted}

ctx_dir="/etc/selinux/${selinuxtype}/contexts/users"
mkdir -p "$ctx_dir"

cat > "${ctx_dir}/sysadm_u" << 'EOF'
system_r:crond_t:s0		sysadm_r:cronjob_t:s0
system_r:init_t:s0		sysadm_r:sysadm_systemd_t:s0
system_r:local_login_t:s0	sysadm_r:sysadm_t:s0
system_r:remote_login_t:s0	sysadm_r:sysadm_t:s0
system_r:sshd_t:s0		sysadm_r:sysadm_t:s0
unconfined_r:unconfined_t:s0	sysadm_r:sysadm_t:s0
staff_r:staff_su_t:s0		sysadm_r:sysadm_t:s0
staff_r:staff_sudo_t:s0		sysadm_r:sysadm_t:s0
sysadm_r:sysadm_su_t:s0	sysadm_r:sysadm_t:s0
sysadm_r:sysadm_sudo_t:s0	sysadm_r:sysadm_t:s0
EOF

chcon -u system_u "${ctx_dir}/sysadm_u" 2>/dev/null || true

echo "Written ${ctx_dir}/sysadm_u"
