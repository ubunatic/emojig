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

if test "$OS" != "linux"
then die "Emojig currently only supports Linux platforms. Detected OS: $OS"
fi

case "$ARCH" in
    x86_64)        TARGET_ARCH="x86_64" ;;
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    *)             die "Unsupported architecture: $ARCH. Supported architectures: x86_64, aarch64." ;;
esac

# ── 2. Resolve Latest Release Tag from Codeberg API ─────────────────────────────
info "Resolving latest release from Codeberg..."
API_RESP=$(curl -sSf "https://codeberg.org/api/v1/repos/ubunatic/emojig/releases" 2>/dev/null || echo "")

if test -z "$API_RESP"
then die "Could not connect to Codeberg API. Please check your internet connection."
fi

# Clean POSIX sh extraction of the first "tag_name" field without jq dependency
TAG=$(echo "$API_RESP" | grep -o '"tag_name":"[^"]*"' | head -n 1 | cut -d':' -f2 | tr -d '"')

if test -z "$TAG"
then die "Could not resolve the latest tag from Codeberg API."
fi

info "Resolved latest release: $TAG"

VERSION=$(echo "$TAG" | sed 's/^v//')

# ── 3. Download & Verify Release Archive ───────────────────────────────────────
ASSET_NAME="emojig-${VERSION}-${TARGET_ARCH}-linux-musl.tar.gz"
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
if ! command -v emojig >/dev/null 2>&1
then warn "$INSTALL_DIR is not in your PATH. Add it to your shell configuration:"
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
# ── 6. Emoji Font Check & Installation ───────────────────────────────────────
# foot (libfcft) requires CBDT bitmap fonts for color emoji — COLRv1 vector
# fonts (e.g. Noto-COLRv1.ttf shipped by modern distros) are not supported.
# Twemoji (twitter-twemoji-fonts / fonts-twemoji) is a CBDT font that works.

install_font_pkg() {
    PKG_MGR=""
    PKG_NAME=""
    if command -v dnf >/dev/null 2>&1
    then PKG_MGR="dnf"; PKG_NAME="$1"
    elif command -v apt-get >/dev/null 2>&1
    then PKG_MGR="apt"; PKG_NAME="$2"
    elif command -v pacman >/dev/null 2>&1
    then PKG_MGR="pacman"; PKG_NAME="$3"
    elif command -v zypper >/dev/null 2>&1
    then PKG_MGR="zypper"; PKG_NAME="$4"
    fi

    if test -n "$PKG_MGR" && test -n "$PKG_NAME"
    then
        info "Installing font package '$PKG_NAME' via $PKG_MGR..."
        case "$PKG_MGR" in
            dnf)    sudo dnf install -y "$PKG_NAME" || true ;;
            apt)    sudo apt-get install -y "$PKG_NAME" || true ;;
            pacman) sudo pacman -S --noconfirm "$PKG_NAME" || true ;;
            zypper) sudo zypper install -y "$PKG_NAME" || true ;;
        esac
    fi
}

HAS_COLOR_EMOJI=0
HAS_CBDT_FONT=0

if command -v fc-list >/dev/null 2>&1
then
    if fc-list : family | grep -i -q -E "color emoji|twemoji|joypixels|openmoji|emoji"
    then HAS_COLOR_EMOJI=1
    fi
    if fc-list : file | grep -i -q -E "twemoji|joypixels|openmoji|-pb-|CBLC|CBDT"
    then HAS_CBDT_FONT=1
    fi
fi

if test "$HAS_COLOR_EMOJI" -eq 0
then
    warn "No color emoji font detected."
    install_font_pkg "twitter-twemoji-fonts" "fonts-twemoji" "ttf-twemoji" "twemoji-color-fonts"
fi

# foot needs a CBDT bitmap font — install Twemoji proactively when foot is present
if command -v foot >/dev/null 2>&1 && test "$HAS_CBDT_FONT" -eq 0
then
    info "Foot terminal detected: installing Twemoji CBDT bitmap font for color emoji support..."
    install_font_pkg "twitter-twemoji-fonts" "fonts-twemoji" "ttf-twemoji" "twemoji-color-fonts"
    fc-cache -f 2>/dev/null || true
    if command -v fc-list >/dev/null 2>&1 &&
       fc-list : file | grep -i -q -E "twemoji|joypixels|openmoji|-pb-|CBLC|CBDT"
    then HAS_CBDT_FONT=1
    fi
fi

# Warn if foot is still left without a CBDT font after install attempt
if command -v foot >/dev/null 2>&1 && test "$HAS_CBDT_FONT" -eq 0
then
    warn "No CBDT bitmap emoji font found. Foot may not render color emoji correctly."
    warn "Install 'twitter-twemoji-fonts' (Fedora) or 'fonts-twemoji' (Ubuntu/Debian)."
    warn "Alternative: export EMOJIG_TERMINAL=ptyxis  (supports COLRv1 vector fonts)"
fi
