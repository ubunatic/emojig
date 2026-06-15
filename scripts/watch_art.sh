#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

# Watches spec/art.json and rebuilds on each save.
set -euo pipefail

echo "Watching spec/art.json — recompiles on each save (Ctrl-C to stop)..."
last=""
while true
do
  cur=$(stat -c %Y spec/art.json)
  if test "$cur" != "$last"
  then last="$cur"
       go run ./scripts/gen_about_art/ &&
       go run ./scripts/gen_about_art/ print &&
       make install
       echo "--- rebuilt ---"
  fi
  sleep 1
done
