#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install Twemoji CBDT bitmap font for foot terminal color emoji rendering.
# foot (libfcft) does not support COLRv1 vector fonts; CBDT is required.
# Skips installation if a CBDT font is already present.
set -euo pipefail

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }

has_cbdt() {
    local fonts
    command -v fc-list >/dev/null 2>&1 || return 1
    fonts=$(fc-list : file 2>/dev/null)
    printf '%s\n' "$fonts" | grep -i -q -E "twemoji|CBDT|CBLC"
}

if has_cbdt
then ok "Twemoji CBDT already installed"
     exit 0
fi

if command -v dnf >/dev/null 2>&1
then info "Installing twitter-twemoji-fonts via dnf..."
     sudo dnf install -y twitter-twemoji-fonts
     fc-cache -f
elif command -v apt-get >/dev/null 2>&1
then info "Installing fonts-twemoji via apt-get..."
     sudo apt-get install -y fonts-twemoji
     fc-cache -f
elif command -v zypper >/dev/null 2>&1
then info "Installing twitter-twemoji-fonts via zypper..."
     sudo zypper install -y twitter-twemoji-fonts
     fc-cache -f
elif command -v apk >/dev/null 2>&1
then info "Installing font-twitter-twemoji via apk..."
     sudo apk add font-twitter-twemoji
     fc-cache -f
elif command -v pacman >/dev/null 2>&1
then warn "Install 'ttf-twemoji' from AUR for foot color emoji: yay -S ttf-twemoji"
     exit 1
else warn "Install 'twitter-twemoji-fonts' (Fedora/openSUSE) or 'fonts-twemoji' (Ubuntu/Debian) for foot color emoji support"
     exit 1
fi

ok "Twemoji CBDT font installed"
