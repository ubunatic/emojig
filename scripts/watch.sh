#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

# Watches spec source files and rebuilds on each save.
set -euo pipefail

: "${GOCACHE:=/tmp/emojig-gocache}"
export GOCACHE


ED_FILE="$1"

if test -n "$ED_FILE"
then echo "INF: watching $ED_FILE — recompiles on each save (Ctrl-C to stop)..."
else echo "ERR: arg1 is empty, must be a file"; exit 1
fi

scripts=$(dirname "$0")
root=$(dirname "$scripts")
base=$(basename "$ED_FILE")
stem=${base%.yaml}

_make() { (cd "$root" && make "$@"); }
_go()   { (cd "$root" && go   "$@"); }

last=""
while true
do
  cur=$(stat -c %Y "$ED_FILE")
  if test "$cur" != "$last"
  then last="$cur"
       case "$base" in
       (en.yaml|de.yaml|es.yaml|fr.yaml|it.yaml|nl.yaml|pl.yaml|pt.yaml|ru.yaml|tr.yaml|uk.yaml)
           if _go run ./scripts/convert_spec/ "$ED_FILE" "spec/strings_${stem}.json"
           then echo "INF: strings spec compiled"
           else echo "ERR: failed to compile strings spec"; exit 1
           fi
           ;;
       (art.yaml)
           if _go run ./scripts/convert_spec/ "$ED_FILE" "spec/art.json" &&
              _go run ./scripts/gen_about_art/ &&
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
       (*.yaml)
           if _go run ./scripts/convert_spec/ "$ED_FILE" "spec/$stem.json"
           then echo "INF: spec compiled"
           else echo "ERR: failed to compile spec"; exit 1
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
