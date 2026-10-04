#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Harden PAM — account lockout, password quality, and resource limits
set -eo pipefail

echo "============================="
echo " Gentoo PAM Hardening"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# Install
# pam_faillock is part of sys-libs/pam (already on the system).
# dev-libs/libpwquality provides pam_pwquality.so for password strength checks.
# =============================================================================

PWQUALITY=0
if emerge --ask=n dev-libs/libpwquality; then
    PWQUALITY=1
else
    echo "NOTE: dev-libs/libpwquality not in portage — pam_pwquality will be skipped."
    echo "Password quality enforcement via PAM will not be configured."
fi

# =============================================================================
# pam_faillock — account lockout after repeated failures
#
# pam_faillock acts on the local account regardless of where the attempt came
# from, closing the gap fail2ban leaves (local console, su, sudo, etc.).
# fail2ban blocks the IP; pam_faillock locks the account. Both are needed.
#
# Recovery if locked out: faillock --user <username> --reset
# =============================================================================

tee /etc/security/faillock.conf > /dev/null << 'EOF'
# Lock account after 5 failures within a 10-minute window
deny = 5
fail_interval = 600

# Keep the account locked for 15 minutes, then automatically unlock
unlock_time = 900

# Root can be locked out the same as any other account
even_deny_root

# Audit all lockout events via auditd
audit
EOF

# =============================================================================
# pam_pwquality — password strength enforcement
#
# Enforces rules when a user sets a new password via passwd, sudo, or PAM.
# Does not retroactively expire existing passwords.
# =============================================================================

if (( PWQUALITY )); then
tee /etc/security/pwquality.conf > /dev/null << 'EOF'
# Minimum password length
minlen = 14

# Require at least 1 uppercase, 1 lowercase, 1 digit, 1 symbol
# Positive values = minimum count required; negative = credit (optional bonus)
ucredit = -1
lcredit = -1
dcredit = -1
ocredit = -1

# Reject passwords that contain the username or GECOS field
reject_username = 1
gecoscheck = 1

# Maximum number of consecutive identical characters (e.g. "aaaa")
maxrepeat = 3

# Maximum number of consecutive characters from the same character class
maxclassrepeat = 4

# Reject if new password is too similar to the old one
# (difok = minimum number of characters that must differ)
difok = 5

# Check against cracklib dictionary of common passwords
dictcheck = 1

# Number of times the user is prompted to enter a satisfactory password
# before PAM returns failure (matches retry=3 in system-auth)
retry = 3
EOF
fi

# =============================================================================
# pam_limits — per-user resource caps
#
# Prevents fork bombs, limits core dump exposure (cores can contain keys/passwords),
# and caps open file descriptors.
# =============================================================================

tee /etc/security/limits.d/99-hardening.conf > /dev/null << 'EOF'
# Disable core dumps for all users — cores can contain sensitive memory contents
*    hard    core        0
*    soft    core        0

# Cap max processes per user to prevent fork bombs (adjust if running containers)
*    hard    nproc       10000
*    soft    nproc       5000

# Cap open file descriptors (default 1024 soft is often too low; 65536 is sane)
*    soft    nofile      65536
*    hard    nofile      65536

# Cap max locked memory (relevant for applications using mlockall)
*    soft    memlock     64
*    hard    memlock     64

# Root retains higher limits where needed but core dumps are still disabled
root hard    core        0
root soft    core        0
EOF

# Also disable core dumps via sysctl in case pam_limits is bypassed
# (complements sysctl hardening script)
if ! grep -q 'kernel.core_pattern' /etc/sysctl.d/99-hardening.conf 2>/dev/null; then
    echo "kernel.core_pattern = |/bin/false" >> /etc/sysctl.d/99-hardening.conf
    sysctl -w kernel.core_pattern="|/bin/false" 2>/dev/null || true
fi

# =============================================================================
# /etc/pam.d/system-auth — patch with hardening modules
#
# Rather than replacing system-auth entirely (which strips Gentoo-specific
# modules from whatever the stage3 installed), we patch the existing file to
# insert only what's missing:
#   auth stack    — pam_faillock preauth/authfail/authsucc around pam_unix
#   account stack — pam_faillock before pam_unix
#   password stack — pam_pwquality before pam_unix (if installed)
#   session stack  — pam_limits, pam_selinux close/open, pam_systemd (if absent)
#
# The patcher is idempotent: it checks before adding each line.
# Backup is kept at system-auth.bak for recovery:
#   cp /etc/pam.d/system-auth.bak /etc/pam.d/system-auth
# =============================================================================

if [[ ! -f /etc/pam.d/system-auth ]]; then
    echo "ERROR: /etc/pam.d/system-auth does not exist — cannot patch."
    exit 1
fi

cp /etc/pam.d/system-auth /etc/pam.d/system-auth.bak
echo "Backed up existing system-auth to /etc/pam.d/system-auth.bak"

python3 - "$PWQUALITY" /etc/pam.d/system-auth << 'PYEOF'
import re, sys

PWQUALITY = int(sys.argv[1])
PAM_FILE  = sys.argv[2]

with open(PAM_FILE) as f:
    lines = f.readlines()

# Detect existing state — each check is the condition to SKIP adding that piece
has_faillock_preauth = any('pam_faillock.so preauth' in l for l in lines)
has_faillock_account = any(re.match(r'^account\b', l) and 'pam_faillock.so' in l for l in lines)
has_pwquality        = any('pam_pwquality.so' in l for l in lines)
has_limits           = any(re.match(r'^session\b', l) and 'pam_limits.so' in l for l in lines)
has_selinux_close    = any('pam_selinux.so' in l and 'close' in l for l in lines)
has_selinux_open     = any('pam_selinux.so' in l and 'open' in l for l in lines)
has_systemd          = any(re.match(r'^session\b', l) and 'pam_systemd.so' in l for l in lines)

result = list(lines)

# --- Auth: wrap pam_unix with pam_faillock ---
if not has_faillock_preauth:
    new, done = [], False
    for line in result:
        if not done and re.match(r'^auth\s+', line) and 'pam_unix.so' in line:
            new.append('auth      required      pam_faillock.so preauth silent\n')
            new.append(line)
            new.append('auth      [default=die] pam_faillock.so authfail\n')
            new.append('auth      optional      pam_faillock.so authsucc\n')
            done = True
        else:
            new.append(line)
    result = new
    print("  auth:     added pam_faillock preauth/authfail/authsucc around pam_unix")
else:
    print("  auth:     pam_faillock already present — skipped")

# --- Account: add pam_faillock before pam_unix ---
if not has_faillock_account:
    new, done = [], False
    for line in result:
        if not done and re.match(r'^account\s+', line) and 'pam_unix.so' in line:
            new.append('account   required      pam_faillock.so\n')
            new.append(line)
            done = True
        else:
            new.append(line)
    result = new
    print("  account:  added pam_faillock before pam_unix")
else:
    print("  account:  pam_faillock already present — skipped")

# --- Password: add pam_pwquality before pam_unix ---
if PWQUALITY and not has_pwquality:
    new, done = [], False
    for line in result:
        if not done and re.match(r'^password\s+', line) and 'pam_unix.so' in line:
            new.append('password  required      pam_pwquality.so retry=3\n')
            # Ensure pam_unix uses the token pwquality already collected (avoids double-prompt)
            if 'use_authtok' not in line:
                line = line.rstrip() + ' use_authtok\n'
            new.append(line)
            done = True
        else:
            new.append(line)
    result = new
    print("  password: added pam_pwquality before pam_unix")
elif not PWQUALITY:
    print("  password: pam_pwquality skipped (libpwquality not installed)")
else:
    print("  password: pam_pwquality already present — skipped")

# --- Session: add missing modules ---
session_additions = []
if not has_limits:
    session_additions.append('session   required      pam_limits.so\n')
if not has_selinux_close:
    session_additions.append('session   optional      pam_selinux.so close\n')
if not has_selinux_open:
    session_additions.append('session   optional      pam_selinux.so open nottty\n')
if not has_systemd:
    session_additions.append('session   optional      pam_systemd.so\n')

if session_additions:
    new, inserted = [], False
    for line in result:
        # Insert before the first 'session ... pam_permit.so' line
        if not inserted and re.match(r'^session\s+\S+\s+pam_permit\.so', line):
            new.extend(session_additions)
            inserted = True
        new.append(line)
    if not inserted:
        # Fall back: append after the last session line
        indices = [i for i, l in enumerate(new) if re.match(r'^session\b', l)]
        pos = indices[-1] + 1 if indices else len(new)
        for i, addition in enumerate(session_additions):
            new.insert(pos + i, addition)
    result = new
    for a in session_additions:
        print(f"  session:  added {a.strip()}")
else:
    print("  session:  all modules already present — skipped")

with open(PAM_FILE, 'w') as f:
    f.writelines(result)

print("system-auth patched successfully.")
PYEOF

if [[ $? -ne 0 ]]; then
    echo "ERROR: Python patcher failed. Restoring backup."
    cp /etc/pam.d/system-auth.bak /etc/pam.d/system-auth
    exit 1
fi

# =============================================================================
# Verify the modules we added are actually present on the filesystem
# =============================================================================

echo "Verifying PAM modules are installed..."
MISSING=0
REQUIRED_MODS="pam_faillock.so pam_env.so pam_unix.so pam_limits.so pam_permit.so"
(( PWQUALITY )) && REQUIRED_MODS="$REQUIRED_MODS pam_pwquality.so"
for mod in $REQUIRED_MODS; do
    if ! find /lib /lib64 /usr/lib /usr/lib64 -name "$mod" 2>/dev/null | grep -q .; then
        echo "ERROR: Required PAM module not found: $mod"
        MISSING=$(( MISSING + 1 ))
    fi
done

if (( MISSING > 0 )); then
    echo "ERROR: $MISSING required PAM module(s) missing. Restoring backup."
    cp /etc/pam.d/system-auth.bak /etc/pam.d/system-auth
    exit 1
fi

for mod in pam_selinux.so pam_systemd.so; do
    if ! find /lib /lib64 /usr/lib /usr/lib64 -name "$mod" 2>/dev/null | grep -q .; then
        echo "WARNING: Optional PAM module not found: $mod (session may have reduced functionality)"
    fi
done

echo "All PAM modules verified."

# =============================================================================
# Create /etc/security/opasswd if it doesn't exist (required for remember=5)
# =============================================================================

if [[ ! -f /etc/security/opasswd ]]; then
    install -m 0600 -o root -g root /dev/null /etc/security/opasswd
    echo "Created /etc/security/opasswd for password history."
fi

# =============================================================================
# Create a minimal /etc/security/time.conf (pam_time)
# No restrictions are active by default; add rules here to restrict which
# users can log in from which terminals at which times.
# Format: services;ttys;users;times
# =============================================================================

if [[ ! -f /etc/security/time.conf ]]; then
    tee /etc/security/time.conf > /dev/null << 'EOF'
# /etc/security/time.conf — pam_time access time restrictions
# No rules are active. Add entries below to restrict login times.
# Format: services;ttys;users;times
# Example (block all users except root from SSH on weekends):
#   sshd;*;!root;Sa0000-2400|Su0000-2400
EOF
    echo "Created /etc/security/time.conf (no restrictions active)."
fi

echo
echo "PAM hardening applied."
echo
echo "Summary:"
echo "  pam_faillock  — locks account after 5 failures in 10 min; auto-unlocks after 15 min"
echo "  pam_pwquality — min 14 chars, requires upper/lower/digit/symbol, rejects dict words"
echo "  pam_unix      — existing config preserved; pam_pwquality enforces quality on changes"
echo "  pam_limits    — core dumps disabled, nproc capped, nofile=65536"
echo
echo "To unlock a locked account:"
echo "  faillock --user <username> --reset"
echo
echo "To check failure counts:"
echo "  faillock --user <username>"
