================================================================================
  GENTOO LINUX AUTOMATED INSTALLATION & POST-INSTALLATION SCRIPTS
================================================================================

  A complete automation suite for installing and hardening Gentoo Linux with
  full-disk encryption (LUKS2+LVM), mandatory access control (SELinux,
  enforcing mode set automatically after initial AVC policy generation at
  post-install time), Secure Boot, and TPM2 auto-unlock. Covers desktop
  (XFCE) and CLI-only installs across four hardware architectures.

================================================================================
  TABLE OF CONTENTS
================================================================================

  1.  Prerequisites & Hardware Requirements
  2.  Directory Structure
  3.  Architecture Sets
  4.  Complete Workflow (Step by Step)
  5.  Script Reference
        5a. Installation Scripts
        5b. Chroot Setup Scripts
        5c. Post-Install Master Scripts
        5d. Post-Install Task Scripts (Security & System)
        5e. Post-Install Task Scripts (Desktop Applications)
        5f. Standalone & Utility Scripts
  6.  Technical Deep Dive
        6a. Disk Layout (LUKS2 + LVM)
        6b. SELinux Integration (All Variants)
        6c. Kernel Configuration
        6d. Secure Boot with sbctl
        6e. TPM2 Auto-Unlock
        6f. Automated Updates (systemd timers)
        6g. PAM Hardening Stack
        6h. Multilib
  7.  Architecture-Specific Notes
  8.  Troubleshooting

================================================================================
  1. PREREQUISITES & HARDWARE REQUIREMENTS
================================================================================

  Required hardware:
    - x86_64, x86, arm64, or arm target machine
    - UEFI firmware (Secure Boot and TPM features require UEFI)
    - TPM 2.0 chip (required only for gentoo-tpm.sh; everything else works
      without a TPM)
    - At minimum 20 GB disk space (40+ GB recommended for desktop installs
      with source-built packages like Firefox and LibreOffice)
    - At least 2 GB RAM. MAKEOPTS uses all available cores (nproc). Swap is
      activated before @world so even machines with limited RAM can complete
      the build. If LLVM OOMs, add a swap file and run emerge --resume.
    - Internet connection during installation (stage3 download and emerge)

  Required on the live environment before running the install script:
    - parted
    - cryptsetup
    - lvm2
    - wget
    - bash (4.0+)

  These are present in the Gentoo minimal install ISO and most live environments
  (SystemRescue, Arch ISO, etc.). Run the install script from any of these.

  The Ventoy USB itself can boot the live environment alongside these scripts.

================================================================================
  2. DIRECTORY STRUCTURE
================================================================================

  scripts/
  ├── README.txt              (this file — identical copy in each arch dir)
  ├── x86_64/                 64-bit Intel / AMD (amd64)
  ├── x86/                    32-bit Intel / AMD (i686)
  ├── arm64/                  64-bit ARM (aarch64)
  └── arm/                    32-bit ARM hard-float (ARMv7, armhf)

  Each architecture directory contains the full set of scripts for all four
  install variants. Scripts are self-contained and discover their directory
  at runtime via BASH_SOURCE[0].

  The four install variants follow a consistent naming scheme:
    gentoo-install.sh              — LUKS-encrypted desktop (XFCE)
    gentoo-install-noluks.sh       — Unencrypted desktop (XFCE)
    gentoo-install-cli.sh          — LUKS-encrypted CLI-only
    gentoo-install-noluks-cli.sh   — Unencrypted CLI-only

  Corresponding chroot scripts (called automatically by their install scripts):
    gentoo-chroot.sh                   — LUKS desktop
    gentoo-chroot-noluks.sh            — Unencrypted desktop
    gentoo-chroot-cli.sh               — LUKS CLI
    gentoo-chroot-noluks-cli.sh        — Unencrypted CLI

  Post-install master scripts (run after first boot):
    gentoo-postinstall.sh              — desktop variants (37 tasks)
    gentoo-postinstall-cli.sh          — CLI variants (23 tasks)

  Utility scripts (in each arch directory):
    kernel-rebuild.sh                  — rebuilds the kernel inside a chroot;
                                         called by gentoo-live-chroot.sh or
                                         run directly on the installed system
    gentoo-live-chroot.sh              — mounts an installed system from a live
                                         USB and offers a kernel rebuild or
                                         rescue shell menu

  noluks variants omit LUKS2/LVM: the second partition is formatted directly
  as ext4 and a swap file is used instead of an LVM logical volume. The
  gentoo-tpm.sh script exits immediately with an explanation when run on a
  noluks install — TPM auto-unlock is only meaningful on encrypted systems.

================================================================================
  3. ARCHITECTURE SETS
================================================================================

  x86_64
  ------
  The reference set. Targets 64-bit Intel and AMD machines. Full feature
  support: NVIDIA proprietary driver (legacy and modern), multilib (ABI_X86),
  all desktop applications including Signal Desktop.

  Stage3 (both desktop and CLI):
    First tries: stage3-amd64-hardened-selinux-systemd
    Fallback:    Desktop: stage3-amd64-desktop-systemd
                 CLI:     stage3-amd64-systemd

  x86
  ---
  Targets 32-bit x86 (i686) machines. Key differences from x86_64:
    - Stage3: first tries stage3-i686-hardened-selinux-systemd,
              fallback desktop: i686-systemd
    - Profile: default/linux/x86/23.0/...
    - GRUB: efi-32 (UEFI) or pc (BIOS); grubia32.efi / BOOTIA32.EFI
    - No ABI_X86 (native 32-bit, multilib is not applicable)
    - No NVIDIA proprietary driver (support was dropped for 32-bit Linux);
      falls back to the nouveau open-source driver
    - Intel GPU detection added (common on older x86 hardware)
    - Signal Desktop not available (Electron is amd64/arm64 only); the
      script prints a clear message and exits cleanly
    - Wine runs 32-bit x86 Windows binaries natively (no multilib needed)

  arm64
  -----
  Targets 64-bit ARM (aarch64) machines: Apple Silicon (via Asahi), Raspberry
  Pi 4/5, Ampere, Qualcomm, etc. Key differences:
    - Stage3: first tries stage3-arm64-hardened-selinux-systemd,
              fallback desktop: arm64-desktop-systemd, CLI: arm64-systemd
    - Profile: default/linux/arm64/23.0/...
    - GRUB: arm64-efi target; grubaa64.efi / BOOTAA64.EFI
    - No ABI_X86
    - No NVIDIA proprietary driver; falls back to nouveau
    - No Intel GPU detection
    - Signal Desktop IS available (~arm64 keyword)
    - Wine runs ARM64 Windows binaries natively; x86 Windows apps require
      box64 (app-emulation/box64) alongside Wine

  arm
  ---
  Targets 32-bit ARM hard-float (ARMv7, armhf): Raspberry Pi 2/3 (32-bit
  mode), BeagleBone, various embedded SBCs. Key differences:
    - Stage3: first tries stage3-armv7a_hardfp-hardened-selinux-systemd,
              fallback: armv7a_hardfp-systemd
    - Profile: default/linux/arm/23.0/...
    - GRUB: arm-efi target; grubarm.efi / BOOTARM.EFI
    - No ABI_X86
    - No NVIDIA proprietary driver; falls back to nouveau
    - No Intel GPU detection
    - Signal Desktop not available (Electron is amd64/arm64 only); stub
    - Wine runs ARM32 Windows binaries natively; x86 Windows apps not
      supported on armhf

================================================================================
  4. COMPLETE WORKFLOW (STEP BY STEP)
================================================================================

  PHASE 1 — Installation (live environment)
  ------------------------------------------
  1. Boot a live Linux environment from the Ventoy USB.
  2. Ensure the target disk is visible (lsblk) and the network is up.
  3. Navigate to the appropriate architecture directory:
       cd /path/to/scripts/x86_64     (adjust for your arch)
  4. Run the install script as root:
       sudo bash gentoo-install.sh              (LUKS-encrypted desktop)
       sudo bash gentoo-install-noluks.sh       (unencrypted desktop)
       sudo bash gentoo-install-cli.sh          (LUKS-encrypted CLI-only)
       sudo bash gentoo-install-noluks-cli.sh   (unencrypted CLI-only)

     The install script will:
       a. Fetch the latest stage3 index (tries the SELinux-hardened stage3
          first, then falls back to the standard systemd stage3 automatically)
       b. Prompt you to select the target disk
       c. Warn you that all data will be destroyed (10-second countdown)
       d. Partition the disk (GPT: 1 GiB EFI + remainder for LUKS)
       e. Set up LUKS2 encryption (you enter the passphrase here)
       f. Create an LVM volume group inside the LUKS container
       g. Create swap and root logical volumes sized to your RAM
       h. Format and mount everything under /mnt/gentoo
       i. Download and verify the stage3 tarball (SHA256 + GPG signature)
       j. Extract the stage3, copy the chroot script, then remove the tarball
          and its .sha256 and .asc verification files
       k. Bind-mount /proc, /sys, /dev, /run
       l. chroot into the new system and run the chroot script automatically

  PHASE 2 — Chroot Setup (runs automatically inside chroot)
  ----------------------------------------------------------
  The chroot script runs without further interaction until it prompts for:
    - A username to create
    - A hostname
    - A password for that user

  What it does automatically:
    a. Syncs the Portage tree (emerge-webrsync + emerge --sync)
    b. Sets the Portage profile for the target architecture:
         Both:    default/linux/{arch}/23.0/hardened/selinux/systemd
    c. Detects the GPU via sysfs (/sys/bus/pci/devices/ vendor and class
         files — no pciutils package required in the stage3) and sets
         VIDEO_CARDS accordingly
    d. Sets MAKEOPTS to use all available cores (nproc). A -l$(nproc) load
         average guard in make.conf prevents spawning new jobs when the system
         is already saturated. Swap is activated before @world so OOM during
         LLVM is avoided without artificially throttling the job count.
    e. Activates swap before @world so compilation of large packages (LLVM,
         Firefox) does not OOM even on machines with limited RAM. On LUKS
         installs the LVM swap LV is activated; on noluks installs a swap
         file is created and activated.
    f. Writes make.conf (includes the 'selinux' USE flag, MAKEOPTS, and
         FEATURES="-selinux" to prevent portage context errors in the chroot
         where /sys/fs/selinux is not mounted). gentoo-selinux.sh removes the
         FEATURES flag and runs restorecon when SELinux is fully set up.
    g. Sets timezone (America/New_York) and locale (en_US.UTF-8)
    h. Detects the stage3's active Python 3.x version and writes
         PYTHON_SINGLE_TARGET and PYTHON_TARGETS into make.conf to prevent
         slot conflicts, then upgrades portage, libselinux, and
         policycoreutils together as a oneshot before @world.
    i. Builds @world with --backtrack=30
    j. Installs all system packages
    k. Builds the kernel using make defconfig, merge_config.sh (in a subshell
         from the kernel source directory), make olddefconfig, then genkernel.
         See section 6c for the full config fragment details.
    l. Prompts for the target disk to retrieve UUIDs
    m. Writes /etc/fstab
    n. Writes /etc/default/grub with LUKS and SELinux kernel parameters:
         security=selinux selinux=1 lsm=landlock,lockdown,yama,selinux,bpf
    o. Writes /etc/crypttab (LUKS variants only)
    p. Installs and configures GRUB
    q. Configures NetworkManager with iwd as Wi-Fi backend
    r. Enables NetworkManager, sshd, iwd, auditd, systemd-timesyncd
       Desktop also: sddm
       LUKS variants also: lvm2-monitor
    s. Creates the user account and maps it to the staff_u SELinux role
    t. Sets the user password
    u. Locks the root account
    v. Touches /.autorelabel to trigger SELinux filesystem relabeling on first boot
    w. Removes the chroot script from the installed system

  PHASE 3 — First Boot
  ---------------------
  After the chroot completes, the install script exits and the cleanup
  trap unmounts everything automatically. Remove the USB and reboot.

  On first boot, systemd detects /.autorelabel and runs restorecon -R /
  to apply correct SELinux file contexts to the entire filesystem before
  completing the boot. This relabeling pass happens once and may take a few
  minutes on slower hardware.

  PHASE 4 — Post-Install Hardening (after first boot)
  -----------------------------------------------------
  Log in, then run the post-install master script as root:

    sudo bash /path/to/scripts/x86_64/gentoo-postinstall.sh      (desktop)
    sudo bash /path/to/scripts/x86_64/gentoo-postinstall-cli.sh  (CLI)

  The script displays a numbered list of all tasks and asks which to run:
    - Press Enter (or type "all") to run everything
    - Enter ranges or lists: "1-5", "1-3,5,7-9", "12,15,20-23"

  Failed tasks are collected and reported at the end — the script does not
  abort on a single failure, so all selected tasks run regardless.

  All post-install scripts are safe to re-run (idempotent). emerge calls skip
  already-installed packages. rkhunter and AIDE will re-baseline on re-run,
  which is the desired behavior after adding new packages.

  PHASE 5 — Secure Boot Enrollment
  ----------------------------------
  After the post-install script completes, Secure Boot can be enrolled.
  The gentoo-secureboot.sh script (run as part of post-install) will have
  already created and enrolled the sbctl keys if the firmware was in Setup
  Mode. If not, you need to:

    1. Enter firmware setup and enable Setup Mode (clear existing keys)
    2. Reboot back into Gentoo
    3. Run: sudo bash gentoo-secureboot.sh
    4. Re-enter firmware setup and enable Secure Boot
    5. Boot again with Secure Boot active

  PHASE 6 — TPM2 Auto-Unlock (optional, LUKS installs only, run manually)
  ------------------------------------------------------------------------
  gentoo-tpm.sh is intentionally excluded from the post-install scripts.
  It only applies to LUKS-encrypted installs; it exits immediately with an
  explanation on noluks installs. It MUST be run only after:
    1. Secure Boot has been enrolled and is currently active
    2. The system is booted with Secure Boot enabled

  This is because TPM2 auto-unlock binds to PCR 7 (Secure Boot state).
  If you enroll the TPM token before Secure Boot is active, the PCR 7
  value at enrollment time will not match the value at boot time, and
  the TPM will refuse to release the key.

    sudo bash /path/to/scripts/x86_64/gentoo-tpm.sh

================================================================================
  5. SCRIPT REFERENCE
================================================================================

  5a. INSTALLATION SCRIPTS
  -------------------------

  gentoo-install.sh
    LUKS-encrypted desktop installer. Partitions the disk (1 GiB EFI + LUKS2
    container), sets up LVM inside LUKS, downloads and verifies the stage3
    (SHA256 + GPG), extracts it, removes the tarball and its .sha256/.asc
    files, and calls gentoo-chroot.sh. Tries the SELinux-hardened stage3
    first, falls back automatically. Run from the live environment.

  gentoo-install-noluks.sh
    Unencrypted desktop installer. Same structure as gentoo-install.sh but
    skips LUKS2/LVM: the second partition is formatted directly as ext4 and a
    swap file is created inside the filesystem. Calls gentoo-chroot-noluks.sh.

  gentoo-install-cli.sh
    LUKS-encrypted CLI-only installer. Same structure as gentoo-install.sh but
    calls gentoo-chroot-cli.sh. Results in a headless installation.

  gentoo-install-noluks-cli.sh
    Unencrypted CLI-only installer. Combines the noluks disk layout with the
    CLI chroot setup. Calls gentoo-chroot-noluks-cli.sh.

  5b. CHROOT SETUP SCRIPTS
  -------------------------

  gentoo-chroot.sh
    LUKS desktop chroot. Runs inside the new installation after LUKS/LVM is
    set up. Handles Portage sync through GRUB installation. Not called directly
    — invoked by gentoo-install.sh. Installs XFCE, SDDM, NetworkManager,
    PipeWire, and the full set of XFCE extras (power manager, notifications,
    screensaver, screenshooter, task manager, Thunar archive plugin, Thunar
    volume manager, nm-applet, xdg-user-dirs). Uses the hardened/selinux/systemd
    profile. Writes GRUB cmdline with crypt_root= and dolvm for LUKS unlock.

    sys-auth/rtkit is installed alongside PipeWire/WirePlumber so they can
    request realtime scheduling priority via D-Bus (org.freedesktop.
    RealtimeKit1) from first boot — without it, audio can glitch/xrun under
    load. D-Bus activated on demand; no service to enable, no config to
    write.

    GPU detection reads vendor and class IDs directly from
    /sys/bus/pci/devices/*/vendor and .../class (bind-mounted from the host
    into the chroot), so no pciutils package is needed at detection time.
    PCI class 0x0300xx=VGA, 0x0302xx=3D, 0x0380xx=Display controller.

    GPU detection logic (desktop variants):
      AMD/ATI  → vendor 0x1002 → VIDEO_CARDS="amdgpu radeonsi",
                 installs xf86-video-amdgpu
      NVIDIA   → vendor 0x10de → Proprietary driver (x86_64 only).
                 Device IDs are also read from sysfs to identify Pascal-
                 generation legacy cards (GTX 10xx / GP102-GP108) and mask
                 driver versions >= 590 for them. Modern cards get the current
                 driver. On non-x86_64 architectures, falls back to nouveau.
      Fallback → VIDEO_CARDS="modesetting"

    MAKEOPTS calculation:
      USER_MAKEOPTS=$(nproc) — uses all available cores.
      The -l$(nproc) load average guard in make.conf prevents spawning new
      jobs when the system is already saturated. If LLVM OOMs on a low-RAM
      machine, add a swap file and run emerge --resume.

    Swap activation before @world:
      The LVM swap logical volume (LUKS) or swap file (noluks) is activated
      before @world runs. This gives the compiler enough virtual memory even
      on machines where physical RAM alone would be insufficient for LLVM.

  gentoo-chroot-noluks.sh
    Unencrypted desktop chroot. Same as gentoo-chroot.sh but writes a plain
    root=UUID= GRUB cmdline (no crypt_root=/dolvm), creates a swap file before
    @world (sized to RAM), activates it during the build, and mounts root
    directly from the ext4 partition.

  gentoo-chroot-cli.sh
    LUKS CLI chroot. Same as gentoo-chroot.sh but installs no desktop
    environment, display server, audio, or fonts. NVIDIA driver is still
    installed (for GPU compute). On non-x86_64, NVIDIA falls back to nouveau.

  gentoo-chroot-noluks-cli.sh
    Unencrypted CLI chroot. Combines the noluks disk layout with the CLI
    package set (no desktop, display server, audio, or fonts).

  5c. POST-INSTALL MASTER SCRIPTS
  ---------------------------------

  gentoo-postinstall.sh
    Runs post-install tasks for a desktop system. Displays a numbered list
    of all tasks and accepts a selection: Enter/all to run everything, or
    a range/list such as "1-5" or "1-3,5,7-9". Each task runs in a subshell;
    failures are caught and reported at the end without aborting the run.

    Task order (37 tasks for x86_64, 36 for other arches):
      1-8   Hardening: ufw, sysctl, fstab, ssh, sudo, pam, fail2ban, audit
      9-11  Security daemons: clamav, logrotate, autoupdate
      12-14 Tools: compilers, secureboot, parted
      15-28 Desktop apps: gparted, gufw, clamtk, firefox, featherpad,
              cairo-dock, xfburn, gimp, libreoffice, signal, protonpass,
              wine, winetricks, steam (x86_64 only)
      29-32 CLI tools: claude, pentest, fastfetch, funtools
      33-35 Config: selinux, mask-sleep, no-powersave
      36-37 Integrity baselines: rkhunter, aide  (MUST be last — both
              snapshot the filesystem; anything installed after them will
              generate false positives)

    On LUKS installs, prints a reminder to run gentoo-tpm.sh manually after
    Secure Boot is active.

  gentoo-postinstall-cli.sh
    Same structure as gentoo-postinstall.sh but runs only the tasks that
    apply to a headless CLI system (no GUI tools, no desktop applications).

    Task order (23 tasks, all arches):
      1-8   Hardening: ufw, sysctl, fstab, ssh, sudo, pam, fail2ban, audit
      9-11  Security daemons: clamav, logrotate, autoupdate
      12-14 Tools: compilers, secureboot, parted
      15-18 CLI tools: claude, pentest, fastfetch, funtools
      19-21 Config: selinux, mask-sleep, no-powersave
      22-23 Integrity baselines: rkhunter, aide

  5d. POST-INSTALL TASK SCRIPTS (SECURITY & SYSTEM)
  ---------------------------------------------------

  gentoo-ufw.sh
    Installs and configures UFW (Uncomplicated Firewall). Default policy is
    deny incoming and deny outgoing, with an explicit allowlist. Enables UFW
    with logging. UFW is used as fail2ban's ban action.

    iptables backend: Modern Gentoo ships iptables with the nftables backend
    (iptables-nft). The script sets the nftables USE flag on net-firewall/iptables
    before emerging, then runs `eselect iptables set xtables-nft-multi` to
    switch all iptables symlinks to the nft backend. The kernel must have
    CONFIG_NF_TABLES=m and CONFIG_NFT_COMPAT=m built (the chroot scripts ensure
    this). The legacy ip_tables.ko module no longer exists in kernel 6.x.

    Modules loaded at boot: nf_tables, nft_compat, nf_conntrack, and x_tables
    are written to /etc/modules-load.d/netfilter.conf so they are loaded by
    systemd-modules-load.service before ufw.service starts. nft_compat is
    required for iptables-nft to create chains; nf_conntrack is required for
    the conntrack xtables match extension used in UFW's default rules.

    ICMP outgoing: UFW's CLI does not support ICMP rules in this version.
    ICMP output rules are injected directly into /etc/ufw/before.rules:
      destination-unreachable, time-exceeded, parameter-problem, echo-request

    Outgoing ports opened:
      22/tcp   — SSH
      53       — DNS (UDP+TCP)
      67/68    — DHCP
      80/tcp   — HTTP
      123/udp  — NTP
      443/tcp  — HTTPS
      873/tcp  — rsync (Portage sync)
      6514/tcp — Syslog TLS

    If the running kernel lacks netfilter support, UFW is installed but not
    activated. The script exits 0 with a warning, and can be re-run after a
    kernel rebuild.

  gentoo-sysctl.sh
    Writes hardened kernel parameter settings to /etc/sysctl.d/99-hardening.conf.
    Covers: network stack hardening (SYN cookies, ICMP filtering, source routing
    disabled, TCP timestamps disabled, SACK enabled), memory protections (ASLR,
    exec shield, dmesg restrict, kptr restrict), filesystem hardening (symlink
    and hardlink restrictions), and core dump restrictions.

  gentoo-fstab.sh
    Audits and hardens /etc/fstab mount options. Adds nodev, nosuid, noexec
    to /tmp, /dev/shm, and /run. Adds hidepid=2 to /proc to prevent users
    from seeing other users' processes. Verifies that tmpfs is actually mounted
    at /tmp with noexec.

  gentoo-ssh.sh
    Hardens the OpenSSH server configuration. Removes weak host key types
    (DSA, ECDSA) and regenerates only Ed25519 and RSA-4096 host keys. Filters
    /etc/ssh/moduli to remove groups smaller than 3072 bits. Configures:
      - Protocol 2 only
      - Ed25519 and RSA-4096 host keys only
      - PasswordAuthentication yes (intentional — fail2ban handles brute force)
      - Root login disabled
      - X11 forwarding disabled
      - MaxAuthTries 3
      - LoginGraceTime 30s
      - AllowTcpForwarding no (can be re-enabled if needed for tunneling)
    Restricts SSH access to users in the 'ssh' group and creates that group.

  gentoo-sudo.sh
    Hardens the sudo configuration. On Gentoo, the default /etc/sudoers does
    not include /etc/sudoers.d, so this script injects the #includedir line
    if it is missing. Validates the sudoers file with visudo -c before and
    after each change. Writes a hardened drop-in to /etc/sudoers.d/hardening:
      - env_reset, secure_path
      - requiretty, use_pty (prevents privilege escalation via background jobs)
      - timestamp_timeout=0 (no credential caching — re-authenticate every time)
      - passwd_tries=1 (one wrong password and sudo exits)
      - Full I/O logging: /var/log/sudo.log and /var/log/sudo-io/

  gentoo-pam.sh
    Hardens PAM authentication by patching /etc/pam.d/system-auth. Rather than
    replacing the file entirely (which would strip Gentoo-specific modules from
    the stage3 install), the script patches the existing file using Python to
    insert only what is missing. A backup is always written to system-auth.bak
    before any changes. Recovery: cp /etc/pam.d/system-auth.bak /etc/pam.d/system-auth

    What is added (idempotent — skipped if already present):
      auth stack:    pam_faillock preauth before pam_unix;
                     pam_faillock authfail / authsucc after pam_unix
      account stack: pam_faillock before pam_unix
      password stack: pam_pwquality before pam_unix (if libpwquality installed)
      session stack:  pam_limits, pam_selinux close/open, pam_systemd
                      (each added only if not already in the file)

    Also configures:
      pam_faillock (/etc/security/faillock.conf): locks after 5 failures in
        10 minutes; auto-unlocks after 15 minutes; even_deny_root enabled
      pam_pwquality (/etc/security/pwquality.conf): minimum 14 characters;
        requires uppercase, lowercase, digit, symbol; rejects dictionary words
      pam_limits (/etc/security/limits.d/99-hardening.conf): core dumps
        disabled, nproc capped at 10000/5000, nofile=65536
    Creates /etc/security/opasswd for password history if it does not exist.

    To unlock a locked account: faillock --user <username> --reset
    To check failure counts:    faillock --user <username>

  gentoo-fail2ban.sh
    Installs fail2ban compiled with systemd journal support (USE="systemd").
    Configures a jail for SSH using the systemd journal as the log backend.
    Ban action is set to ufw, so bans are enforced at the firewall level
    rather than iptables directly. Ban parameters: 5 failures in 10 minutes
    triggers a 1-hour ban.

  gentoo-audit.sh
    Installs auditd and writes audit rules to /etc/audit/rules.d/hardening.rules.
    Rules cover: file permission changes, user/group modifications, login
    events, sudo usage, kernel module loads/unloads, network configuration
    changes, and time changes. Enables and starts the auditd service.

  gentoo-tmp-cleanup.sh
    Creates /usr/local/sbin/tmp-cleanup.sh (removes files older than 2 days
    from /tmp and /var/tmp) and a systemd service + timer to run it daily at
    04:30. Pure housekeeping — no coupling to anything else, so it's fully
    independent.

  gentoo-clamav.sh
    Installs ClamAV antivirus. Configures clamd and freshclam. Runs an initial
    signature database update with freshclam. Detects the ClamAV service name
    dynamically (clamav-clamd.service or clamd.service depending on the
    installed version). Enables the detected service.

    Also creates /usr/local/sbin/clamav-scan.sh (forces a fresh freshclam
    update, then a full scan of /etc /home /root /tmp /var/tmp /opt /srv
    /boot) and a systemd service + timer to run it daily at 03:00. An
    infection found shows up as a failed systemd unit (systemctl --failed /
    journalctl -u clamav-scan.service), not just a line in a log file.

  gentoo-rkhunter.sh
    Installs rkhunter (rootkit hunter). Performs an initial system scan and
    runs --propupd to build the baseline property database. Must run after
    all other packages are installed (last two tasks in the postinstall order)
    to avoid false positives from newly installed files.

    Also creates two independent pieces:
      - rkhunter-scan.sh + service + timer (daily 03:30): signature update
        (rkhunter --update) + scan (rkhunter --check --sk). A warning shows
        up as a failed systemd unit.
      - rkhunter-propupd.sh + service, no timer: refreshes the file-properties
        baseline (rkhunter --propupd). Only ever triggered directly by
        autoupdate.sh right after @world — an independent schedule would
        report every updated binary as a false positive until the next
        refresh ran.

  gentoo-aide.sh
    Installs AIDE (Advanced Intrusion Detection Environment) for file integrity
    monitoring. Writes a configuration covering critical system paths (/bin,
    /sbin, /usr/bin, /usr/sbin, /lib, /etc, /boot). Initializes the AIDE
    database with aide --init. Must run last in the postinstall order for
    the same reason as rkhunter.

    Also creates two independent pieces, mirroring rkhunter's split:
      - aide-check.sh + service + timer (daily 04:00): aide --check only.
        A non-clean run shows up as a failed systemd unit.
      - aide-update.sh + service, no timer: refreshes the baseline (aide
        --update, then swaps aide.db.new into aide.db). Only ever triggered
        directly by autoupdate.sh right after @world, for the same false-
        positive reason as rkhunter-propupd.

  gentoo-logrotate.sh
    Configures log rotation for all major services:
      - /var/log/auth.log, syslog, kern.log: daily, 30 days retention
      - /var/log/audit/audit.log: weekly, 12 weeks, sends USR1 to auditd
      - /var/log/sudo.log: daily, 90 days
      - /var/log/fail2ban.log: weekly, 8 weeks
      - /var/log/clamav/*.log: weekly, 8 weeks
      - /var/log/pending-configs-discarded.log: monthly, 12 months

  gentoo-autoupdate.sh
    Creates /usr/local/sbin/autoupdate.sh and installs a systemd service and
    timer to run it weekly on Saturday at 05:00 (persistent — catches up if
    the system was off at the scheduled time).

    ClamAV, rkhunter, and AIDE scans do NOT run from this script — each has
    its own independent daily timer (gentoo-clamav.sh, gentoo-rkhunter.sh,
    gentoo-aide.sh, all above). This script's job is purely the package
    update mechanics, plus triggering the two baseline-refresh steps that
    must happen right after @world:

    The autoupdate script performs in this order:
      1. LVM snapshot          — creates a pre-update snapshot of the root LV
                                  (skipped silently on noluks installs)
      2. Disk space check      — aborts if less than 5 GiB free on / or /var/tmp
      3. emaint -a sync        — sync all Portage overlays
      4. emerge --oneshot sys-apps/portage — update Portage itself first
      5. emerge -vuDNU @world  — update all packages (aborts here on failure)
      6. emerge --depclean     — remove orphaned packages
      7. emerge @preserved-rebuild — rebuild packages against updated libraries
      8. revdep-rebuild        — fix any broken library linkage
      9. emerge @module-rebuild — rebuild kernel modules for the running kernel
     10. Discard pending configs — detects ._cfg* files under /etc, logs them to
                                  /var/log/pending-configs-discarded.log, then
                                  deletes them directly with `find -delete`.
                                  Does NOT call etc-update --automode — every
                                  automode has an interactive assumption baked
                                  in (-5 blindly overwrites everything despite
                                  the name; -7's discard path still shells out
                                  to `rm -i` by default). A plain delete only
                                  ever removes the proposed NEW file sitting
                                  alongside the live one — it can never touch
                                  or overwrite the running config, so current
                                  configs are never changed by this step,
                                  merged or otherwise. The discard log lets a
                                  silently-dropped upstream config change
                                  still be traced later if something needs
                                  troubleshooting.
     11. Trigger rkhunter-propupd.service and aide-update.service (systemctl
         start --wait) — skipped with a warning if either isn't installed
     12. systemd reload        — daemon-reexec if systemd itself was updated,
                                  daemon-reload otherwise
     13. Kernel rebuild        — if new source is available, rebuilds with genkernel;
                                  uses --luks --lvm on LUKS installs (detected via
                                  /etc/crypttab), plain genkernel all on noluks
     14. Kernel version check  — if a new kernel is installed and the running
                                  kernel differs from the latest in /lib/modules,
                                  schedule a reboot in 1 minute
     15. Remove LVM snapshot   — removes the pre-update snapshot on success

  gentoo-compilers.sh
    Installs a comprehensive set of compilers, language runtimes, and build
    tools. Packages installed:
      Compilers:      gcc (with gfortran), clang/clang++, nasm, yasm
      LLVM toolchain: llvm, lld
      Languages:      Go, Rust/Cargo (rust-bin), Java (OpenJDK), Node.js/npm
      Build systems:  cmake, meson, ninja, autoconf, automake, libtool
      Dev tools:      gdb, valgrind, dev-debug/strace, ccache, patchelf,
                      pkg-config, git
    Note: the strace package is dev-debug/strace (not dev-util/strace) in
    current Gentoo portage. Arch-specific: OpenJDK warns and skips on 32-bit
    ARM; valgrind and rust-bin fall back gracefully if unavailable.

  gentoo-secureboot.sh
    Installs sbctl and sets up Secure Boot key enrollment. Checks that the
    firmware is in Setup Mode before proceeding (if not, it skips and exits
    cleanly). Creates a custom Platform Key and Key Exchange Key with sbctl,
    enrolls them into the firmware alongside Microsoft's certificates (-m flag
    for compatibility with dual-boot or firmware updates). Signs the GRUB EFI
    binary and the fallback EFI binary. Also signs any kernel EFI stubs in
    /boot. Architecture-specific EFI binary names:
      x86_64  → grubx64.efi / BOOTX64.EFI
      x86     → grubia32.efi / BOOTIA32.EFI
      arm64   → grubaa64.efi / BOOTAA64.EFI
      arm     → grubarm.efi / BOOTARM.EFI

  gentoo-parted.sh
    Installs sys-block/parted, the command-line disk partitioning tool.
    Included in both the desktop and CLI post-install sets.

  gentoo-sshfs.sh
    Installs sshfs (net-fs/sshfs) — mounts remote filesystems over SSH via
    FUSE. Requires CONFIG_FUSE_FS=m in the kernel (included in the fragment).
    Usage: sshfs user@host:/remote/path /local/mountpoint
    Unmount: fusermount -u /local/mountpoint

  gentoo-mask-sleep.sh
    Masks all systemd sleep and hibernate targets so the system never suspends
    or hibernates automatically or on user request. Also writes
    /etc/systemd/logind.conf.d/no-sleep.conf to configure logind to ignore
    the suspend key, hibernate key, and lid-switch events.

    Targets masked: sleep.target, suspend.target, hibernate.target,
    hybrid-sleep.target, suspend-then-hibernate.target

  gentoo-no-powersave.sh
    Disables all power-saving features system-wide. Covers:
      Audio:   /etc/modprobe.d/audio-powersave.conf — snd_hda_intel and
               snd_ac97_codec power_save=0
      USB:     udev rule — autosuspend disabled for all USB devices
      PCI:     udev rule — power/control set to "on" for all PCI devices
      SATA:    udev rule — SATA link power management set to "max_performance"
      NVMe:    udev rule — NVMe APST (Autonomous Power State Transitions)
               disabled
      CPU:     systemd service — sets the CPU frequency governor to
               "performance" on all cores at boot
      WiFi:    NetworkManager dispatcher script — disables power management
               on all wireless interfaces when they connect
      Kernel:  GRUB_CMDLINE_LINUX additions — usbcore.autosuspend=-1 and
               pcie_aspm=off

    After running this script, update-grub is called automatically to apply
    the kernel parameter changes.

  5e. POST-INSTALL TASK SCRIPTS (DESKTOP APPLICATIONS)
  ------------------------------------------------------
  These scripts are only in gentoo-postinstall.sh, not the CLI variant.

  gentoo-gparted.sh
    Installs GParted, the graphical disk partitioning tool (GNOME Partition
    Editor). Requires a running X session to use.

  gentoo-gufw.sh
    Installs the graphical UFW frontend. Launches with pkexec for privilege
    elevation (PolicyKit-based, no gksudo/gksu dependency).

  gentoo-clamtk.sh
    Installs ClamTk, the graphical ClamAV frontend for on-demand scanning
    and configuration.

  gentoo-firefox.sh
    Installs Firefox built from source (www-client/firefox ~<arch>). This
    is a source build — it will take a significant amount of time, especially
    on slower machines or with limited CPU cores.

  gentoo-featherpad.sh
    Installs FeatherPad, a lightweight Qt5 plain-text editor.

  gentoo-cairo-dock.sh
    Installs Cairo-Dock, a compositing dock/taskbar for the XFCE desktop.

  gentoo-mediatools.sh
    Installs HandBrake (GUI, GStreamer) and MakeMKV (GUI) for disc
    ripping/transcoding. Both need ~arm64 accept_keywords (only amd64 is
    stable upstream for either). MakeMKV also needs accepting the
    MakeMKV-EULA license; its source tarballs are fetched manually over
    HTTPS since upstream's http:// URL returns a Cloudflare 403. Not
    available on plain arm -- HandBrake has no keyword for it at all,
    stable or unstable.

  gentoo-xfburn.sh
    Installs Xfburn, the XFCE disc burning application.

  gentoo-gimp.sh
    Installs GIMP. Writes /etc/portage/package.use/gimp before emerging to
    satisfy required USE flags: app-text/poppler cairo, media-libs/babl lcms,
    media-libs/gegl lcms cairo.

  gentoo-libreoffice.sh
    Installs LibreOffice from source (~<arch>). Writes package.use/libreoffice:
    sys-libs/zlib minizip, dev-libs/xmlsec nss, media-libs/harfbuzz icu.
    Source build — takes a long time.

  gentoo-signal.sh
    x86_64, arm64: Installs Signal Desktop via the GURU community overlay.
      - Adds GURU overlay only if /var/db/repos/guru does not already exist
        (idempotent — safe to re-run even if the overlay is already enabled)
      - Accepts ~<arch> keyword for net-im/signal-desktop-bin
    x86, arm: Prints a message and exits cleanly (Electron unavailable for
      32-bit architectures).

  gentoo-protonpass.sh
    Installs Proton Pass password manager via Flatpak from Flathub.

  gentoo-wine.sh
    Installs Wine (app-emulation/wine-vanilla). Writes package.use/wine with
    USE flags including media-libs/libsdl2 gles2 (required by REQUIRED_USE
    wayland? ( gles2 ) constraint).

  gentoo-winetricks.sh
    Installs Winetricks. Checks for a working Wine installation by looking for
    either the wine or wine64 binary (Gentoo x86_64 may install either name).

  gentoo-steam.sh  (x86_64 only, included in gentoo-postinstall.sh)
    Installs Steam via Portage (games-util/steam). Verifies multilib is
    configured, accepts the Steam proprietary license, sets abi_x86_32.
    Opens UFW outgoing ports required for Steam multiplayer and the Steam
    client: 27015-27036/tcp+udp, 3478/udp (SDR/STUN), 4380/udp (SDR).

  gentoo-claude.sh
    Installs Claude Code (Anthropic's AI-powered CLI). Installs Node.js via
    Portage if not already present, then installs @anthropic-ai/claude-code
    globally via npm. Configures maxTokens: 200000 for root and all future
    users via /etc/skel/.claude/settings.json.

  5f. STANDALONE & UTILITY SCRIPTS
  ----------------------------------

  gentoo-tpm.sh
    Enrolls a TPM2 token for automatic LUKS passphrase release at boot.
    Exits immediately on noluks installs. Must be run manually after:
      1. gentoo-secureboot.sh has run and keys are enrolled
      2. The system has rebooted with Secure Boot enabled
      3. The firmware is NOT in Setup Mode

    PCR binding: PCR 0 (firmware code) + PCR 7 (Secure Boot state). Survives
    kernel updates; breaks on firmware updates or key changes. Always keep
    the LUKS passphrase as a fallback.

  kernel-rebuild.sh  (in each arch directory)
    Rebuilds the kernel inside a running chroot. Can be called by
    gentoo-live-chroot.sh or run directly on the installed system:
      sudo bash /path/to/scripts/x86_64/kernel-rebuild.sh [luks|noluks]

    Writes the full kernel config fragment, runs defconfig → merge_config.sh
    (in a subshell from the kernel source directory) → olddefconfig → cp →
    genkernel. After genkernel completes, syncs any modules in the updates/
    directory to the newly built versions and runs depmod -a. The updates/
    directory takes priority over kernel/ in depmod's search order; without
    this sync, stale pre-rebuild modules in updates/ would shadow new builds.

  gentoo-live-chroot.sh  (in each arch directory, run from the live USB)
    Helper for mounting a target Gentoo installation from a live environment
    and entering a rescue chroot.

    What it does:
      1. Asks whether the install is LUKS-encrypted or plain
      2. Shows lsblk output and prompts for the target disk
      3. Opens the LUKS container and activates LVM (LUKS path), or mounts
         the partition directly (noluks path)
      4. Mounts the root filesystem and EFI partition
      5. Bind-mounts /proc, /sys, /dev, /dev/pts, /run into the chroot
      6. Sets up a trap to unmount everything cleanly on exit
      7. Presents a menu: (1) kernel rebuild, (2) rescue shell

    Usage:
      sudo bash /path/to/scripts/x86_64/gentoo-live-chroot.sh

  gentoo-rpi4-firmware.sh  (arm64 only — not present in other arch directories)
    Installs the pftf/RPi4 UEFI firmware (RPI_EFI.fd) plus the matching
    Broadcom boot files (start4.elf, fixup4.dat, config.txt, device-tree
    overlays, Wi-Fi/BT blobs) onto an existing FAT32 partition. Required
    because the Pi 4 has no native UEFI — GRUB's arm64-efi target needs
    RPI_EFI.fd acting as the boot ROM's "armstub" before it can run.

    Fetches the latest release from the pftf/RPi4 GitHub API automatically
    (currently a single self-contained zip; no separate download of Pi boot
    files is needed). Backs up any existing config.txt to config.txt.bak
    before overwriting. Leaves GRUB's own EFI/ directory untouched — pftf's
    files live at the partition root, GRUB's do not, so both coexist on the
    same ESP that gentoo-install-*.sh already created.

    Run it:
      - Post-install, against the ESP the installer created (e.g. /dev/sda1
        or /dev/mmcblk0p1), so the Pi can boot the installed system directly.
      - Against a separate live-boot USB/SD card you've pre-formatted with one
        FAT32 partition, to give that medium a UEFI environment to boot into
        before you even start the Gentoo install (see section 7, arm64 notes).

    Usage:
      sudo bash /path/to/scripts/arm64/gentoo-rpi4-firmware.sh

  gentoo-selinux.sh  (desktop and CLI postinstall)
    SELinux post-install configuration. Run near the end of both the desktop
    and CLI post-install task lists so the initial AVC scan captures denials
    from all earlier tasks.
      - Verifies the running kernel has CONFIG_SECURITY_SELINUX=y
      - Installs SELinux userspace tools and policy modules
      - Runs restorecon -R / to apply current file contexts
      - Writes /etc/selinux/config with SELINUX=permissive initially
      - Scans AVC denials via ausearch, generates a gentoo-local policy
        module via audit2allow, and installs it with semodule
      - Switches to enforcing mode (setenforce 1) as the final step

  gentoo-fastfetch.sh  (desktop and CLI postinstall)
    Installs Fastfetch, a system information tool.

  gentoo-funtools.sh  (desktop and CLI postinstall)
    Installs fun/novelty terminal tools (cowsay, fortune, lolcat, figlet,
    cmatrix, hollywood). Some require additional overlays — noted and skipped
    if unavailable.

  gentoo-pentest.sh  (desktop and CLI postinstall)
    Installs penetration testing and security analysis tools available in
    the main Gentoo portage tree (including nmap). Tools requiring additional
    overlays (e.g. Metasploit via Pentoo) are noted but not installed
    automatically. No UFW rules are opened — pentest tools require manual
    firewall configuration for each engagement.

  gentoo-window-lock-memory.sh  (desktop postinstall, XFCE only)
    Installs a per-user systemd --user service that saves each window's
    position (and maximized state) when the screen locks and restores it
    on unlock. Works around an AMDGPU/Xorg DDX DPMS bug
    (drmmode_do_crtc_dpms cannot get last vblank counter, visible in
    Xorg.0.log around a lock/wake cycle) that can reflow windows onto a
    single monitor when the screens wake -- no real monitor disconnect
    occurs (nothing shows in `journalctl -k` for DRM hotplug), so this is
    purely a display-server/WM-level glitch, not a hardware issue.
      - Installs x11-misc/xdotool and x11-misc/wmctrl
      - Writes ~/bin/window-monitor-memory.sh (save/restore logic) and
        ~/bin/window-lock-watcher.sh (dbus listener for xfce4-screensaver's
        org.xfce.ScreenSaver ActiveChanged signal) for the primary user
        (UID 1000)
      - Writes ~/.config/systemd/user/window-lock-watcher.service and
        enables it by symlink directly (systemctl --user enable needs a
        live user session/bus, which won't exist during post-install) --
        takes effect at the user's next login, or start it immediately
        with: systemctl --user start window-lock-watcher.service
      - A maximized window's position is locked by the WM (a plain move is
        silently ignored), so restoring one means: unmaximize -> move to
        the saved position -> re-maximize, which snaps it back onto
        whichever monitor it's now positioned on

================================================================================
  6. TECHNICAL DEEP DIVE
================================================================================

  6a. DISK LAYOUT (LUKS2 + LVM)
  -------------------------------
  The installer creates the following partition layout:

    [Disk]
    ├── Partition 1: EFI System Partition (1 GiB, FAT32)
    │     Mounted at /boot
    │     Contains GRUB EFI binary and kernel/initrd files
    └── Partition 2: LUKS2 encrypted container
          └── LVM Physical Volume
                └── Volume Group: vg0
                      ├── Logical Volume: swap (sized to RAM)
                      └── Logical Volume: root (remainder, ext4)

  LUKS2 is used (not LUKS1) for its improved key derivation (Argon2id by
  default), which significantly increases resistance to offline brute-force
  attacks. The container is opened with a passphrase at every boot unless
  TPM auto-unlock is configured.

  The crypttab entry is named "root" because genkernel's crypt_root= kernel
  parameter maps the device as /dev/mapper/root. Using the same name in
  crypttab prevents systemd from attempting a second unlock of an already-open
  device during boot.

  Swap is inside the LUKS container and therefore encrypted. The swap LV is
  also activated inside the chroot during @world compilation to prevent OOM
  kills on low-RAM machines.

  6b. SELINUX INTEGRATION (ALL VARIANTS)
  ----------------------------------------
  SELinux is the MAC layer for both desktop and CLI variants.

  Stage3 and profile:
    Both install scripts attempt to fetch the hardened-selinux-systemd stage3
    first, which ships with SELinux-aware libraries pre-built. If unavailable,
    the installer falls back automatically.

    The chroot script selects the hardened/selinux/systemd Portage profile:
      default/linux/{arch}/23.0/hardened/selinux/systemd

  Kernel parameters:
    The following parameters are written to GRUB_CMDLINE_LINUX:
      security=selinux
      selinux=1
      lsm=landlock,lockdown,yama,selinux,bpf

  SELinux user mapping:
    After creating the user account, the chroot scripts run:
      semanage login -a -s staff_u -r s0-s0:c0.c1023 <username>
    Without this mapping, pam_selinux cannot obtain a valid context at login
    and authentication will appear to fail with "A valid context could not be
    obtained."

  First-boot filesystem relabeling:
    The chroot script touches /.autorelabel before exiting. On the first boot,
    systemd runs restorecon -R / to apply correct security contexts to all
    files, then removes /.autorelabel and reboots.

  Initial policy generation:
    When gentoo-selinux.sh runs, it performs a one-time scan of AVC denials
    accumulated since boot and generates a gentoo-local policy module. The
    .te and .pp files are saved to /etc/selinux/local/ for review.

  Subsequent manual policy updates:
      ausearch -m avc -ts recent | audit2why
      sudo /usr/local/sbin/selinux-avc-update

  Operating modes:
    SELinux runs permissive during setup. gentoo-selinux.sh switches it to
    enforcing at the end of the post-install run.

  6c. KERNEL CONFIGURATION
  -------------------------
  The kernel is built using this sequence in every chroot and kernel-rebuild
  script:

    make -C /usr/src/linux defconfig
    (cd /usr/src/linux && scripts/kconfig/merge_config.sh -m .config \
        /tmp/gentoo-extra-kconfig)
    make -C /usr/src/linux olddefconfig
    cp /usr/src/linux/.config /tmp/gentoo-merged-kconfig
    genkernel [--luks --lvm] all --kernel-config=/tmp/gentoo-merged-kconfig

  The merge_config.sh call is run in a subshell from the kernel source
  directory to ensure its output is written to /usr/src/linux/.config. If
  called from any other directory, merge_config.sh writes to ./config in
  that directory, and the merged configuration is silently discarded.

  The config file is staged to /tmp before genkernel because genkernel runs
  make mrproper which deletes .config before copying --kernel-config into place.

  Persistent fragment:
    After writing the fragment, scripts save a copy to /etc/kernel/gentoo-extra-kconfig.
    autoupdate.sh reads this file when rebuilding the kernel on source updates,
    so custom config options survive kernel upgrades automatically. Running
    kernel-rebuild.sh on an installed machine also updates this file.

  Ordering requirements:
    - CONFIG_NF_TABLES and sub-options must precede CONFIG_NETFILTER_XTABLES
    - CONFIG_NETFILTER_ADVANCED=y must precede all XT_MATCH_* options
      (make olddefconfig silently drops them without it)
    - NF_TABLES_IPV4/IPV6/INET are bool — must be =y not =m

  Config fragment sections (/tmp/gentoo-extra-kconfig):

    SELinux + LSM stack (required for lsm= kernel cmdline parameter)
    Netfilter / nftables (UFW) — legacy ip_tables.ko removed in kernel 6.x;
      nf_tables + NFT_COMPAT is the only supported path
    Storage (built-in =y): SATA, NVMe, eMMC/MMC/SD
    LUKS / dm-crypt (built-in =y)
    GPU DRM drivers (modules =m — need /lib/firmware/ after root mount)
    EFI framebuffer
    exFAT
    Touchscreen — I2C-HID, HID_MULTITOUCH, vendor drivers
    Signature pads / graphics tablets — Wacom HID + USB, GTCO, Acecad
    Touchpad — PS/2 drivers, Elan I2C, INPUT_EVDEV
    Audio — ALSA/HDA, all codecs, USB audio, ASoC/SOF
    TPM — TCG_TPM, TIS, CRB, TIS_I2C (required for gentoo-tpm.sh)
    Hardware crypto — AES-NI, GHASH/CLMUL, SHA-SSSE3, CRC32C (speeds up LUKS)
    Bluetooth — BT, HCIBTUSB, RFCOMM, HIDP, LE
    Webcam — MEDIA_SUPPORT, USB_VIDEO_CLASS (UVC)
    IOMMU — INTEL_IOMMU, AMD_IOMMU (DMA protection)
    KVM — KVM, KVM_INTEL/AMD, VHOST_NET
    Virtio — paravirtual drivers for running as a VM guest
    Thunderbolt / USB4
    VPN / KVM networking — TUN, WIREGUARD, VETH, BRIDGE
    AMD P-state — X86_AMD_PSTATE (better than acpi-cpufreq on Ryzen)
    Hardware monitoring — HWMON, K10TEMP, CORETEMP
    Filesystem extras — FUSE, NTFS3, NFS, CIFS
    WiFi — CFG80211/MAC80211 core + Intel/Realtek/Atheros/MediaTek/Broadcom
    Laptop platform drivers — DELL_WMI/LAPTOP, ASUS_WMI, THINKPAD_ACPI, HP_WMI
    Containers — OVERLAY_FS, NAMESPACES, CGROUPS, MEMCG, CGROUP_BPF
    USB serial — FTDI_SIO, CP210X, CH341 (Arduino/microcontrollers)
    Network filesystems — NFS, CIFS/SMB
    Game controllers — XPAD, HID_SONY, HID_NINTENDO
    USB Ethernet adapters — USB_NET_DRIVERS, USB_USBNET
    ACPI power — BATTERY, AC, VIDEO, FAN, THERMAL, BUTTON, PROCESSOR, PLATFORM_PROFILE
    EFI variables — EFIVAR_FS (required by sbctl / Secure Boot tools)
    WMI base driver — ACPI_WMI (required by laptop platform drivers)
    Dell / SuperIO sensors — SENSORS_DELL_SMM, NCT6775, IT87
    RAID — software MD RAID (=y) + hardware controllers (=y): MegaRAID, HP
      Smart Array, Adaptec, MPT3SAS, Intel VMD; all =y so available in initrd
      if root is on a RAID array
    Intel DesignWare I2C + Intel GPIO pinctrl — required for I2C touchpads on
      Intel Atom/Celeron (Apollo Lake, Gemini Lake). Includes PINCTRL_GEMINILAKE
      specifically for Celeron N4000 interrupt routing (Asus E203M, etc.)
    Microsoft Surface tablet — SURFACE_AGGREGATOR bus, HID, button, ITHC
      touchscreen controller (Surface Pro 4 through newer models)
    Asus Prime X399-A (AMD Threadripper) — IGB (Intel I211-AT dual GbE),
      I2C_PIIX4 (AMD SMBus sensors), AMD CCP/PSP (fTPM + hw crypto),
      USB host controllers (XHCI/EHCI), USB_STORAGE, USB_UAS, TYPEC,
      SR-IOV (PCI_IOV), PCIe hotplug, hardware RNG (HW_RANDOM_INTEL)
    Dell PowerEdge T320/T330 — TIGON3 (Broadcom BCM5720 dual GbE),
      IPMI stack (IPMI_HANDLER/SI/SSIF/WATCHDOG — iDRAC fan control),
      EDAC ECC reporting (SB_ECC for T320, SKX for T330),
      PMBus PSU monitoring, Intel TCO watchdog (ITCO_WDT),
      NIC bonding, iDRAC USB virtual NIC (CDC_NCM), serial console

  Applying kernel config changes to an already-installed machine:
    1. sudo bash /path/to/scripts/x86_64/kernel-rebuild.sh [luks|noluks]
    2. Reboot into the new kernel
    3. Re-run any post-install scripts that depend on kernel features (e.g.
       gentoo-ufw.sh after adding netfilter modules)
    If the kernel was rebuilt without kernel-rebuild.sh (e.g. manually), run
    sync-modules.sh to sync the updates/ directory before rebooting.

  6d. SECURE BOOT WITH SBCTL
  ---------------------------
  sbctl (Secure Boot control) manages custom Secure Boot keys entirely from
  within Linux without needing to use the firmware setup menus for key
  management (beyond initial Setup Mode activation).

  The process:
    1. Enter firmware setup, clear existing Secure Boot keys to enter Setup Mode
    2. Boot Gentoo (Setup Mode allows booting unsigned binaries)
    3. sbctl create-keys — generates PK, KEK, and db keys in /var/lib/sbctl/keys/
    4. sbctl enroll-keys -m — enrolls keys alongside Microsoft's certificates
    5. sbctl sign -s <efi> — signs each EFI binary
    6. Re-enable Secure Boot in firmware

  6e. TPM2 AUTO-UNLOCK
  ---------------------
  systemd-cryptenroll binds a new LUKS key slot to the TPM2 chip using PCR
  measurements. PCR 0 measures firmware code; PCR 7 measures Secure Boot state.
  Kernel updates do NOT break the seal. Firmware updates or key changes do.

  The crypttab entry is updated with tpm2-device=auto,tpm2-pcrs=0+7. If TPM
  measurement fails, the system falls back to the LUKS passphrase. Always
  keep the passphrase in a safe place.

  6f. AUTOMATED UPDATES (SYSTEMD TIMERS)
  ---------------------------------------
  Package updates and security scanning are separate systemd timers, not one
  monolithic script. Each does one thing and can be inspected, run, or
  disabled independently (systemctl status/start/disable <name>.timer):

    autoupdate.timer       Sat 05:00   package updates + kernel rebuild
    clamav-scan.timer      daily 03:00 ClamAV definitions + full scan
    rkhunter-scan.timer    daily 03:30 rkhunter signatures + scan
    aide-check.timer       daily 04:00 AIDE integrity check
    tmp-cleanup.timer      daily 04:30 /tmp, /var/tmp housekeeping

  All use Type=oneshot with Persistent=true (catches up a missed run if the
  system was off at the scheduled time). The three scan services deliberately
  do NOT swallow their tool's exit code — a non-clean AIDE/rkhunter/ClamAV
  result leaves the systemd unit in a failed state, so `systemctl --failed`
  or `journalctl -u <name>.service` surfaces it, not just a line buried in a
  log file.

  Two services have no timer of their own and are only ever triggered
  directly by autoupdate.sh (systemctl start --wait), right after @world:

    aide-update.service        aide --update, then swap aide.db.new -> aide.db
    rkhunter-propupd.service   rkhunter --propupd

  Both refresh a baseline against files that @world just legitimately
  changed. If either ran on its own independent schedule instead, the next
  aide-check/rkhunter-scan could run before that day's baseline refresh and
  flag every updated binary as a false positive. autoupdate.sh checks
  [[ -f /etc/systemd/system/<name>.service ]] before triggering either, so
  it degrades gracefully (with a warning, not a failure) on a system where
  gentoo-aide.sh/gentoo-rkhunter.sh haven't been run.

  LUKS detection for kernel rebuilds:
    The script checks /etc/crypttab for non-comment entries to determine whether
    the system uses LUKS. This makes the same autoupdate script work on all four
    install variants without any manual configuration.

  6g. PAM HARDENING STACK
  ------------------------
  The PAM configuration (gentoo-pam.sh) patches /etc/pam.d/system-auth, which
  is the central config included by login, sudo, su, sshd, and most other
  authentication points on Gentoo.

  Rather than replacing the file, the script uses Python to insert hardening
  modules around the existing pam_unix lines. This preserves all Gentoo-specific
  modules from the stage3 install and avoids breaking authentication due to
  missing modules.

  What is inserted (only if not already present):

    auth stack:
      pam_faillock preauth    — check if account is locked before prompting
      [existing pam_unix]
      pam_faillock authfail   — record failure, lock if threshold reached
      pam_faillock authsucc   — clear failure count on success

    account stack:
      pam_faillock            — enforce account lockout state
      [existing pam_unix]

    password stack:
      pam_pwquality retry=3   — enforce complexity before accepting new password
      [existing pam_unix]     — pam_unix gets use_authtok added to avoid
                                 double-prompting when pwquality is inserted

    session stack (each added only if absent):
      pam_limits              — apply resource limits from limits.d/
      pam_selinux close       — release SELinux context at session close
      pam_selinux open nottty — establish SELinux context at session open
      pam_systemd             — register session with systemd-logind

  pam_selinux.so is required on Gentoo+SELinux. Without it, authentication
  succeeds but the session fails to open, presenting as "password doesn't work."

  6h. MULTILIB (x86_64 ONLY)
  ----------------------------
  ABI_X86="64 32" in make.conf instructs Portage to build both 64-bit and
  32-bit variants of packages that support multiple ABIs. This is required
  for Wine to run 32-bit Windows applications and for Steam's 32-bit runtime.

  The amd64 hardened/selinux/systemd profile is multilib-capable. ABI_X86
  is the variable that actually triggers the 32-bit builds. This increases
  build times significantly for initial @world and updates.

================================================================================
  7. ARCHITECTURE-SPECIFIC NOTES
================================================================================

  x86_64
  ------
  - Full NVIDIA proprietary driver support including legacy cards
  - Legacy GPU detection: Pascal generation (GTX 10xx / GP102-GP108) cards
    are masked to driver versions < 590 and marked ~amd64
  - ABI_X86="64 32" enables full 32-bit library support for Wine and Steam
  - All applications available including Signal Desktop
  - Both desktop and CLI installs try amd64-hardened-selinux-systemd stage3
    (desktop fallback: amd64-desktop-systemd; CLI fallback: amd64-systemd)

  x86
  ---
  - NVIDIA proprietary driver dropped 32-bit Linux support; nouveau handles all
    NVIDIA cards on x86
  - Intel GPU detection included (common on older x86 hardware)
  - GRUB compiled for detected boot mode: efi-32 for UEFI, pc for BIOS
  - Signal Desktop not available (Electron is amd64/arm64 only)
  - Wine runs 32-bit Windows apps natively (no multilib needed)
  - Both desktop and CLI installs attempt the i686-hardened-selinux-systemd
    stage3 first

  arm64
  -----
  - GRUB arm64-efi requires UEFI firmware. Raspberry Pi 4/5 needs the pftf/RPi4
    UEFI firmware on the SD card/USB to use GRUB — install it with
    gentoo-rpi4-firmware.sh (see section 5f).
  - NVIDIA consumer desktop driver not available for arm64; nouveau handles PCIe
    NVIDIA cards
  - Signal Desktop available (~arm64) via the GURU overlay
  - Wine on arm64 runs ARM64 Windows binaries natively; pair with box64 for x86
    Windows app support
  - Both desktop and CLI installs attempt the arm64-hardened-selinux-systemd
    stage3 first

  Raspberry Pi 4/400/CM4 — full workflow
    The install scripts check /sys/firmware/efi in the CURRENTLY RUNNING
    environment and refuse to proceed under a non-UEFI boot, so the live
    environment itself must already be UEFI-booted before you run them. Since
    gentoo-install-*.sh repartitions its entire target disk (destroying any
    firmware already on it), the UEFI live-boot medium and the Gentoo install
    target must be two different pieces of media, unless you accept
    reinstalling the Pi firmware onto the target afterward (see step 4):
      1. Format one FAT32 partition on a spare USB/SD card, then run
         gentoo-rpi4-firmware.sh against it. Add a live arm64 Linux distro's
         own efi/boot/bootaa64.efi to the same partition (or a separate
         partition on the same medium) so the Pi has something to boot into.
      2. Boot the Pi from that medium; confirm UEFI is active (the live
         environment should show /sys/firmware/efi).
      3. Run gentoo-install-noluks-cli.sh (or your chosen variant) from
         scripts/arm64/, targeting your real install disk (SD card, USB SSD,
         or NVMe via a PCIe HAT) — not the live-boot medium.
      4. After the install finishes, run gentoo-rpi4-firmware.sh again, this
         time against the ESP on the install disk (the partition
         gentoo-chroot*.sh installed GRUB to), so the Pi can boot that disk
         directly without the separate live-boot medium.
      5. Remove the live-boot medium and reboot from the install disk.
      6. On an 8 GB (or 4 GB) Pi 4: the pftf firmware enforces a 3 GB RAM cap
         by default. Press Esc at the rainbow/Pi logo on first boot and
         disable it under Device Manager -> Raspberry Pi Configuration ->
         Advanced Configuration -> Limit RAM to 3 GB. gentoo-rpi4-firmware.sh
         prints this reminder after it runs.

  arm (armhf)
  -----------
  - Stage3 uses the armv7a_hardfp variant (VFPv3 hard-float ABI)
  - Many armhf systems use U-Boot rather than GRUB; adjust the bootloader
    configuration if your hardware requires it
  - Signal Desktop not available for 32-bit ARM
  - Wine on armhf runs ARM32 Windows binaries natively; x86 apps not supported
  - TPM2 chips are rare on typical armhf hardware
  - Both desktop and CLI installs attempt the armv7a_hardfp-hardened-selinux-
    systemd stage3 first

================================================================================
  8. TROUBLESHOOTING
================================================================================

  INSTALLATION ISSUES
  -------------------

  Stage3 download fails / "Failed to fetch stage3 info"
    - Check network: ping 8.8.8.8 and ping distfiles.gentoo.org
    - If DNS is not working: echo "nameserver 8.8.8.8" > /etc/resolv.conf
    - If the mirror is down, the Gentoo mirror list is at:
        https://www.gentoo.org/downloads/mirrors/

  Partition creation fails
    - If the disk has an existing partition table that refuses to be removed:
        wipefs -a /dev/sdX && sgdisk --zap-all /dev/sdX
    - On NVMe drives, partitions use p1/p2 naming (nvme0n1p1, nvme0n1p2).
      The script detects this automatically.

  LUKS passphrase not accepted
    - The passphrase must be entered twice during luksFormat and once more
      during cryptsetup open. If you made a typo during format, re-run from
      the beginning.

  CHROOT ISSUES
  -------------

  emerge @world fails with Python TARGETS slot conflict
    - The active Python version is detected and pinned automatically. If it
      fails, pin manually in make.conf:
        PYTHON_SINGLE_TARGET="python3_14"
        PYTHON_TARGETS="python3_14"
      Then run:
        emerge --ask=n --oneshot sys-apps/portage sys-libs/libselinux \
            sys-apps/policycoreutils
        emerge --ask -vuDNU @world

  Kernel build fails with OOM (Killed signal terminated cc1plus)
    - LLVM compilation requires ~1.5-2 GiB RAM per parallel job at -O3.
    - The scripts use all cores (nproc) and activate swap before @world.
    - If OOM still occurs, add a swap file and resume:
        dd if=/dev/zero of=/swapfile bs=1G count=4
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        emerge --resume

  grub-install fails
    - Confirm /boot is mounted: mount | grep /boot
    - Confirm the correct --target for your architecture (see section 5d).

  BOOT ISSUES
  -----------

  Boot frozen at "loading initial ramdisk"
    - The kernel lacks EFI framebuffer support. Use gentoo-live-chroot.sh
      from the live USB to run kernel-rebuild.sh.

  Raspberry Pi 4 shows the rainbow splash / Pi logo but never reaches GRUB
    - The boot ROM found start4.elf/config.txt but has no UEFI armstub, or
      GRUB isn't where UEFI expects it. Run gentoo-rpi4-firmware.sh against
      the disk's ESP (see section 7, arm64 notes) to install RPI_EFI.fd
      alongside the Broadcom boot files.
    - If it still doesn't boot from an SD card or USB (only from the SD
      card's own boot partition worked before), the Pi's EEPROM is too old.
      Update it from another machine: https://github.com/raspberrypi/rpi-eeprom

  Raspberry Pi 4 8GB only shows/uses 3 GB of RAM
    - The pftf UEFI firmware caps RAM at 3 GB by default (DMA hardware
      workaround) unless told otherwise. Press Esc at the Pi logo to enter
      firmware setup: Device Manager -> Raspberry Pi Configuration ->
      Advanced Configuration -> Limit RAM to 3 GB -> Disabled. Safe with the
      kernel these scripts build (5.8+ has the required DMA patch).

  Failed to find LUKS device / missing kernel support for storage
    - The initramfs is missing dm-crypt or storage controller drivers.
    - The chroot scripts compile CONFIG_DM_CRYPT=y and storage drivers (NVMe,
      SATA, SCSI) as built-in (=y). If the kernel was built without these,
      use gentoo-live-chroot.sh to trigger a kernel rebuild.

  /dev/dri missing / GPU not initialized
    - GPU drivers must be modules (=m), not built-in (=y). Built-in GPU
      drivers run before root mount and cannot access /lib/firmware/, causing
      a fatal firmware load failure.
    - Rebuild the kernel; after reboot: modprobe amdgpu (or i915 / nouveau)

  SELinux "A valid context could not be obtained" at login
    - The user has no SELinux login mapping.
    - Run: semanage login -a -s staff_u -r s0-s0:c0.c1023 <username>
    - The chroot scripts do this automatically for new installs.

  SELinux not active after boot
    - Check kernel: zcat /proc/config.gz | grep CONFIG_SECURITY_SELINUX
      Must be =y.
    - Check cmdline: cat /proc/cmdline | grep selinux
      Must contain: security=selinux selinux=1
    - Run gentoo-selinux.sh if not yet run.

  First boot takes very long / appears to hang
    - The SELinux filesystem relabeling (restorecon -R /) runs once on first
      boot. On slow storage it can take 10-30 minutes. Wait for it to complete.

  POST-INSTALL ISSUES
  -------------------

  UFW service fails to start
    - Root cause: ip_tables.ko no longer exists in kernel 6.x. The legacy
      iptables backend requires it; iptables must be rebuilt with the nftables
      USE flag to use the nf_tables kernel infrastructure instead.
    - gentoo-ufw.sh now handles this automatically (sets nftables USE flag,
      runs eselect iptables set xtables-nft-multi, writes modules-load.d).
    - On an already-installed machine that hit this issue:
        1. sudo bash kernel-rebuild.sh [luks|noluks]   (add NFT_COMPAT etc.)
        2. Reboot
        3. sudo bash gentoo-ufw.sh                     (sets up iptables-nft)
    - The kernel must have CONFIG_NF_TABLES=m, CONFIG_NFT_COMPAT=m,
      CONFIG_NF_TABLES_IPV4/IPV6/INET=y, and CONFIG_NETFILTER_ADVANCED=y.
      The current kernel config fragment includes all of these.

  UFW: "RULE_APPEND failed (No such file or directory): rule in chain ufw-*"
    - Symptom: 'ufw --force enable' (and thus gentoo-ufw.sh itself) fails with
      RULE_APPEND failed for ufw-not-local, ufw-after-logging-*, ufw-user-limit,
      etc. "Problem running '/etc/ufw/before.rules'" / user.rules also shown.
    - Root cause: nft_compat kernel module is NOT loaded. iptables-nft can list
      rules without nft_compat (so the iptables -L check passes), but it cannot
      CREATE custom chains without it. UFW's rules files define dozens of custom
      chains; all chain creations fail silently, then every rule that references
      them fails with "No such file or directory".
    - Key diagnostic: the old 'iptables -L' check was insufficient — it passes
      even when chain creation is broken. The script now also tests chain creation
      with 'iptables -N ufw-nft-probe-$$' and exits with a clear message if it
      fails, instead of passing through to the cryptic iptables-restore errors.
    - Fix: run kernel-rebuild.sh (adds CONFIG_NFT_COMPAT=m to the kernel config),
      reboot into the new kernel, then re-run gentoo-ufw.sh.
    - Also fixed: ufw.service races ahead of systemd-modules-load.service at boot
      (DefaultDependencies=no). gentoo-ufw.sh now writes a drop-in at
      /etc/systemd/system/ufw.service.d/after-modules-load.conf with
      After=systemd-modules-load.service to prevent the race.

  UFW: XT_MATCH modules missing after kernel rebuild
    - Symptom: nf_conntrack, xt_limit, xt_hl etc. not present in /lib/modules
    - Cause: CONFIG_NETFILTER_ADVANCED=y was missing from the config fragment.
      make olddefconfig silently drops all NETFILTER_XT_MATCH_* options if
      NETFILTER_ADVANCED is not set (they all depend on it). Fixed in current
      kernel config fragment.
    - Also check: the updates/ directory in /lib/modules takes priority over
      kernel/ in depmod search order. kernel-rebuild.sh now syncs updates/ to
      the new build automatically.

  emerge fails with "Failed to set new SELinux execution context"
    - Occurs when portage tries to exec itself as portage_t but /sys/fs/selinux
      is not mounted (chroot on a non-SELinux live USB) or the transition is
      denied by the current context.
    - Fixed in current chroot scripts: FEATURES="-selinux" is written to
      make.conf so portage skips the context transition during the install phase.
    - On an already-installed system running postinstall scripts: the error is
      usually a warning (emerge continues in permissive mode). Run
      gentoo-selinux.sh which removes FEATURES="-selinux" and runs restorecon.
    - To fix file contexts after running emerge without SELinux FEATURES:
        restorecon -R /

  Signal fails / "guru: repository already enabled"
    - Fixed in current scripts — the check now uses directory existence
      (/var/db/repos/guru) rather than eselect output parsing.
    - If running an older script: manually run
        emerge --sync guru && emerge --ask=n net-im/signal-desktop-bin

  Winetricks fails / "Wine does not appear to be installed"
    - Fixed in current scripts — checks for both wine and wine64 binaries.
    - If wine is installed but winetricks still fails:
        which wine wine64 2>/dev/null
      If neither is found, re-run gentoo-wine.sh first.

  Steam fails / "no ebuilds to satisfy games-util/steam-launcher"
    - Fixed in current scripts — package renamed to games-util/steam.
    - If running an older script: emerge --ask=n games-util/steam

  PAM breaks login after running gentoo-pam.sh
    - Restore the backup: cp /etc/pam.d/system-auth.bak /etc/pam.d/system-auth
    - The current script patches the existing system-auth rather than replacing
      it, which avoids stripping Gentoo-specific modules.
    - If you cannot log in at all, boot a live USB, mount the system, and
      restore the backup from there.

  AIDE database initialization fails
    - Check: ls -la /var/lib/aide
    - If the directory does not exist: mkdir -p /var/lib/aide
    - Run aide --init manually after fixing the directory.

  autoupdate service fails silently
    - Check the journal: journalctl -u autoupdate.service
    - Run manually: sudo /usr/local/sbin/autoupdate.sh

  SELinux AVC denials in audit log
    - Review: ausearch -m avc -ts recent | audit2why
    - Apply policy: sudo /usr/local/sbin/selinux-avc-update
    - Revert to permissive temporarily if needed:
        setenforce 0
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

  SECURE BOOT ISSUES
  ------------------

  sbctl status shows "Secure Boot: disabled" after enrollment
    - Enable Secure Boot in firmware setup after enrolling keys.

  Secure Boot blocks boot after key enrollment
    - Boot from live USB (disable Secure Boot temporarily), chroot, and:
        sbctl sign /boot/EFI/Gentoo/grubx64.efi
        sbctl sign /boot/EFI/BOOT/BOOTX64.EFI
        sbctl verify

  TPM ISSUES
  ----------

  TPM asks for passphrase on every boot despite enrollment
    - PCR measurements changed (firmware update, Secure Boot key change).
    - Re-enroll: run gentoo-tpm.sh again.
    - Remove old slots: systemd-cryptenroll --wipe-slot=<n> <device>

  NVIDIA DRIVER ISSUES (x86_64 only)
  ------------------------------------

  NVIDIA driver fails to load after kernel update
    - Rebuild the module: emerge @module-rebuild
    - The autoupdate script does this automatically.

  Black screen with NVIDIA but X starts  (desktop)
    - Check for SELinux denials: ausearch -m avc -ts recent | grep nvidia
    - Apply policy if needed: sudo /usr/local/sbin/selinux-avc-update

  HARDWARE-SPECIFIC NOTES
  -----------------------

  Asus E203M (Celeron N4000, Gemini Lake) — touchpad not working after install
    - The I2C controller is present (lspci shows 00:17.0) but the touchpad
      never enumerates because the platform pinctrl isn't loaded.
    - Fix: run kernel-rebuild.sh to build PINCTRL_GEMINILAKE=m and
      I2C_DESIGNWARE_PCI=m, then reboot.
    - Confirm with: ls /dev/i2c-* (should show at least /dev/i2c-0)

  Asus E203M — WiFi not working (iwd/wlan0 present but no regulatory domain)
    - Symptom: wlan0 interface exists, network scan works, but connection fails.
    - Root cause: SELinux AVC denial blocks reading regulatory.db from firmware.
    - Fix: restorecon -R /usr/lib/firmware/ && systemctl restart iwd NetworkManager

  Asus Prime X399-A — no wired network on first boot
    - Intel I211-AT requires the igb driver (CONFIG_IGB=m). If installed before
      this was in the kernel fragment, run kernel-rebuild.sh and reboot.

  Dell PowerEdge T320/T330 — fans at 100% / iDRAC unreachable from OS
    - Root cause: IPMI drivers not loaded. iDRAC monitors the OS via IPMI; if
      the kernel provides no IPMI interface, iDRAC assumes the system is hung
      and drives fans to maximum.
    - Fix: run kernel-rebuild.sh to build CONFIG_IPMI_HANDLER=m and related
      modules, then reboot. Verify with: ls /dev/ipmi0

  Dell PowerEdge T320/T330 — no wired network on first boot
    - Broadcom BCM5720 requires the tg3 driver (CONFIG_TIGON3=m). Run
      kernel-rebuild.sh and reboot.

  Kernel config bool options produce make warning during build
    - Symptom: "warning: symbol value 'm' invalid for <option>"
    - Cause: a bool Kconfig symbol was set to =m in the fragment. Bool symbols
      only accept =y or =n; =m is silently treated as =n.
    - Known affected options (now fixed to =y in all scripts):
        CONFIG_SURFACE_AGGREGATOR_BUS  (Surface tablet bus)
        CONFIG_X86_AMD_PSTATE          (Ryzen CPU frequency driver)
    - If you see this for a different symbol, change =m to =y in the fragment
      in kernel-rebuild.sh or the relevant chroot script.

================================================================================
  LICENSE
================================================================================

  Licensed under the GNU General Public License v3.0 (GPL-3.0) or later.
  See the LICENSE file in the repository root for the full text. Forks
  and derivative works must remain open-source under the same license.

================================================================================
  END OF README
================================================================================
