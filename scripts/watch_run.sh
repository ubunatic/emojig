#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

scripts=$(dirname "$0")
root=$(dirname "$scripts")

_make() { (cd "$root" && make "$@"); }

find_last_mod() {
   find "$root/src" "$root/spec" "$root/Makefile" "$root/build.zig" "$root/build.zig.zon" -type f -exec stat -c "%Y" {} + | sort -rn | head -n 1
}

echo "INF: watching source and spec files — recompiling and running GUI on changes (Ctrl-C to stop)..."

last=""
while true
do
  cur=$(find_last_mod)
  if test "$cur" != "$last"
  then last="$cur"
       if _make install
       then echo "INF: emojig rebuilt successfully, opening GUI..."
            _make gui || true
       else echo "ERR: rebuild failed"
       fi
  fi
  sleep 1
done
