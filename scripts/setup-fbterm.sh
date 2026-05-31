#!/usr/bin/env bash
# Helper script for setting up fbterm for emojig in a Linux virtual console.
# Run once as yourself (not root); uses sudo only where needed.

set -euo pipefail

info()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31merr\033[0m %s\n' "$*"; exit 1; }

# ── 1. Install fbterm ──────────────────────────────────────────────────────────
if command -v fbterm &>/dev/null; then
    ok "fbterm already installed ($(command -v fbterm))"
else
    info "Installing fbterm..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y fbterm
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm fbterm
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y fbterm
    else
        die "Cannot detect package manager. Install fbterm manually and re-run."
    fi
fi

# ── 2. /dev/fb0 group membership ───────────────────────────────────────────────
FB_GROUP=$(stat -c '%G' /dev/fb0 2>/dev/null || echo "video")
if groups | grep -qw "$FB_GROUP"; then
    ok "User already in group '$FB_GROUP'"
else
    info "Adding $USER to group '$FB_GROUP' (requires logout/login to take effect)..."
    sudo usermod -aG "$FB_GROUP" "$USER"
    warn "You must log out and back in before fbterm can access /dev/fb0."
fi

# ── 3. Font configuration ──────────────────────────────────────────────────────
FBTERM_CFG="$HOME/.fbtermrc"
FONT_FAMILY="Noto Sans"

if fc-list | grep -qi "Noto"; then
    ok "Noto fonts available"
else
    warn "Noto fonts not found — fbterm will fall back to a system monospace."
    warn "Install with: sudo apt-get install fonts-noto"
fi

if [[ -f "$FBTERM_CFG" ]]; then
    ok ".fbtermrc already exists at $FBTERM_CFG — not overwriting"
else
    info "Writing $FBTERM_CFG..."
    cat > "$FBTERM_CFG" <<EOF
# fbtermrc written by emojig scripts/setup-fbterm.sh
font-names=$FONT_FAMILY
font-size=14
text-encodings=utf-8
EOF
    ok "Wrote $FBTERM_CFG"
fi

# ── 4. Verify ──────────────────────────────────────────────────────────────────
info "Setup complete. In a virtual console (Ctrl+Alt+F3), run:"
printf '    fbterm -- emojig\n'
printf '    fbterm -- emojig --tui\n'
