#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Apply kernel hardening via sysctl (network, memory, kernel security)
set -eo pipefail

echo "============================="
echo " Gentoo sysctl Hardening"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# Written to 99-hardening.conf so it loads last within /etc/sysctl.d/ and
# overrides any conflicting defaults from packages or the base system.
mkdir -p /etc/sysctl.d
tee /etc/sysctl.d/99-hardening.conf > /dev/null << 'EOF'
## =============================================================================
## Kernel security
## =============================================================================

# Restrict dmesg to root — prevents unprivileged users reading kernel messages
# that may leak kernel addresses or hardware info useful for exploitation
kernel.dmesg_restrict = 1

# Hide kernel symbol addresses from unprivileged users and root (level 2)
# Level 1: hidden from non-root; level 2: hidden from everyone without CAP_SYSLOG
kernel.kptr_restrict = 2

# Restrict ptrace to parent processes only (level 1)
# Prevents one user process from inspecting/modifying another arbitrary process
# Level 0: unrestricted; 1: parent only; 2: CAP_SYS_PTRACE only; 3: disabled
kernel.yama.ptrace_scope = 1

# Prevent loading a new kernel image via kexec without a reboot
# Critical for Secure Boot — kexec could otherwise bypass the verified boot chain
kernel.kexec_load_disabled = 1

# Disable the magic SysRq key — prevents physical-access attacks via keyboard
kernel.sysrq = 0

# Prevent unprivileged users from creating BPF programs
# BPF has been a common attack surface for local privilege escalation
kernel.unprivileged_bpf_disabled = 1

# Full ASLR — randomise base addresses of stack, mmap, and VDSO
# Level 0: off; 1: conservative; 2: full (heap included)
kernel.randomize_va_space = 2

# Restrict perf_event access to privileged users
# perf can be used to extract sensitive data or assist in exploits
kernel.perf_event_paranoid = 2

## =============================================================================
## Filesystem protections
## =============================================================================

# Disable core dumps for SUID/SGID executables
# Core files from privileged processes can expose sensitive memory contents
fs.suid_dumpable = 0

# Prevent hardlink attacks — only allow hardlinks to files the user owns
# or has read+write access to (prevents /tmp-based privilege escalation)
fs.protected_hardlinks = 1

# Prevent symlink attacks — disallow following symlinks in sticky world-writable
# directories unless the symlink and its target are owned by the same user
fs.protected_symlinks = 1

# Prevent opening FIFOs/pipes in sticky world-writable directories unless the
# FIFO owner matches the directory owner or the opening process (CVE mitigations)
fs.protected_fifos = 2
fs.protected_regular = 2

## =============================================================================
## BPF JIT hardening
## =============================================================================

# Harden the BPF JIT compiler against JIT spraying attacks
# Level 1: constant blinding for unprivileged; level 2: blinding for all
net.core.bpf_jit_harden = 2

## =============================================================================
## IPv4 — routing and redirects
## =============================================================================

# Disable IP forwarding — this machine is not a router
net.ipv4.ip_forward = 0

# Disable source-routed packets — source routing can be used to bypass firewalls
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Do not send ICMP redirects — only routers should send these
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Do not accept ICMP redirects — could redirect traffic through an attacker
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Do not accept secure ICMP redirects from "trusted" gateways either
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

## =============================================================================
## IPv4 — spoofing and martians
## =============================================================================

# Strict reverse path filtering — drop packets whose source address has no
# route back through the interface it arrived on (prevents IP spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log packets with impossible source addresses (martians) for detection
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Only respond to ARP requests addressed to this machine's own IP
net.ipv4.conf.all.arp_ignore = 1

# Always use the best local address when sending ARP replies
net.ipv4.conf.all.arp_announce = 2

## =============================================================================
## IPv4 — ICMP
## =============================================================================

# Ignore ICMP echo requests sent to broadcast addresses (smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore malformed ICMP error responses that violate RFC 1122
net.ipv4.icmp_ignore_bogus_error_responses = 1

## =============================================================================
## IPv4 — TCP hardening
## =============================================================================

# Enable TCP SYN cookies to resist SYN flood denial-of-service attacks
net.ipv4.tcp_syncookies = 1

# Protect against TCP TIME-WAIT assassination (RFC 1337)
net.ipv4.tcp_rfc1337 = 1

# Disable TCP timestamps — prevents remote uptime fingerprinting
net.ipv4.tcp_timestamps = 0

# Reduce SYN and SYN-ACK retransmit attempts to limit exposure during floods
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

## =============================================================================
## IPv6
## =============================================================================

# Disable IPv6 forwarding — this machine is not a router
net.ipv6.conf.all.forwarding = 0

# Disable source-routed IPv6 packets
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Do not accept IPv6 ICMP redirects
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not accept router advertisements — prevents rogue RA attacks
# Disable only if not relying on SLAAC for IPv6 address configuration
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

## =============================================================================
## Memory
## =============================================================================

# Prevent unprivileged use of userfaultfd — has been abused in kernel exploits
# to slow kernel execution and widen race condition windows
vm.unprivileged_userfaultfd = 0

# Reduce swap aggressiveness — keeps more data in RAM and less sensitive
# content written to disk (swap is encrypted via LUKS but minimising is prudent)
vm.swappiness = 10
EOF

echo "Applying sysctl settings..."
# --system re-reads all sysctl.d files; warnings on unsupported params are non-fatal
sysctl --system

echo
echo "Active hardening settings:"
sysctl -a 2>/dev/null | grep -E \
    'dmesg_restrict|kptr_restrict|ptrace_scope|kexec_load|sysrq|bpf_disabled|randomize_va|perf_event_paranoid|suid_dumpable|protected_|bpf_jit_harden|ip_forward|accept_source_route|send_redirects|accept_redirects|secure_redirects|rp_filter|log_martians|arp_ignore|arp_announce|icmp_echo_ignore|icmp_ignore_bogus|tcp_syncookies|tcp_rfc1337|tcp_timestamps|tcp_syn_retries|tcp_synack_retries|ipv6.*forward|ipv6.*accept|unprivileged_userfaultfd|swappiness'

echo
echo "sysctl hardening applied."
echo "Settings persist across reboots via /etc/sysctl.d/99-hardening.conf"
