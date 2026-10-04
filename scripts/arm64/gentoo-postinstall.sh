#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

LOG_FILE="${BASH_SOURCE[0]%.sh}.log"
exec > >(tee "$LOG_FILE") 2>&1

# Ensure the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

# =============================================================================
# Gentoo Post-Install Master Script (Desktop)
# Runs all post-install tasks automatically in order.
#
# this script completes, Secure Boot is enrolled, and the system has been
# rebooted with Secure Boot enabled:
# =============================================================================

export GENTOO_POSTINSTALL=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TASKS=(
    # Phase 1 — Core security hardening
    "${SCRIPT_DIR}/gentoo-ufw.sh"
    "${SCRIPT_DIR}/gentoo-sysctl.sh"
    "${SCRIPT_DIR}/gentoo-fstab.sh"
    "${SCRIPT_DIR}/gentoo-ssh.sh"
    "${SCRIPT_DIR}/gentoo-sudo.sh"
    "${SCRIPT_DIR}/gentoo-pam.sh"
    "${SCRIPT_DIR}/gentoo-fail2ban.sh"
    "${SCRIPT_DIR}/gentoo-audit.sh"
    # Phase 2 — System configuration
    "${SCRIPT_DIR}/gentoo-logrotate.sh"
    "${SCRIPT_DIR}/gentoo-autoupdate.sh"
    "${SCRIPT_DIR}/gentoo-compilers.sh"
    "${SCRIPT_DIR}/gentoo-secureboot.sh"
    "${SCRIPT_DIR}/gentoo-mask-sleep.sh"
    "${SCRIPT_DIR}/gentoo-no-powersave.sh"
    # Phase 3 — System utilities
    "${SCRIPT_DIR}/gentoo-parted.sh"
    "${SCRIPT_DIR}/gentoo-sshfs.sh"
    "${SCRIPT_DIR}/gentoo-gparted.sh"
    "${SCRIPT_DIR}/gentoo-archivetools.sh"
    "${SCRIPT_DIR}/gentoo-touchscreen.sh"
    "${SCRIPT_DIR}/gentoo-window-lock-memory.sh"
    "${SCRIPT_DIR}/gentoo-tmp-cleanup.sh"
    # Phase 4 — Security tools (backend then GUI)
    "${SCRIPT_DIR}/gentoo-clamav.sh"
    "${SCRIPT_DIR}/gentoo-gufw.sh"
    "${SCRIPT_DIR}/gentoo-clamtk.sh"
    # Phase 5 — Desktop applications
    "${SCRIPT_DIR}/gentoo-firefox.sh"
    "${SCRIPT_DIR}/gentoo-featherpad.sh"
    "${SCRIPT_DIR}/gentoo-sddm-theme.sh"
    "${SCRIPT_DIR}/gentoo-cairo-dock.sh"
    "${SCRIPT_DIR}/gentoo-guvcview.sh"
    "${SCRIPT_DIR}/gentoo-pavucontrol.sh"
    "${SCRIPT_DIR}/gentoo-vlc.sh"
    "${SCRIPT_DIR}/gentoo-mediatools.sh"
    "${SCRIPT_DIR}/gentoo-xfburn.sh"
    "${SCRIPT_DIR}/gentoo-gimp.sh"
    "${SCRIPT_DIR}/gentoo-libreoffice.sh"
    "${SCRIPT_DIR}/gentoo-rpi-imager.sh"
    "${SCRIPT_DIR}/gentoo-etcher.sh"
    # Phase 6 — Communication and credentials
    "${SCRIPT_DIR}/gentoo-signal.sh"
    "${SCRIPT_DIR}/gentoo-discord.sh"
    "${SCRIPT_DIR}/gentoo-protonpass.sh"
    "${SCRIPT_DIR}/gentoo-qbittorrent.sh"
    # Phase 7 — Gaming and entertainment
    "${SCRIPT_DIR}/gentoo-wine.sh"
    "${SCRIPT_DIR}/gentoo-winetricks.sh"
    "${SCRIPT_DIR}/gentoo-steam.sh"
    "${SCRIPT_DIR}/gentoo-spotify.sh"
    # Phase 8 — Developer and CLI tools
    "${SCRIPT_DIR}/gentoo-claude.sh"
    "${SCRIPT_DIR}/gentoo-pentest.sh"
    "${SCRIPT_DIR}/gentoo-fastfetch.sh"
    "${SCRIPT_DIR}/gentoo-funtools.sh"
    "${SCRIPT_DIR}/gentoo-wormhole.sh"
    "${SCRIPT_DIR}/gentoo-wormhole-gui.sh"
    # Phase 9 — Finalizers (relabel/scan final system state — must be last)
    "${SCRIPT_DIR}/gentoo-selinux.sh"
    "${SCRIPT_DIR}/gentoo-rkhunter.sh"
    "${SCRIPT_DIR}/gentoo-aide.sh"
)

run_task() {
    local script="$1"
    local name
    name="$(basename "$script")"
    echo
    echo "================================================================"
    echo " Running: ${name}"
    echo "================================================================"
    if [[ ! -f "$script" ]]; then
        echo "--- SKIPPED: ${name} (file not found) ---"
        return 1
    fi
    if bash "$script"; then
        echo "--- Completed: ${name} ---"
        return 0
    else
        echo "--- FAILED: ${name} ---"
        return 1
    fi
}

echo
echo "================================"
echo "  Gentoo Post-Install (Desktop)"
echo "================================"
echo
# Display numbered task list
echo "Available tasks:"
for i in "${!TASKS[@]}"; do
    printf "  %2d. %s\n" "$((i+1))" "$(basename "${TASKS[$i]}")"
done

echo
echo "Selection format:"
echo "  all         — run all tasks"
echo "  1-5         — run tasks 1 through 5"
echo "  1-3,5,7-9   — run specific tasks and ranges"
echo
read -rp "Enter selection [all]: " SELECTION || true
SELECTION="${SELECTION:-all}"
SELECTION="${SELECTION// /}"

SELECTED_INDICES=()
if [[ "${SELECTION,,}" == "all" ]]; then
    for i in "${!TASKS[@]}"; do SELECTED_INDICES+=( "$i" ); done
else
    IFS=',' read -ra _PARTS <<< "$SELECTION"
    for _part in "${_PARTS[@]}"; do
        if [[ "$_part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for (( _i=${BASH_REMATCH[1]}; _i<=${BASH_REMATCH[2]}; _i++ )); do
                _idx=$(( _i - 1 ))
                [[ $_idx -ge 0 && $_idx -lt ${#TASKS[@]} ]] && SELECTED_INDICES+=( "$_idx" )
            done
        elif [[ "$_part" =~ ^([0-9]+)$ ]]; then
            _idx=$(( ${BASH_REMATCH[1]} - 1 ))
            [[ $_idx -ge 0 && $_idx -lt ${#TASKS[@]} ]] && SELECTED_INDICES+=( "$_idx" )
        else
            echo "WARNING: Unrecognized token '${_part}' — skipping"
        fi
    done
fi

echo
echo "Running ${#SELECTED_INDICES[@]} of ${#TASKS[@]} tasks..."
echo

FAILED=0
FAILED_TASKS=()

for _idx in "${SELECTED_INDICES[@]}"; do
    if ! run_task "${TASKS[$_idx]}"; then
        FAILED=$(( FAILED + 1 ))
        FAILED_TASKS+=( "$(basename "${TASKS[$_idx]}")" )
    fi
done

echo
echo "================================================================"
echo " Post-install complete"
echo "================================================================"
echo

if (( FAILED > 0 )); then
    echo "${FAILED} task(s) failed:"
    for t in "${FAILED_TASKS[@]}"; do
        echo "  - $t"
    done
else
    echo "All tasks completed successfully."
fi

echo
if grep -qE '^[^#]' /etc/crypttab 2>/dev/null; then
    echo "NEXT STEP — TPM auto-unlock setup:"
    echo "  1. Reboot and verify Secure Boot is active"
fi
