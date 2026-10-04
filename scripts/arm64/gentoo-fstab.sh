#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Harden filesystem mounts — tmpfs for /tmp and hidepid on /proc
set -eo pipefail

echo "============================="
echo " Gentoo fstab Hardening"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# /tmp — mount as tmpfs with noexec, nosuid, nodev
#
# Prevents execution of binaries dropped in /tmp, a common exploitation step.
# tmpfs is always a separate virtual filesystem regardless of disk layout, so
# this works even with a single-partition setup.
# =============================================================================

if grep -q '[[:space:]]/tmp[[:space:]]' /etc/fstab; then
    echo "/tmp entry already present in /etc/fstab, skipping."
else
    echo "tmpfs  /tmp  tmpfs  defaults,noexec,nosuid,nodev,size=2G  0 0" >> /etc/fstab
    echo "Added tmpfs /tmp entry to /etc/fstab."
fi

# Apply immediately without requiring a reboot
if ! mountpoint -q /tmp; then
    mount /tmp
elif ! grep ' /tmp ' /proc/mounts | grep -q noexec; then
    mount -o remount,noexec,nosuid,nodev /tmp
    echo "Remounted /tmp with noexec,nosuid,nodev."
fi

# =============================================================================
# /proc — mount with hidepid=2 and gid=proc
#
# hidepid=2: users can only see their own processes in /proc
# gid=proc:  processes in the 'proc' group (systemd services) retain full
#            visibility — required for systemd, ps, and monitoring tools to work
#
# This is independent of disk layout; /proc is always a virtual filesystem.
# =============================================================================

# Ensure the proc group exists — systemd services that need full /proc
# visibility should be added to this group
if ! getent group proc > /dev/null; then
    groupadd --system proc
    echo "Created 'proc' system group."
fi

PROC_GID="$(getent group proc | cut -d: -f3)"

if grep -q '[[:space:]]/proc[[:space:]]' /etc/fstab; then
    echo "/proc entry already present in /etc/fstab, skipping."
else
    echo "proc  /proc  proc  defaults,hidepid=2,gid=${PROC_GID}  0 0" >> /etc/fstab
    echo "Added /proc hidepid=2 entry to /etc/fstab."
fi

# Apply immediately
mount -o remount,hidepid=2,gid="${PROC_GID}" /proc
echo "Remounted /proc with hidepid=2,gid=${PROC_GID}."

echo
echo "Verifying mounts..."
grep -E '[[:space:]](/tmp|/proc)[[:space:]]' /proc/mounts

echo
echo "fstab hardening applied."
echo "Changes persist across reboots via /etc/fstab."
echo
echo "NOTE: If any services fail to start after reboot, add them to the 'proc'"
echo "group to restore their /proc visibility:"
echo "  usermod -aG proc <service-user>"
