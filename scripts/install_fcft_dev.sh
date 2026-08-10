#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install fcft's *development* package (headers) — NOT required to build or
# run scripts/canary_width_compare.zig (it dlopens the already-installed
# runtime libfcft.so.4, foot's own dependency, with hand-transcribed extern
# struct declarations; no header needed at build or run time). This script
# exists purely as a convenience for maintainers who want to re-check
# fcft.h's real struct layout (fcft.zig's structs expose public fields,
# unlike Cairo/Pango's opaque pointers) after an fcft upgrade, or add a new
# field. Skips installation if the header is already present.
set -euo pipefail

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }

has_fcft_header() {
    command -v pkg-config >/dev/null 2>&1 || return 1
    pkg-config --exists fcft
}

if has_fcft_header
then ok "fcft dev package already installed"
     exit 0
fi

if command -v dnf >/dev/null 2>&1
then info "Installing fcft-devel via dnf..."
     sudo dnf install -y fcft-devel
elif command -v apt-get >/dev/null 2>&1
then info "Installing libfcft-dev via apt-get..."
     sudo apt-get install -y libfcft-dev
elif command -v zypper >/dev/null 2>&1
then info "Installing fcft-devel via zypper..."
     sudo zypper install -y fcft-devel
elif command -v apk >/dev/null 2>&1
then info "Installing fcft-dev via apk..."
     sudo apk add fcft-dev
elif command -v pacman >/dev/null 2>&1
then info "Installing fcft via pacman (Arch ships headers/pkg-config in the main package)..."
     sudo pacman -S --noconfirm fcft
else warn "Install 'fcft-devel' (Fedora/openSUSE) or 'libfcft-dev' (Ubuntu/Debian) for scripts/canary_width_compare.zig"
     exit 1
fi

if ! has_fcft_header
then warn "pkg-config still can't resolve fcft after install — check the package name above for your distro"
     exit 1
fi

ok "fcft dev package installed"
