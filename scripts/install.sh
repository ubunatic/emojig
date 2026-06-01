#!/bin/sh
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Emojig: Lightweight zero-dependency installer script.
# Fetches the latest pre-compiled static release from Codeberg.
#
# Usage: curl -sSf https://ubunatic.com/emojig/install.sh | sh

set -e

info()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31merr\033[0m %s\n' "$*"; exit 1; }

# ── 1. OS & Architecture Detection ────────────────────────────────────────────
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

if [ "$OS" != "linux" ]; then
    die "Emojig currently only supports Linux platforms. Detected OS: $OS"
fi

case "$ARCH" in
    x86_64)      TARGET_ARCH="x86_64" ;;
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    *)           die "Unsupported architecture: $ARCH. Supported architectures: x86_64, aarch64." ;;
esac

# ── 2. Resolve Latest Release Tag from Codeberg API ─────────────────────────────
info "Resolving latest release from Codeberg..."
API_RESP=$(curl -sSf "https://codeberg.org/api/v1/repos/ubunatic/emojig/releases" 2>/dev/null || echo "")

if [ -z "$API_RESP" ]; then
    die "Could not connect to Codeberg API. Please check your internet connection."
fi

# Clean POSIX sh extraction of the first "tag_name" field without jq dependency
TAG=$(echo "$API_RESP" | grep -o '"tag_name":"[^"]*"' | head -n 1 | cut -d':' -f2 | tr -d '"')

if [ -z "$TAG" ]; then
    die "Could not resolve the latest tag from Codeberg API."
fi

info "Resolved latest release: $TAG"

# ── 3. Download & Verify Release Archive ───────────────────────────────────────
ASSET_NAME="emojig-${TAG}-${TARGET_ARCH}-linux-musl.tar.gz"
DOWNLOAD_URL="https://codeberg.org/ubunatic/emojig/releases/download/${TAG}/${ASSET_NAME}"
TMP_DIR=$(mktemp -d -t emojig-install-XXXXXX)
defer_cleanup() { rm -rf "$TMP_DIR"; }
trap defer_cleanup EXIT INT TERM

info "Downloading Emojig static archive..."
curl -L -o "$TMP_DIR/$ASSET_NAME" "$DOWNLOAD_URL"

# Extract binary
tar -xzf "$TMP_DIR/$ASSET_NAME" -C "$TMP_DIR"

# ── 4. Installation ───────────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

info "Installing binary to $INSTALL_DIR/emojig..."
cp "$TMP_DIR/emojig" "$INSTALL_DIR/emojig"
chmod +x "$INSTALL_DIR/emojig"

ok "Emojig successfully installed!"

# ── 5. Integration Hint ────────────────────────────────────────────────────────
if ! command -v emojig >/dev/null 2>&1; then
    warn "$INSTALL_DIR is not in your PATH. Add it to your shell configuration:"
    warn "  export PATH=\$PATH:\$HOME/.local/bin"
fi

# Generate completion scripts
info "Setting up shell completions..."
"$INSTALL_DIR/emojig" --install

ok "Shell integration installed to ~/.local/share/emojig/shell/"
ok "To activate Ctrl+E shortcut, add this line to your shell configuration:"
ok "  zsh:  source ~/.local/share/emojig/shell/emojig.zsh"
ok "  bash: source ~/.local/share/emojig/shell/emojig.bash"
ok "  fish: source ~/.local/share/emojig/shell/emojig.fish"
