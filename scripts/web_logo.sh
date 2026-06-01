#!/bin/sh
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Emojig: Produce a web-compatible SVG from the source app logo.
# Uses Inkscape to strip editor-specific markup (sodipodi/inkscape
# namespaces, metadata) and drop unused defs, yielding a clean plain
# SVG suitable for embedding on a website.
#
# Usage: scripts/web_logo.sh [SOURCE_SVG] [OUTPUT_SVG]
#   SOURCE_SVG  default: src/assets/emojig-icon.svg
#   OUTPUT_SVG  default: src/assets/emojig-icon.web.svg

set -e

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*"; exit 1; }

# Resolve repo root so the script works from any directory.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SRC=${1:-"$REPO_ROOT/src/assets/emojig-icon.svg"}
OUT=${2:-"$REPO_ROOT/src/assets/emojig-icon.web.svg"}

if ! test -f "$SRC"
then die "Source SVG not found: $SRC"
fi

# Skip the conversion unless the source is newer than the generated file.
if test -f "$OUT" && ! test "$SRC" -nt "$OUT"
then ok "Up to date: $OUT (source not newer)"; exit 0
fi

# inkscape is only needed to regenerate, so it is not a strict dev dependency:
# warn and keep any existing output rather than failing the build.
if ! command -v inkscape >/dev/null 2>&1
then warn "inkscape not found; skipping logo conversion (install: sudo apt install inkscape)"
     exit 0
fi

info "Converting $SRC"
info "  -> plain web SVG"

# --export-plain-svg  : drop sodipodi/inkscape namespaces and editor metadata
# --vacuum-defs       : remove unused gradient/clip/etc. definitions
inkscape \
    --export-type=svg \
    --export-plain-svg \
    --vacuum-defs \
    --export-filename="$OUT" \
    "$SRC" >/dev/null 2>&1

if ! test -f "$OUT"
then die "Inkscape did not produce an output file: $OUT"
fi

ok "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
