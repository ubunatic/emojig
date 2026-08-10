#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install cairo/pango/pangocairo *development* packages (headers + pkg-config
# files + unversioned .so symlinks) — scripts/canary_font/main.go links
# against them directly via `#cgo pkg-config: cairo pango pangocairo`.
# Skips installation if pkg-config can already resolve all three.
set -euo pipefail

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }

has_dev_libs() {
    command -v pkg-config >/dev/null 2>&1 || return 1
    pkg-config --exists cairo pango pangocairo
}

if has_dev_libs
then ok "cairo/pango/pangocairo dev packages already installed"
     exit 0
fi

if command -v dnf >/dev/null 2>&1
then info "Installing cairo-devel pango-devel via dnf..."
     sudo dnf install -y cairo-devel pango-devel
elif command -v apt-get >/dev/null 2>&1
then info "Installing libcairo2-dev libpango1.0-dev via apt-get..."
     sudo apt-get install -y libcairo2-dev libpango1.0-dev
elif command -v zypper >/dev/null 2>&1
then info "Installing cairo-devel pango-devel via zypper..."
     sudo zypper install -y cairo-devel pango-devel
elif command -v apk >/dev/null 2>&1
then info "Installing cairo-dev pango-dev via apk..."
     sudo apk add cairo-dev pango-dev
elif command -v pacman >/dev/null 2>&1
then info "Installing cairo pango via pacman (Arch ships headers/pkg-config in the main packages)..."
     sudo pacman -S --noconfirm cairo pango
else warn "Install 'cairo-devel pango-devel' (Fedora/openSUSE) or 'libcairo2-dev libpango1.0-dev' (Ubuntu/Debian) for scripts/canary_font/main.go"
     exit 1
fi

if ! has_dev_libs
then warn "pkg-config still can't resolve cairo/pango/pangocairo after install — check the package names above for your distro"
     exit 1
fi

ok "cairo/pango/pangocairo dev packages installed"
