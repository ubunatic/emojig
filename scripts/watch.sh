#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

# Watches spec files and rebuilds on each save.
set -euo pipefail


ED_FILE="$1"

if test -n "$ED_FILE"
then echo "INF: watching $ED_FILE — recompiles on each save (Ctrl-C to stop)..."
else echo "ERR: arg1 is empty, must be a file"; exit 1
fi

scripts=$(dirname "$0")
root=$(dirname "$scripts")
dir=$(dirname "$ED_FILE")
base=$(basename "$ED_FILE")

_make() { (cd "$root" && make "$@"); }
_go()   { (cd "$root" && go   "$@"); }

last=""
while true
do
  cur=$(stat -c %Y "$ED_FILE")
  if test "$cur" != "$last"
  then last="$cur"
       case "$base" in
       (art.json) 
           if _go run ./scripts/gen_about_art/ &&
              _go run ./scripts/gen_about_art/ print
           then echo "INF: art compiled and printed"
           else echo "ERR: failed to compile art"; exit 1
           fi
           ;;
       (input.yaml)
           if _go run ./scripts/gen_input_spec/
           then echo "INF: input spec compiled"
           else echo "ERR: failed to compile input spec"; exit 1
           fi
           ;;
       (*) ;;
       esac
       if _make install
       then echo "INF: emojig rebuilt on $ED_FILE change"
       else echo "ERR: failed to build emojig"; exit 1
       fi
  fi
  sleep 1
done
