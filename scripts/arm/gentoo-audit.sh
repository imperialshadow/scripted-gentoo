#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure auditd with hardening ruleset
set -eo pipefail

echo "============================="
echo " Gentoo auditd Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Install
# =============================================================================

echo "Installing audit..."
emerge --ask=n sys-process/audit

mkdir -p /etc/audit/rules.d /var/log/audit

# =============================================================================
# Configure auditd.conf
# =============================================================================

tee /etc/audit/auditd.conf > /dev/null << 'EOF'
log_file = /var/log/audit/audit.log
log_group = root
log_format = ENRICHED
flush = INCREMENTAL_ASYNC
freq = 50

# Keep 5 rotated logs of 32 MB each (160 MB total)
max_log_file = 32
num_logs = 5
max_log_file_action = ROTATE

# Warn via syslog at 75 MB free; suspend auditing at 50 MB free
space_left = 75
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND
disk_full_action = SUSPEND
disk_error_action = SUSPEND

priority_boost = 4
name_format = HOSTNAME
q_depth = 400
overflow_action = SYSLOG
max_restarts = 10
plugin_dir = /etc/audit/plugins.d
end_of_event_timeout = 2
EOF

# =============================================================================
# Audit rules
# Loaded in filename order; 99-finalize.rules sets -e 2 (immutable) last.
# After -e 2 is active, rules cannot be changed until reboot.
# =============================================================================

tee /etc/audit/rules.d/10-hardening.rules > /dev/null << 'EOF'
# Remove any existing rules and set kernel event buffer size
-D
-b 8192

# Ignore errors from rules that reference paths not present on this system
-i

# Exclude high-volume, low-value events from kernel threads (auid=unset)
-a always,exclude -F msgtype=CWD

## -------------------------------------------------------------------------
## Time changes
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

## -------------------------------------------------------------------------
## Identity and authentication files
## -------------------------------------------------------------------------
-w /etc/passwd   -p wa -k identity
-w /etc/shadow   -p wa -k identity
-w /etc/group    -p wa -k identity
-w /etc/gshadow  -p wa -k identity
-w /etc/security -p wa -k identity
-w /etc/pam.d    -p wa -k identity

## -------------------------------------------------------------------------
## Privilege escalation
## -------------------------------------------------------------------------
-w /etc/sudoers   -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers

-a always,exit -F arch=b64 -S setuid,setreuid,setresuid -F auid>=1000 -F auid!=4294967295 -k privilege-escalation
-a always,exit -F arch=b32 -S setuid,setreuid,setresuid -F auid>=1000 -F auid!=4294967295 -k privilege-escalation
-a always,exit -F arch=b64 -S setgid,setregid,setresgid -F auid>=1000 -F auid!=4294967295 -k privilege-escalation
-a always,exit -F arch=b32 -S setgid,setregid,setresgid -F auid>=1000 -F auid!=4294967295 -k privilege-escalation

## -------------------------------------------------------------------------
## Privileged commands
## -------------------------------------------------------------------------
-a always,exit -F path=/usr/bin/sudo    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/su      -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/newgrp  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chsh    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chfn    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/passwd  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/gpasswd -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/usermod  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/useradd  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/userdel  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/groupmod -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/groupadd -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/groupdel -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged

## -------------------------------------------------------------------------
## File permission and ownership changes (by regular users)
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k perm-mod
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k perm-mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=4294967295 -k perm-mod
-a always,exit -F arch=b32 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=4294967295 -k perm-mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm-mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm-mod

## -------------------------------------------------------------------------
## Unauthorised file access attempts
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S open,openat,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S open,openat,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=4294967295 -k access

## -------------------------------------------------------------------------
## File deletions by regular users
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k delete

## -------------------------------------------------------------------------
## Network configuration changes
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S sethostname,setdomainname -k network-config
-a always,exit -F arch=b32 -S sethostname,setdomainname -k network-config
-w /etc/hosts    -p wa -k network-config
-w /etc/hostname -p wa -k network-config
-w /etc/resolv.conf -p wa -k network-config

## -------------------------------------------------------------------------
## Kernel module loading and unloading
## -------------------------------------------------------------------------
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules

## -------------------------------------------------------------------------
## System configuration files
## -------------------------------------------------------------------------
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d    -p wa -k sysctl
-w /etc/systemd     -p wa -k systemd
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/portage     -p wa -k portage

## -------------------------------------------------------------------------
## Cron
## -------------------------------------------------------------------------
-w /etc/crontab      -p wa -k cron
-w /etc/cron.d       -p wa -k cron
-w /etc/cron.daily   -p wa -k cron
-w /etc/cron.hourly  -p wa -k cron
-w /etc/cron.weekly  -p wa -k cron
-w /etc/cron.monthly -p wa -k cron
-w /var/spool/cron   -p wa -k cron

## -------------------------------------------------------------------------
## Login and session tracking
## -------------------------------------------------------------------------
-w /var/log/faillog  -p wa -k logins
-w /var/log/lastlog  -p wa -k logins
-w /var/log/btmp     -p wa -k logins
-w /var/log/wtmp     -p wa -k logins
-w /var/run/utmp     -p wa -k session

## -------------------------------------------------------------------------
## Filesystem mounts (by regular users)
## -------------------------------------------------------------------------
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
EOF

# Separate file so -e 2 is always the final rule regardless of what else is in rules.d
tee /etc/audit/rules.d/99-finalize.rules > /dev/null << 'EOF'
# Make audit rules immutable — requires reboot to modify rules after this point
-e 2
EOF

# =============================================================================
# Load rules and enable service
# =============================================================================

echo "Loading audit rules..."
augenrules --load

echo "Enabling auditd service..."
systemctl enable --now auditd.service

echo
echo "Verifying loaded rules..."
auditctl -l

echo
echo "auditd configured and enabled."
echo "Audit log: /var/log/audit/audit.log"
echo "Rules are immutable (-e 2) until next reboot."
echo "To query events: ausearch -k <key>  e.g. ausearch -k identity"
echo "To generate reports: aureport"
