#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install and configure UFW (default deny in/out with minimal allowlist)
set -eo pipefail

echo "============================="
echo " Gentoo UFW Firewall Setup"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "Installing UFW..."
# Ensure iptables uses the nftables kernel backend (iptables-nft). The legacy
# backend requires ip_tables.ko which is not in the standard kernel config;
# the nftables backend uses nf_tables which is included.
mkdir -p /etc/portage/package.use
if ! grep -q 'net-firewall/iptables' /etc/portage/package.use/iptables 2>/dev/null; then
    echo "net-firewall/iptables nftables" > /etc/portage/package.use/iptables
fi
emerge --ask=n net-firewall/iptables net-firewall/ufw

# Switch all iptables symlinks to the nft backend.
# emerge alone does not update the symlinks — eselect must be called explicitly.
eselect iptables set xtables-nft-multi

# Ensure nf_tables and xt_tables modules are loaded — modern Gentoo builds
# iptables with the nftables backend (iptables-nft) which requires nf_tables.
# These are =m in the kernel config so must be explicitly loaded before UFW
# starts, both here and at every boot.
_missing_mods=()
for _mod in nf_tables nft_compat nf_conntrack x_tables; do
    modprobe "$_mod" 2>/dev/null || _missing_mods+=("$_mod")
done
if [[ ${#_missing_mods[@]} -gt 0 ]]; then
    echo "WARNING: Failed to load kernel modules: ${_missing_mods[*]}"
    echo "The kernel may need to be rebuilt — run kernel-rebuild.sh then reboot."
fi
unset _missing_mods _mod

# xt_LOG provides the LOG target used in UFW's audit rules (user.rules
# ### LOGGING ### section). CONFIG_NFT_LOG is not set on this kernel so
# iptables-nft cannot use the native nf_tables log expression and must fall
# back to xt_LOG via nft_compat. nf_log_syslog is the syslog backend that
# xt_LOG dispatches through. Load these explicitly; autoloading from inside
# iptables-restore is unreliable in some post-install environments.
for _mod in xt_LOG nf_log_syslog; do
    modprobe "$_mod" 2>/dev/null || true
done
unset _mod

# Write a modules-load.d entry so these modules are loaded at boot before
# the UFW service starts.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/netfilter.conf << 'EOF'
nf_tables
nft_compat
nf_conntrack
x_tables
xt_LOG
nf_log_syslog
EOF

if ! iptables -L >/dev/null 2>&1; then
    echo
    echo "WARNING: iptables is not functional — the running kernel lacks netfilter support."
    echo "UFW has been installed but cannot be activated until the kernel is rebuilt."
    echo "Rebuild the kernel with kernel-rebuild.sh, reboot, then re-run this script."
    echo
    exit 0
fi

# iptables-nft can LIST rules without nft_compat, but UFW needs to CREATE custom
# chains (ufw-before-input, ufw-not-local, etc.). Test chain creation now so we
# give a clear diagnostic instead of a cryptic iptables-restore failure inside
# 'ufw --force enable'.
_probe="ufw-nft-probe-$$"
if ! iptables -N "$_probe" 2>/dev/null; then
    iptables -X "$_probe" 2>/dev/null || true
    echo
    echo "WARNING: iptables can list rules but cannot create chains."
    echo "The nft_compat kernel module is not loaded. UFW requires nft_compat to"
    echo "create its internal chains with the nf_tables backend."
    echo "UFW has been installed but cannot be activated."
    echo "Rebuild the kernel with kernel-rebuild.sh, reboot, then re-run this script."
    echo
    exit 0
fi
iptables -X "$_probe" 2>/dev/null || true
unset _probe

# Force nft_compat to fully initialize its compat table infrastructure before
# UFW's ufw-init-functions runs iptables-restore -n. When nft_compat is freshly
# loaded, modprobe returns before the 'ip filter' compat table exists. The first
# 'iptables-restore -n' call inside ufw-init that appends to built-in chains
# (INPUT/OUTPUT/FORWARD) then fails because the table isn't ready yet, leaving
# none of the UFW chains created. Listing all chains forces the compat table to
# be created and fully registered before any restore operations run.
iptables -L >/dev/null 2>&1 || true
ip6tables -L >/dev/null 2>&1 || true

echo "Resetting UFW to a clean state..."
ufw --force reset

# =============================================================================
# Default policies — set before any rules
# =============================================================================

ufw default deny incoming
ufw default deny outgoing
ufw default deny forward

# =============================================================================
# Loopback — required for local inter-process communication
# =============================================================================

ufw allow in  on lo comment 'Loopback'
ufw allow out on lo comment 'Loopback'

# =============================================================================
# Incoming
# =============================================================================

ufw allow in 22/tcp comment 'SSH'

# =============================================================================
# Outgoing
# =============================================================================

# DHCP — client sends from port 68 to port 67; response arrives on port 68.
# The response is not reliably tracked as ESTABLISHED over broadcast so both
# directions are specified explicitly.
ufw allow out proto udp from any port 68 to any port 67 comment 'DHCP request'
ufw allow in  proto udp from any port 67 to any port 68 comment 'DHCP response'

# DNS — UDP for normal queries, TCP for large responses / DNSSEC
ufw allow out to any port 53 comment 'DNS'

# NTP — time synchronisation
ufw allow out proto udp to any port 123 comment 'NTP'

# rsync — Portage tree sync via 'emerge --sync' (rsync protocol)
ufw allow out proto tcp to any port 873 comment 'rsync (Portage sync)'

# HTTP / HTTPS — package downloads, Portage distfiles, emerge-webrsync
ufw allow out proto tcp to any port 80  comment 'HTTP'
ufw allow out proto tcp to any port 443 comment 'HTTPS'

# SSH — outgoing SSH connections
ufw allow out proto tcp to any port 22  comment 'SSH'

# ICMP — outgoing ping and traceroute for network diagnostics
# UFW's CLI does not support ICMP rules in this version; inject directly into
# before.rules instead. ufw --force reset above already created the file.
if ! grep -q 'ufw-before-output.*icmp' /etc/ufw/before.rules 2>/dev/null; then
    sed -i '/^COMMIT/i \
# ok icmp codes for OUTPUT\
-A ufw-before-output -p icmp --icmp-type destination-unreachable -j ACCEPT\
-A ufw-before-output -p icmp --icmp-type time-exceeded -j ACCEPT\
-A ufw-before-output -p icmp --icmp-type parameter-problem -j ACCEPT\
-A ufw-before-output -p icmp --icmp-type echo-request -j ACCEPT\
' /etc/ufw/before.rules
fi

# Syslog TLS — remote encrypted log shipping
ufw allow out proto tcp to any port 6514 comment 'Syslog TLS'


# =============================================================================
# Enable
# =============================================================================

# iptables-nft 1.8.x threshold bug: iptables-restore -n fails to create any
# new chains once the filter table already has 18+ custom chains. This breaks
# EVERY ufw-init step after the initial restore (logging-deny, skip-to-policy,
# user chains, and all rule file loads all fail). Pre-creating a few chains
# does not help — the initial restore deletes extra chains not in its block.
#
# Fix: replace ExecStart with a custom script that creates ALL 35 UFW chains
# atomically in ONE iptables-restore call (no -n, clean slate), then loads
# rule files with iptables-restore -n. Since no new chains are created in
# subsequent calls, the threshold bug is never triggered.
echo "Enabling UFW..."
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
sed -i 's/^LOGLEVEL=.*/LOGLEVEL=low/' /etc/ufw/ufw.conf

echo "Installing UFW start script..."
cat > /usr/share/ufw/ufw-nft-start << 'STARTSCRIPT'
#!/bin/sh
# Custom UFW start for iptables-nft 1.8.x threshold bug:
# iptables-restore -n fails to create new chains when the filter table already
# has 18+ custom chains. Creates ALL 35 UFW chains in one iptables-restore
# (no -n, clean slate), then loads rule files with -n (rules only, no new chains).

PATH="/sbin:/bin:/usr/sbin:/usr/bin"
DATA_DIR=""

for _s in "${DATA_DIR}/etc/default/ufw" "${DATA_DIR}/etc/ufw/ufw.conf"; do
    [ -s "$_s" ] || { echo "Could not find $_s (aborting)"; exit 1; }
    . "$_s"
done

RULES_PATH="/etc/ufw"
USER_PATH="/etc/ufw"

[ "$ENABLED" = "yes" ] || [ "$ENABLED" = "YES" ] || {
    echo "Skip starting firewall: ufw (not enabled)"
    exit 0
}

if iptables -L ufw-user-input -n >/dev/null 2>&1; then
    echo "Firewall already started, use 'force-reload'"
    exit 0
fi

for _m in $IPT_MODULES; do modprobe "$_m" || true; done
modprobe -a xt_LOG nf_log_syslog xt_limit || true

_execs="iptables"
if [ "$IPV6" = "yes" ] || [ "$IPV6" = "YES" ]; then
    ip6tables -L INPUT -n >/dev/null 2>&1 && _execs="$_execs ip6tables"
fi

_err=""

for _exe in $_execs; do
    _t=""
    [ "$_exe" = "ip6tables" ] && _t="6"
    _before="$RULES_PATH/before${_t}.rules"
    _after="$RULES_PATH/after${_t}.rules"
    _user="$USER_PATH/user${_t}.rules"

    # One iptables-restore (no -n) creates ALL 35 UFW chains from a clean
    # slate. Zero pre-existing custom chains → no threshold bug.
    if ! ${_exe}-restore << EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:ufw${_t}-before-logging-input - [0:0]
:ufw${_t}-before-logging-output - [0:0]
:ufw${_t}-before-logging-forward - [0:0]
:ufw${_t}-before-input - [0:0]
:ufw${_t}-before-output - [0:0]
:ufw${_t}-before-forward - [0:0]
:ufw${_t}-after-input - [0:0]
:ufw${_t}-after-output - [0:0]
:ufw${_t}-after-forward - [0:0]
:ufw${_t}-after-logging-input - [0:0]
:ufw${_t}-after-logging-output - [0:0]
:ufw${_t}-after-logging-forward - [0:0]
:ufw${_t}-reject-input - [0:0]
:ufw${_t}-reject-output - [0:0]
:ufw${_t}-reject-forward - [0:0]
:ufw${_t}-track-input - [0:0]
:ufw${_t}-track-output - [0:0]
:ufw${_t}-track-forward - [0:0]
:ufw${_t}-not-local - [0:0]
:ufw${_t}-logging-deny - [0:0]
:ufw${_t}-logging-allow - [0:0]
:ufw${_t}-skip-to-policy-input - [0:0]
:ufw${_t}-skip-to-policy-output - [0:0]
:ufw${_t}-skip-to-policy-forward - [0:0]
:ufw${_t}-user-input - [0:0]
:ufw${_t}-user-output - [0:0]
:ufw${_t}-user-forward - [0:0]
:ufw${_t}-user-logging-input - [0:0]
:ufw${_t}-user-logging-output - [0:0]
:ufw${_t}-user-logging-forward - [0:0]
:ufw${_t}-user-limit - [0:0]
:ufw${_t}-user-limit-accept - [0:0]
-A INPUT -j ufw${_t}-before-logging-input
-A INPUT -j ufw${_t}-before-input
-A INPUT -j ufw${_t}-after-input
-A INPUT -j ufw${_t}-after-logging-input
-A INPUT -j ufw${_t}-reject-input
-A INPUT -j ufw${_t}-track-input
-A OUTPUT -j ufw${_t}-before-logging-output
-A OUTPUT -j ufw${_t}-before-output
-A OUTPUT -j ufw${_t}-after-output
-A OUTPUT -j ufw${_t}-after-logging-output
-A OUTPUT -j ufw${_t}-reject-output
-A OUTPUT -j ufw${_t}-track-output
-A FORWARD -j ufw${_t}-before-logging-forward
-A FORWARD -j ufw${_t}-before-forward
-A FORWARD -j ufw${_t}-after-forward
-A FORWARD -j ufw${_t}-after-logging-forward
-A FORWARD -j ufw${_t}-reject-forward
-A FORWARD -j ufw${_t}-track-forward
COMMIT
EOF
    then
        echo "iptables-restore failed for ${_exe}" >&2
        _err="yes"
        continue
    fi

    # All remaining -n calls only append rules to existing chains — no new
    # chain creation, no threshold bug.

    # Skip-to-policy chains
    printf '*filter\n-A ufw%s-skip-to-policy-input -j %s\n-A ufw%s-skip-to-policy-output -j %s\n-A ufw%s-skip-to-policy-forward -j %s\nCOMMIT\n' \
        "$_t" "$DEFAULT_INPUT_POLICY" \
        "$_t" "$DEFAULT_OUTPUT_POLICY" \
        "$_t" "$DEFAULT_FORWARD_POLICY" \
        | ${_exe}-restore -n || _err="yes"

    # Reject rules (only when policy=REJECT)
    if [ "$DEFAULT_INPUT_POLICY" = "REJECT" ]; then
        printf '*filter\n-A ufw%s-reject-input -j REJECT\nCOMMIT\n' "$_t" | ${_exe}-restore -n || _err="yes"
    fi
    if [ "$DEFAULT_OUTPUT_POLICY" = "REJECT" ]; then
        printf '*filter\n-A ufw%s-reject-output -j REJECT\nCOMMIT\n' "$_t" | ${_exe}-restore -n || _err="yes"
    fi
    if [ "$DEFAULT_FORWARD_POLICY" = "REJECT" ]; then
        printf '*filter\n-A ufw%s-reject-forward -j REJECT\nCOMMIT\n' "$_t" | ${_exe}-restore -n || _err="yes"
    fi

    # Track rules (only when policy=ACCEPT)
    if [ "$DEFAULT_INPUT_POLICY" = "ACCEPT" ]; then
        printf '*filter\n-A ufw%s-track-input -p tcp -m conntrack --ctstate NEW -j ACCEPT\n-A ufw%s-track-input -p udp -m conntrack --ctstate NEW -j ACCEPT\nCOMMIT\n' \
            "$_t" "$_t" | ${_exe}-restore -n || _err="yes"
    fi
    if [ "$DEFAULT_OUTPUT_POLICY" = "ACCEPT" ]; then
        printf '*filter\n-A ufw%s-track-output -p tcp -m conntrack --ctstate NEW -j ACCEPT\n-A ufw%s-track-output -p udp -m conntrack --ctstate NEW -j ACCEPT\nCOMMIT\n' \
            "$_t" "$_t" | ${_exe}-restore -n || _err="yes"
    fi
    if [ "$DEFAULT_FORWARD_POLICY" = "ACCEPT" ]; then
        printf '*filter\n-A ufw%s-track-forward -p tcp -m conntrack --ctstate NEW -j ACCEPT\n-A ufw%s-track-forward -p udp -m conntrack --ctstate NEW -j ACCEPT\nCOMMIT\n' \
            "$_t" "$_t" | ${_exe}-restore -n || _err="yes"
    fi

    # Load rule files stripping chain declarations (threshold bug also fires for
    # counter-resets in -n mode). Also strip -m limit from all rules: this
    # kernel build has CONFIG_NFT_LIMIT=n and no nft_limit.ko module, so
    # iptables-nft (which translates -m limit to native nft limit rate) always
    # fails with ENOENT. Strip the limit match in-place via sed so the rest of
    # each rule (including the jump target) is preserved.
    # LOG rules from user files are fully stripped and reapplied below.
    if [ -s "$_before" ]; then
        { printf '*filter\n'
          grep '^-' "$_before" | sed 's/ -m limit --limit [^ ]* --limit-burst [0-9]*//'
          printf 'COMMIT\n'
        } | ${_exe}-restore -n || { echo "Problem running '$_before'" >&2; _err="yes"; }
    fi
    if [ -s "$_after" ]; then
        { printf '*filter\n'
          grep '^-' "$_after" | sed 's/ -m limit --limit [^ ]* --limit-burst [0-9]*//'
          printf 'COMMIT\n'
        } | ${_exe}-restore -n || { echo "Problem running '$_after'" >&2; _err="yes"; }
    fi
    if [ -s "$_user" ]; then
        { printf '*filter\n'
          grep '^-' "$_user" | grep -vE ' -j LOG | -m limit '
          printf 'COMMIT\n'
        } | ${_exe}-restore -n || { echo "Problem running '$_user'" >&2; _err="yes"; }
        # Apply LOG rules via individual iptables commands without -m limit
        # (no rate limiting — nft_limit kernel support absent on this build).
        ${_exe} -A "ufw${_t}-after-logging-input"  -j LOG --log-prefix "[UFW BLOCK] " || _err="yes"
        ${_exe} -A "ufw${_t}-after-logging-output" -j LOG --log-prefix "[UFW BLOCK] " || _err="yes"
        ${_exe} -A "ufw${_t}-after-logging-forward" -j LOG --log-prefix "[UFW BLOCK] " || _err="yes"
        ${_exe} -I "ufw${_t}-logging-deny" 1 -m conntrack --ctstate INVALID -j RETURN || _err="yes"
        ${_exe} -A "ufw${_t}-logging-deny" -j LOG --log-prefix "[UFW BLOCK] " || _err="yes"
        ${_exe} -A "ufw${_t}-logging-allow" -j LOG --log-prefix "[UFW ALLOW] " || _err="yes"
        ${_exe} -A "ufw${_t}-user-limit"   -j LOG --log-prefix "[UFW LIMIT BLOCK] " || _err="yes"
        # Wire user chains into before chains
        printf '*filter\n-A ufw%s-before-input -j ufw%s-user-input\n-A ufw%s-before-output -j ufw%s-user-output\n-A ufw%s-before-forward -j ufw%s-user-forward\nCOMMIT\n' \
            "$_t" "$_t" "$_t" "$_t" "$_t" "$_t" | ${_exe}-restore -n || _err="yes"
    fi
done

# Set default policies last (keeps network accessible during init)
for _exe in $_execs; do
    _t=""
    [ "$_exe" = "ip6tables" ] && _t="6"
    _inp="$DEFAULT_INPUT_POLICY";   [ "$_inp" = "REJECT" ] && _inp="DROP"
    _out="$DEFAULT_OUTPUT_POLICY";  [ "$_out" = "REJECT" ] && _out="DROP"
    _fwd="$DEFAULT_FORWARD_POLICY"; [ "$_fwd" = "REJECT" ] && _fwd="DROP"
    printf '*filter\n:INPUT %s [0:0]\n:FORWARD %s [0:0]\n:OUTPUT %s [0:0]\nCOMMIT\n' \
        "$_inp" "$_fwd" "$_out" | ${_exe}-restore -n || _err="yes"
done

[ -n "$IPT_SYSCTL" ] && [ -s "$IPT_SYSCTL" ] && sysctl -e -q -p "$IPT_SYSCTL" || true

[ "$_err" = "yes" ] && { echo "Firewall setup failed" >&2; exit 1; }
echo "Firewall is active and enabled on system startup"
STARTSCRIPT
chmod +x /usr/share/ufw/ufw-nft-start

echo "Enabling UFW on boot..."
# UFW's unit has DefaultDependencies=no so it starts before network.target and
# can race ahead of systemd-modules-load.service at boot. Without nf_tables and
# nft_compat loaded, iptables-nft cannot create chains and every rule append
# fails. This drop-in adds an explicit After= ordering so the modules are always
# present before ufw-nft-start runs.
mkdir -p /etc/systemd/system/ufw.service.d
cat > /etc/systemd/system/ufw.service.d/after-modules-load.conf << 'EOF'
[Unit]
After=systemd-modules-load.service

[Service]
ExecStart=
ExecStart=/usr/share/ufw/ufw-nft-start
EOF
systemctl daemon-reload
systemctl enable --now ufw.service

echo
ufw status verbose

echo
echo "UFW configured and enabled."
echo
echo "Optional rules not included — add manually if needed:"
echo "  587/tcp out  — SMTP submission (system email alerts from cron etc.)"
echo "  5353/udp out — mDNS/Avahi (local service discovery on desktop)"
echo "   43/tcp out  — Whois"
