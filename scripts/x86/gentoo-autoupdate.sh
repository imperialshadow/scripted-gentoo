#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Set up weekly automatic system update with kernel reboot detection.
# ClamAV, rkhunter, and AIDE scans run on their own independent daily timers
# (set up by gentoo-clamav.sh, gentoo-rkhunter.sh, gentoo-aide.sh) rather than
# being rolled into this script. Their baseline-refresh steps that must run
# right after @world (aide --update, rkhunter --propupd) are triggered from
# here directly, since running them on an independent schedule would report
# every updated binary as a false positive until the next refresh.
set -eo pipefail

echo "================================"
echo " Gentoo Auto-Update Setup"
echo "================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Auto-update script
# All paths are hardcoded — no variable assignments — so the script runs
# correctly under systemd's minimal environment without any surprises.
# =============================================================================

tee /usr/local/sbin/autoupdate.sh > /dev/null << 'EOF'
#!/bin/bash

# Prevent concurrent runs
exec 9>/var/lock/autoupdate.lock
if ! flock -n 9; then
    echo "autoupdate already running — exiting" >&2
    exit 1
fi

# Rotate previous log then redirect all output into fresh log
[[ -f /var/log/autoupdate.log ]] && mv /var/log/autoupdate.log /var/log/autoupdate.log.1
: > /var/log/autoupdate.log
exec >> /var/log/autoupdate.log 2>&1

echo "========== Auto Update Started - $(date) =========="

echo "========== Creating pre-update LVM snapshot - $(date) =========="
ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null)"
SNAPSHOT_CREATED=false
if [[ -n "$ROOT_DEV" ]] && command -v lvcreate >/dev/null 2>&1; then
    SNAP_VG="$(lvs --noheadings -o vg_name "$ROOT_DEV" 2>/dev/null | tr -d ' ')"
    SNAP_LV="$(lvs --noheadings -o lv_name "$ROOT_DEV" 2>/dev/null | tr -d ' ')"
    SNAP_NAME="${SNAP_LV}-snap-$(date +%Y%m%d)"
    if [[ -n "$SNAP_VG" ]] && [[ -n "$SNAP_LV" ]]; then
        lvremove -f "${SNAP_VG}/${SNAP_NAME}" 2>/dev/null || true
        if lvcreate -s -n "$SNAP_NAME" -L 10G "/dev/${SNAP_VG}/${SNAP_LV}"; then
            echo "LVM snapshot created: /dev/${SNAP_VG}/${SNAP_NAME}"
            SNAPSHOT_CREATED=true
        else
            echo "WARNING: LVM snapshot creation failed — continuing without snapshot"
        fi
    else
        echo "Could not determine LVM VG/LV — skipping snapshot"
    fi
else
    echo "Root not on LVM or lvcreate unavailable — skipping snapshot"
fi

echo "========== Checking disk space - $(date) =========="
MIN_FREE_GB=5
for check_path in / /var/tmp; do
    avail="$(df -BG "$check_path" --output=avail 2>/dev/null | tail -n1 | tr -d 'G ')"
    if (( avail < MIN_FREE_GB )); then
        echo "ERROR: Less than ${MIN_FREE_GB}G free on $check_path (${avail}G available) — aborting to avoid inconsistent package state"
        exit 1
    fi
    echo "  $check_path: ${avail}G free"
done
echo "Disk space check passed"

echo "========== Syncing Portage tree - $(date) =========="
emaint -a sync

echo "========== Updating Portage itself - $(date) =========="
emerge --oneshot sys-apps/portage

echo "========== Updating packages - $(date) =========="
if ! emerge --ask=n -vuDNU @world; then
    echo "ERROR: @world update failed — see dependency/merge output above. Aborting before further steps."
    exit 1
fi

echo "========== Removing unneeded dependencies - $(date) =========="
echo "Packages that will be removed:"
emerge -p --depclean 2>/dev/null || true
emerge --ask=n --depclean --verbose

echo "========== Rebuilding preserved packages - $(date) =========="
emerge --ask=n @preserved-rebuild

echo "========== Checking reverse dependencies - $(date) =========="
revdep-rebuild -- --ask=n

echo "========== Rebuilding kernel modules after package updates - $(date) =========="
emerge --ask=n @module-rebuild || echo "WARNING: module rebuild failed — continuing"

echo "========== Discarding pending config updates - $(date) =========="
# Deliberately does NOT call etc-update in any --automode here. Every
# automode has an interactive assumption baked in: -5 (auto-merge) doesn't
# just merge cosmetic changes -- it's -3's OVERWRITE_ALL=yes plus a
# non-interactive mv, i.e. it blindly overwrites EVERY pending file with
# the new version (this previously ran as -5 and would have clobbered
# sshd_config/SELinux config unattended -- see the config review from this
# session for what that actually looked like). -7 (discard, keep current)
# still shells out to `rm -i` per file, because /etc/etc-update.conf sets
# rm_opts="-i" by default -- only -9 clears that, and -9 itself requires
# typing YES at a prompt. There's no automode here that's safe to run
# unattended, so pending files are removed directly with a plain `find
# -delete` -- this only ever deletes the proposed NEW file sitting
# alongside the live one; it can never touch or overwrite the running
# config. The list is logged to pending-configs-discarded.log first, so a
# silently-dropped upstream config change can still be traced later if
# something needs troubleshooting -- it just won't be auto-applied.
PENDING_CONFIGS="$(find /etc -name '._cfg*' 2>/dev/null)"
if [[ -n "$PENDING_CONFIGS" ]]; then
    echo "Discarding pending config updates (current configs unchanged):"
    echo "$PENDING_CONFIGS"
    {
        echo "=== $(date) ==="
        echo "$PENDING_CONFIGS"
    } >> /var/log/pending-configs-discarded.log
    find /etc -name '._cfg*' -delete
else
    echo "No pending config updates"
fi

echo "========== Refreshing security baselines - $(date) =========="
if [[ -f /etc/systemd/system/rkhunter-propupd.service ]]; then
    systemctl start --wait rkhunter-propupd.service || echo "WARNING: rkhunter-propupd.service failed — review journalctl -u rkhunter-propupd.service"
else
    echo "rkhunter-propupd.service not installed — skipping (run gentoo-rkhunter.sh to set it up)"
fi
if [[ -f /etc/systemd/system/aide-update.service ]]; then
    systemctl start --wait aide-update.service || echo "WARNING: aide-update.service failed — review journalctl -u aide-update.service"
else
    echo "aide-update.service not installed — skipping (run gentoo-aide.sh to set it up)"
fi

echo "========== Checking systemd - $(date) =========="
if [[ "$(stat -c %Y /usr/lib/systemd/systemd)" -gt "$(date -d "$(uptime -s)" +%s)" ]]; then
    echo "systemd updated — executing daemon-reexec"
    systemctl daemon-reexec
else
    echo "systemd unchanged — executing daemon-reload"
    systemctl daemon-reload
fi

echo "========== Rebuilding kernel if new source available - $(date) =========="
LATEST_SRC_DIR="$(ls -1d /usr/src/linux-* 2>/dev/null | sort -V | tail -n 1)"
LATEST_SRC_VER="${LATEST_SRC_DIR##*/linux-}"
if [[ -z "$LATEST_SRC_VER" ]]; then
    echo "No kernel source found in /usr/src — skipping kernel rebuild"
elif [[ "$(uname -r)" == "$LATEST_SRC_VER"* ]]; then
    echo "Kernel source current ($(uname -r)) — no rebuild needed"
elif compgen -G "/lib/modules/${LATEST_SRC_VER}*" > /dev/null; then
    echo "Kernel $LATEST_SRC_VER already built — skipping rebuild"
else
    echo "New kernel source detected ($(uname -r) -> $LATEST_SRC_VER) — rebuilding"
    ln -sfn "$LATEST_SRC_DIR" /usr/src/linux
    # Apply persistent kernel config fragment if available
    if [[ -f /etc/kernel/gentoo-extra-kconfig ]]; then
        make -C /usr/src/linux defconfig
        (cd /usr/src/linux && scripts/kconfig/merge_config.sh -m .config /etc/kernel/gentoo-extra-kconfig)
        make -C /usr/src/linux olddefconfig
        cp /usr/src/linux/.config /tmp/gentoo-merged-kconfig
        if grep -qE '^[^#]' /etc/crypttab 2>/dev/null && command -v cryptsetup >/dev/null 2>&1; then
            genkernel --luks --lvm all --kernel-config=/tmp/gentoo-merged-kconfig
        else
            genkernel all --kernel-config=/tmp/gentoo-merged-kconfig
        fi
    else
        echo "WARNING: /etc/kernel/gentoo-extra-kconfig not found — building with default config"
        if grep -qE '^[^#]' /etc/crypttab 2>/dev/null && command -v cryptsetup >/dev/null 2>&1; then
            genkernel --luks --lvm all
        else
            genkernel all
        fi
    fi
    # Sync updates/ directory to newly built modules
    KVER_NEW="$(ls /lib/modules/ | sort -V | tail -1)"
    UPDATES_DIR="/lib/modules/${KVER_NEW}/updates"
    if [[ -d "$UPDATES_DIR" ]]; then
        for ko in "${UPDATES_DIR}"/*.ko "${UPDATES_DIR}"/*.ko.xz "${UPDATES_DIR}"/*.ko.zst; do
            [[ -e "$ko" ]] || continue
            name="$(basename "$ko")"; name="${name%%.*}.ko"
            new_ko="$(find "/lib/modules/${KVER_NEW}/kernel" -name "$name" 2>/dev/null | head -1)"
            [[ -n "$new_ko" ]] && cp "$new_ko" "$ko"
        done
        depmod -a
    fi
    emerge --ask=n @module-rebuild
    if [[ -f /boot/grub/grub.cfg ]] && command -v grub-mkconfig >/dev/null 2>&1; then
        cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak
        grub-mkconfig -o /boot/grub/grub.cfg
    elif [[ -f /boot/extlinux/extlinux.conf ]]; then
        cp /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.bak
        echo "extlinux config detected — backed up; verify new kernel entry manually if needed"
    else
        echo "WARNING: No recognized bootloader config found — skipping bootloader update"
    fi
    if command -v sbctl >/dev/null 2>&1; then
        echo "Signing new kernel EFI files for Secure Boot..."
        for efi in /boot/*.efi /boot/EFI/Linux/*.efi; do
            [[ -f "$efi" ]] && sbctl sign -s "$efi"
        done
    fi
    echo "Kernel rebuild complete"
fi

echo "========== Checking kernel - $(date) =========="
LATEST_MOD="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "$LATEST_MOD" ]]; then
    echo "No kernel modules found in /lib/modules — skipping kernel check"
elif [[ "$(uname -r)" != "$LATEST_MOD" ]]; then
    echo "Kernel updated ($(uname -r) -> $LATEST_MOD) — rebooting in 1 minute"
    /usr/bin/shutdown -r +1 "Kernel updated: scheduled reboot"
else
    echo "Kernel unchanged ($(uname -r)) — no reboot required"
fi

echo "========== Removing pre-update LVM snapshot - $(date) =========="
if [[ "$SNAPSHOT_CREATED" == "true" ]] && lvs "${SNAP_VG}/${SNAP_NAME}" >/dev/null 2>&1; then
    lvremove -f "${SNAP_VG}/${SNAP_NAME}"
    echo "Pre-update snapshot /dev/${SNAP_VG}/${SNAP_NAME} removed"
fi

echo "========== Auto Update Finished - $(date) =========="
EOF

chmod 700 /usr/local/sbin/autoupdate.sh

# =============================================================================
# Systemd service and timer
# =============================================================================

tee /etc/systemd/system/autoupdate.service > /dev/null << 'EOF'
[Unit]
Description=Automatic System Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/usr/local/sbin/autoupdate.sh
EOF

tee /etc/systemd/system/autoupdate.timer > /dev/null << 'EOF'
[Unit]
Description=Automatic System Update

[Timer]
OnCalendar=Sat *-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now autoupdate.timer

echo
echo "Auto-update configured — runs weekly on Saturday at 05:00."
echo "Update log: /var/log/autoupdate.log"
echo "ClamAV/rkhunter/AIDE scans run on their own daily timers — see"
echo "gentoo-clamav.sh, gentoo-rkhunter.sh, gentoo-aide.sh."
