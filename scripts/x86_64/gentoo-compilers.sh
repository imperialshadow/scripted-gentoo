#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install compilers, language runtimes, and build tools
set -eo pipefail

echo "=================================="
echo " Compilers & Build Tools Install"
echo "=================================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# =============================================================================
# USE flag configuration
# =============================================================================

mkdir -p /etc/portage/package.use

# gfortran is gated by a USE flag on gcc rather than a separate package
if ! grep -q 'sys-devel/gcc' /etc/portage/package.use/compilers 2>/dev/null; then
    echo "sys-devel/gcc fortran" >> /etc/portage/package.use/compilers
fi

# npm is gated by a USE flag on nodejs
if ! grep -q 'net-libs/nodejs' /etc/portage/package.use/compilers 2>/dev/null; then
    echo "net-libs/nodejs npm" >> /etc/portage/package.use/compilers
fi

# www-client/firefox's USE=clang pulls in the full clang/LLVM toolchain,
# which defaults to building for every ABI_X86 in make.conf (64 32 here,
# needed globally for Wine/Steam). The i386 build of
# llvm-runtimes/compiler-rt-sanitizers fails to link (undefined reference
# to pthread_atfork/__tls_get_addr -- a known class of upstream/Gentoo
# LLVM packaging bug). Nothing needs 32-bit clang/sanitizers on this
# system (GCC is the default compiler), so disable abi_x86_32 for just
# the clang/LLVM toolchain rather than touching ABI_X86 globally.
if ! grep -q 'llvm-core/clang -abi_x86_32' /etc/portage/package.use/compilers 2>/dev/null; then
    cat >> /etc/portage/package.use/compilers << 'EOF'
llvm-core/clang -abi_x86_32
llvm-core/clang-common -abi_x86_32
llvm-runtimes/clang-runtime -abi_x86_32
llvm-runtimes/compiler-rt -abi_x86_32
llvm-runtimes/compiler-rt-sanitizers -abi_x86_32
EOF
fi

# =============================================================================
# LLVM / Clang toolchain
# =============================================================================

emerge --ask=n --verbose \
    llvm-core/llvm \
    llvm-core/clang \
    llvm-core/lld

# =============================================================================
# Language runtimes
# =============================================================================

emerge --ask=n --verbose \
    dev-lang/go \
    dev-lang/nasm \
    dev-lang/yasm \
    net-libs/nodejs

# Rust — binary distribution installs in minutes; fall back to source build
# if the binary package is unavailable for this architecture
emerge --ask=n --verbose dev-lang/rust-bin || \
    emerge --ask=n --verbose dev-lang/rust || \
    echo "WARNING: Rust not available for this architecture — skipping."

# Java — latest available OpenJDK; not supported on all architectures (e.g. arm 32-bit)
emerge --ask=n --verbose dev-java/openjdk || \
    echo "WARNING: OpenJDK not available for this architecture — skipping."

# =============================================================================
# gfortran — rebuild gcc with fortran USE flag enabled
# =============================================================================

if ! command -v gfortran &>/dev/null; then
    echo "Rebuilding gcc with fortran support..."
    emerge --ask=n --oneshot --verbose sys-devel/gcc
fi

# =============================================================================
# Build systems
# =============================================================================

emerge --ask=n --verbose \
    dev-build/autoconf \
    dev-build/automake \
    dev-build/cmake \
    dev-build/libtool \
    dev-build/meson \
    dev-build/ninja

# =============================================================================
# Development utilities
# =============================================================================

emerge --ask=n --verbose \
    dev-util/ccache \
    dev-util/patchelf \
    dev-util/pkgconf \
    dev-debug/strace \
    dev-vcs/git \
    dev-debug/gdb

# Valgrind — not available on all architectures
emerge --ask=n --verbose dev-util/valgrind || \
    echo "WARNING: valgrind not available for this architecture — skipping."

echo
echo "Compilers and build tools installed."
echo
echo "  Compilers:     gcc (g++, gfortran), clang/clang++, nasm, yasm"
echo "  Languages:     Go, Rust/Cargo, Java (OpenJDK), Node.js/npm"
echo "  LLVM tools:    llvm, lld, clang-format, clang-tidy"
echo "  Build systems: cmake, meson, ninja, autoconf, automake, libtool"
echo "  Dev tools:     gdb, valgrind, strace, ccache, patchelf, pkg-config, git"
