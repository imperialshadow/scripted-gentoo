#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure SELinux in permissive mode; install policy from AVC denials
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "============================="
echo " Gentoo SELinux Setup"
echo "============================="
echo


# Remove the -selinux FEATURES flag set during chroot install (prevented portage
# context errors when /sys/fs/selinux was not mounted). Now that SELinux is active,
# portage should manage file contexts normally.
if grep -q 'FEATURES.*-selinux' /etc/portage/make.conf 2>/dev/null; then
    sed -i '/^FEATURES="-selinux"$/d' /etc/portage/make.conf
    echo "Removed FEATURES=-selinux from make.conf"
fi

install_selinux() {
    # Check if SELinux is active — /sys/fs/selinux mounted is authoritative.
    # Kernel config file checks are unreliable (file may be absent or gzip
    # support not compiled in), but a mounted selinuxfs proves the kernel
    # has SELinux support and it is enabled on the current boot.
    if [[ ! -d /sys/fs/selinux ]]; then
        echo "ERROR: /sys/fs/selinux is not mounted — SELinux is not active."
        echo "SELinux requires kernel support and the correct boot parameters."
        echo
        echo "Steps to fix:"
        echo "  1. In kernel config: Security options → SELinux support"
        echo "     (CONFIG_SECURITY_SELINUX=y)"
        echo "  2. Add to GRUB cmdline:"
        echo "     security=selinux selinux=1 lsm=landlock,lockdown,yama,selinux,bpf"
        echo "  3. Rebuild: genkernel all   (or with --luks --lvm on encrypted installs)"
        echo "  4. Reboot and re-run this script."
        return 1
    fi

    echo "Installing SELinux userspace tools..."
    emerge --ask=n --noreplace \
        sys-libs/libselinux \
        sys-apps/policycoreutils \
        sys-apps/checkpolicy \
        app-admin/setools

    # Pin policy building to just "targeted" (matching SELINUXTYPE below),
    # instead of the EAPI 8 default of silently building all four policy
    # types (mcs, mls, strict, targeted) on every sec-policy update. Both
    # the new USE_EXPAND and the deprecated env var are set and kept in
    # sync per Gentoo's own migration guidance:
    # https://www.gentoo.org/support/news-items/2026-04-26-selinux-policy-eapi-8.html
    mkdir -p /etc/portage/package.use
    if ! grep -q "SELINUX_POLICY_TYPES" /etc/portage/package.use/selinux-policy 2>/dev/null; then
        echo 'sec-policy/* SELINUX_POLICY_TYPES: targeted' >> /etc/portage/package.use/selinux-policy
    fi
    if ! grep -q "^POLICY_TYPES=" /etc/portage/make.conf 2>/dev/null; then
        echo 'POLICY_TYPES="targeted"' >> /etc/portage/make.conf
    fi

    echo "Installing SELinux policies..."
    install_policy() {
        emerge --ask=n --noreplace "sec-policy/$1" || \
            echo "NOTE: sec-policy/$1 not available in portage — skipping"
    }

    install_policy selinux-base
    install_policy selinux-base-policy
    install_policy selinux-sudo
    install_policy selinux-logrotate
    install_policy selinux-networkmanager
    install_policy selinux-fail2ban
    install_policy selinux-clamav
    install_policy selinux-aide
    install_policy selinux-dbus
    install_policy selinux-xserver
    install_policy selinux-mplayer

    # Full filesystem relabel is handled by gentoo-restorecon.sh via
    # /.autorelabel, which triggers a safe boot-time relabel before services
    # start. Running restorecon -R / on a live system crashes running sessions.

    # Persist permissive mode across reboots
    if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    else
        mkdir -p /etc/selinux
        cat > /etc/selinux/config << 'EOF'
SELINUX=permissive
SELINUXTYPE=targeted
EOF
    fi

    # Set permissive mode in the running kernel (no-op at install time; useful on rerun)
    if command -v setenforce >/dev/null 2>&1; then
        setenforce 0 2>/dev/null || true
    fi

    echo "Setting SELinux booleans..."
    set_bool() {
        setsebool -P "$1" "$2" 2>/dev/null || echo "NOTE: boolean $1 not available — skipping"
    }
    set_bool xserver_allow_dri          on
    set_bool systemd_tmpfiles_manage_all on
    set_bool global_ssp                 on
    set_bool ssh_use_gpg_agent          on
    set_bool allow_execmem              on
    set_bool systemd_logind_get_bootloader on
    set_bool mplayer_manage_all_user_content    on
    set_bool xserver_client_writes_xserver_tmpfs on
    set_bool user_tcp_server                    on
    set_bool allow_java_execstack               on
    set_bool java_manage_all_user_content       on
    set_bool wireshark_manage_all_user_content  on
    set_bool user_write_removable               on
    set_bool authlogin_pam                      on

    echo "SELinux configured."
    sestatus 2>/dev/null || true
}

# Compile and install the bundled gentoo-local policy module covering known
# AVC denials for staff_t, staff_sudo_t, staff_bubblewrap_t, and others.
install_local_policy() {
    if ! command -v checkmodule >/dev/null 2>&1 || ! command -v semodule_package >/dev/null 2>&1; then
        echo "NOTE: checkmodule/semodule_package not available — skipping local policy install."
        return 0
    fi

    local te_src
    # Look for the .te file relative to this script's location
    te_src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../gentoo-local.te"
    if [[ ! -f "$te_src" ]]; then
        echo "NOTE: gentoo-local.te not found — skipping local policy install."
        return 0
    fi

    echo "Compiling and installing gentoo-local SELinux policy module..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cp "$te_src" "${tmpdir}/gentoo-local.te"
    checkmodule -M -m -o "${tmpdir}/gentoo-local.mod" "${tmpdir}/gentoo-local.te"
    semodule_package -o "${tmpdir}/gentoo-local.pp" -m "${tmpdir}/gentoo-local.mod"
    semodule -i "${tmpdir}/gentoo-local.pp" && \
        echo "gentoo-local policy module installed." || \
        echo "WARNING: Failed to install gentoo-local policy module."

    mkdir -p /etc/selinux/local
    cp "${tmpdir}/gentoo-local.te" "${tmpdir}/gentoo-local.pp" /etc/selinux/local/ 2>/dev/null || true
}

# Configure SELinux login user mappings and context files.
# Under targeted policy, root maps to unconfined_u (same as the desktop user).
# UBAC constraints block unconfined_u → sysadm_u transitions in Gentoo's
# targeted policy because unconfined_t is still ubac_constrained_type.
# Standard targeted policy has all interactive users as unconfined_u.
#
# The unconfined_u context file fix: pam_selinux calls get_ordered_context_list
# when sudo opens a PAM session. Gentoo's stock unconfined_u context file only
# has system_r:* source entries. When root is already running as unconfined_t
# (not via a login manager), the lookup fails with EINVAL. Adding the
# unconfined_r:unconfined_t self-mapping fixes this.
configure_selinux_users() {
    echo "Configuring SELinux login user mappings..."

    semanage login -a -s unconfined_u root 2>/dev/null \
        || semanage login -m -s unconfined_u root
    echo "  root → unconfined_u"

    local selinuxtype
    selinuxtype=$(awk -F= '/^SELINUXTYPE/{gsub(/"/, "", $2); print $2; exit}' \
        /etc/selinux/config 2>/dev/null)
    selinuxtype=${selinuxtype:-targeted}

    local ctx_file="/etc/selinux/${selinuxtype}/contexts/users/unconfined_u"
    if [[ -f "$ctx_file" ]]; then
        local fix="unconfined_r:unconfined_t    unconfined_r:unconfined_t"
        if ! grep -qF "$fix" "$ctx_file"; then
            echo "$fix" >> "$ctx_file"
            echo "  unconfined_u context file: added unconfined_r self-mapping"
        else
            echo "  unconfined_u context file: self-mapping already present"
        fi
    else
        echo "  NOTE: ${ctx_file} not found — skipping context fix"
    fi
}

# Install a helper script for manually applying AVC-based policy updates.
# Run this only after reviewing the denials with: ausearch -m avc -ts recent | audit2why
install_avc_update_script() {
    cat > /usr/local/sbin/selinux-avc-update << 'SCRIPT'
#!/bin/bash
set -eo pipefail
if ! command -v ausearch >/dev/null 2>&1 || ! command -v audit2allow >/dev/null 2>&1; then
    echo "ausearch or audit2allow not available — install sys-process/audit and sys-apps/policycoreutils"
    exit 1
fi
avc_log=$(ausearch -m avc -ts week 2>/dev/null || true)
if [[ -z "$avc_log" ]]; then
    echo "No AVC denials in the past week."
    exit 0
fi
count=$(echo "$avc_log" | grep -c "type=AVC" || true)
echo "Found ${count} AVC denial(s) — generating policy module..."
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
(
    cd "$tmpdir"
    echo "$avc_log" | audit2allow -M gentoo-local 2>/dev/null
)
if [[ -f "${tmpdir}/gentoo-local.pp" ]]; then
    semodule -i "${tmpdir}/gentoo-local.pp"
    mkdir -p /etc/selinux/local
    cp "${tmpdir}/gentoo-local.pp" "${tmpdir}/gentoo-local.te" /etc/selinux/local/ 2>/dev/null || true
    echo "selinux-avc-update: installed updated gentoo-local policy module."
    echo "Review the generated rules: cat /etc/selinux/local/gentoo-local.te"
else
    echo "No policy module generated."
fi
SCRIPT
    chmod 750 /usr/local/sbin/selinux-avc-update
    echo "Manual AVC update script installed: /usr/local/sbin/selinux-avc-update"
}

if ! install_selinux; then
    echo
    echo "SELinux installation skipped — rebuild the kernel first (see above)."
    exit 0
fi

# =============================================================================
# Boot-time filesystem relabel mechanism (systemd generator + service +
# target + worker script). Gentoo's sys-apps/policycoreutils does not ship
# any of this -- unlike Fedora/RHEL, where it comes from policycoreutils
# upstream -- so it's built here from scratch, adapted for Gentoo's missing
# fixfiles wrapper (drives restorecon/setfiles directly instead).
#
# Architecture (confirmed against Fedora's reference design, not an
# initramfs mechanism): a systemd generator runs very early and, only if
# /.autorelabel exists or "autorelabel" is on the kernel cmdline, retargets
# this boot to selinux-autorelabel.target instead of the normal
# default.target. That target requires only sysinit.target (not
# basic.target/multi-user.target/graphical.target), so the relabel runs
# before ANY normal service starts and could hold files open during the
# relabel -- this is what makes it safe to run restorecon -R / here, unlike
# on an already-running system with SDDM/XFCE/D-Bus active. The worker
# force-reboots when done, since a relabel under a deliberately minimal
# boot needs one more clean boot before it's trusted.
#
# This mechanism is completely inert on a normal boot -- the generator
# checks for the trigger file and does nothing if it's absent, so
# installing it carries no risk to normal boots. The only genuinely
# consequential moment is if/when /.autorelabel actually exists at boot.
# =============================================================================

install_autorelabel_mechanism() {
    mkdir -p /usr/libexec/selinux /etc/systemd/system-generators

    cat > /usr/libexec/selinux/selinux-autorelabel << 'SCRIPT'
#!/bin/bash
# Relabels the filesystem per the active SELinux policy, then reboots.
# Adapted from Fedora/RHEL's selinux-autorelabel worker for Gentoo, which
# does not ship policycoreutils' fixfiles wrapper -- this drives
# restorecon directly instead. Triggered only via selinux-autorelabel
# .service, which only runs when /.autorelabel exists or "autorelabel" is
# on the kernel cmdline (see the generator) -- a normal boot never
# reaches this script.
set -uo pipefail

echo "SELinux autorelabel: starting full filesystem relabel..."

# Force permissive for the duration of the relabel so a stale label can
# never cause a denial mid-relabel (harmless no-op if already permissive,
# which is the expected state at this point).
if [[ -w /sys/fs/selinux/enforce ]]; then
    echo 0 > /sys/fs/selinux/enforce
fi

# Manual override: AUTORELABEL=0 in /etc/selinux/config skips the relabel
# and drops to a rescue shell instead, mirroring Fedora's escape hatch for
# when this trips unexpectedly. Exiting the shell continues booting
# normally without clearing /.autorelabel or rebooting.
if grep -q '^AUTORELABEL=0' /etc/selinux/config 2>/dev/null; then
    echo "AUTORELABEL=0 in /etc/selinux/config -- skipping relabel."
    echo "Dropping to a rescue shell. Type 'exit' to continue booting"
    echo "normally (nothing will be relabeled, /.autorelabel stays)."
    exec sulogin
fi

# Build the exclude list from currently-mounted pseudo/virtual/network
# filesystems -- these either can't carry SELinux xattrs (proc, sysfs,
# vfat, tmpfs-backed pseudo-fs) or are transient/remote mounts that
# shouldn't be touched by a system-wide relabel.
EXCLUDE_TYPES="proc sysfs devtmpfs devpts tmpfs cgroup2 mqueue hugetlbfs
    debugfs tracefs binfmt_misc autofs efivarfs selinuxfs fusectl vfat
    fuse.portal fuse.sshfs fuse.gvfsd-fuse nfs nfs4 cifs"

EXCLUDE_ARGS=()
while read -r _ mountpoint fstype _; do
    for t in $EXCLUDE_TYPES; do
        if [[ "$fstype" == "$t" ]]; then
            EXCLUDE_ARGS+=(-e "$mountpoint")
            break
        fi
    done
done < /proc/mounts

echo "Excluding: ${EXCLUDE_ARGS[*]:-none}"
mkdir -p /var/log
restorecon -R -F "${EXCLUDE_ARGS[@]}" / 2>&1 | tee /var/log/selinux-autorelabel.log

echo "Relabel complete. Removing /.autorelabel and rebooting..."
rm -f /.autorelabel
sync
systemctl --force reboot
SCRIPT
    chmod 755 /usr/libexec/selinux/selinux-autorelabel

    cat > /etc/systemd/system-generators/selinux-autorelabel-generator << 'SCRIPT'
#!/bin/sh
# systemd.generator(7): if SELinux is active and /.autorelabel exists (or
# "autorelabel" is on the kernel cmdline), retarget this boot to
# selinux-autorelabel.target instead of the normal default.target. A
# normal boot with no trigger present does nothing here -- this generator
# is inert by default.
#
# Generators receive three directory arguments: $1=normal, $2=early,
# $3=late. default.target overrides belong in the early dir so they take
# effect before unit files are otherwise processed.
PATH=/usr/sbin:/usr/bin:$PATH
unitdir=/etc/systemd/system
earlydir="${2:-/tmp}"

set_target() {
    mkdir -p "$earlydir"
    ln -sf "$unitdir/selinux-autorelabel.target" "$earlydir/default.target"
}

if selinuxenabled 2>/dev/null; then
    if [ -f /.autorelabel ]; then
        set_target
    elif grep -qE '(^|[[:space:]])autorelabel([[:space:]]|$)' /proc/cmdline 2>/dev/null; then
        set_target
    fi
fi
SCRIPT
    chmod 755 /etc/systemd/system-generators/selinux-autorelabel-generator

    cat > /etc/systemd/system/selinux-autorelabel.service << 'EOF'
[Unit]
Description=Relabel all filesystems
DefaultDependencies=no
Conflicts=shutdown.target
After=sysinit.target
Before=shutdown.target
ConditionSecurity=selinux

[Service]
ExecStart=/usr/libexec/selinux/selinux-autorelabel
Type=oneshot
# Deliberately finite, unlike Fedora's TimeoutSec=0 (infinite): if the
# relabel worker hangs, this bounds it instead of leaving no recourse at
# all in an environment that hasn't been live-tested through a real
# reboot yet.
TimeoutSec=1800
RemainAfterExit=yes
StandardInput=tty
StandardOutput=tty
EOF

    cat > /etc/systemd/system/selinux-autorelabel.target << 'EOF'
[Unit]
Description=Relabel all filesystems and reboot
DefaultDependencies=no
Requires=sysinit.target selinux-autorelabel.service
Conflicts=shutdown.target
After=sysinit.target selinux-autorelabel.service
ConditionSecurity=selinux
EOF

    systemctl daemon-reload
    echo "Boot-time relabel mechanism installed (inert until /.autorelabel exists)."
}

install_local_policy
configure_selinux_users
install_avc_update_script
install_autorelabel_mechanism

# =============================================================================
# Schedule boot-time filesystem relabel. Stay in permissive mode so the
# system remains usable after relabel. Collect AVC denials in permissive,
# build a policy module with selinux-avc-update, then manually enable
# enforcing once the policy is validated.
#
# The /.autorelabel file, combined with the mechanism installed above,
# causes the system to relabel the entire filesystem in a minimal
# (sysinit.target-only) boot environment before any normal service starts,
# then reboot once more into the regular target with corrected labels.
# =============================================================================

echo "Scheduling full filesystem relabel on next boot..."
touch /.autorelabel

# Stay in permissive — do NOT auto-switch to enforcing.
# Enforcing before validating the policy breaks GUI login (SDDM/XFCE).
# After rebooting and confirming everything works in permissive:
#   1. Review denials: ausearch -m avc -ts recent | audit2why
#   2. Build policy:   sudo /usr/local/sbin/selinux-avc-update
#   3. Enable:         sudo setenforce 1 && sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

echo
sestatus 2>/dev/null || true
echo
echo "Reboot to apply:"
echo "  1. The system will relabel the entire filesystem at boot"
echo "  2. SELinux will come up in PERMISSIVE mode (denials logged, not blocked)"
echo "  3. /.autorelabel is removed automatically when complete"
echo
echo "After reboot �� to enable enforcing once policy is validated:"
echo "  ausearch -m avc -ts recent | audit2why"
echo "  sudo /usr/local/sbin/selinux-avc-update"
echo "  sudo setenforce 1"
echo "  sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config"
echo "  sudo /usr/local/sbin/selinux-avc-update"
