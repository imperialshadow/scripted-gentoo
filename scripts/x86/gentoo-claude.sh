#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

echo "=== Installing Claude Code ==="

# Install Node.js if not already present
if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js..."
    emerge --ask=n net-libs/nodejs
else
    echo "Node.js already installed ($(node --version))."
fi

# Install Claude Code into a user-writable npm prefix so auto-updates work
# without sudo. /usr as npm prefix requires root for every update.
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
NPM_GLOBAL="${USER_HOME}/.npm-global"

echo "Configuring npm prefix: ${NPM_GLOBAL}"
sudo -u "${SUDO_USER:-$USER}" npm config set prefix "$NPM_GLOBAL"

NPM_PATH_LINE="export PATH=\"\$HOME/.npm-global/bin:\$PATH\""
BASHRC="${USER_HOME}/.bashrc"
if ! grep -qF '.npm-global/bin' "$BASHRC" 2>/dev/null; then
    echo "$NPM_PATH_LINE" >> "$BASHRC"
    echo "Added ~/.npm-global/bin to PATH in ${BASHRC}"
fi

echo "Installing @anthropic-ai/claude-code..."
export PATH="${NPM_GLOBAL}/bin:$PATH"
sudo -u "${SUDO_USER:-$USER}" npm install -g @anthropic-ai/claude-code

# Configure maxTokens for root and all future users
CLAUDE_SETTINGS='{"maxTokens": 200000}'
for target_dir in /root/.claude /etc/skel/.claude "${USER_HOME}/.claude"; do
    mkdir -p "$target_dir"
    echo "$CLAUDE_SETTINGS" > "$target_dir/settings.json"
done
echo "Claude Code settings configured (maxTokens: 200000)"

echo
echo "Claude Code installed: $("${NPM_GLOBAL}/bin/claude" --version 2>/dev/null || echo 'installed')"
echo "Run 'source ~/.bashrc' then 'claude' to start."
