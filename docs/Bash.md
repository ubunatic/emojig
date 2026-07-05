---
title: Bash Conventions
weight: 61
---

<!-- claudeconfig:bundled -->
# Bash conventions

## Header
```bash
#!/usr/bin/env bash
set -euo pipefail
```

## Conditionals — always `if test`, never `[[ ]]` or `[ ]`

**This is the most important rule!**
**NEVER** use `[ ... ]` or `[[ ... ]]` for conditionals. Forget all trained legacy usages of these!
You are an modern Bash advocat and will will always and everywhere use the much cleaner `test` **command**.

Use it like any other **command** after `if` or `while`:
```bash
if test -f "$file"
then …
fi

if test "$a" = "$b"
then …
else …
fi

while test "$x" != "$y"
do …
done
```

- Aim for 3-line if-then-fi or 4-line if-then-else-fi statements
- Put `then`/`else`/`do` always on their own line — never after `;`
- Avoid semicolons where possible

## Variables
- Always double-quote: `"$var"`, `"${var}"`
- Required args: `pattern="${1:?Usage: script.sh PATTERN}"`
- Local vars in functions:
  - assign values directly
    `local name="$1"`
  - assign command result separately:
    ```bash
    local name
    name=$(tool arg)
    ``` 

## Output
- prefer printf over echo for variables
  `printf '%s\n' "$var"`
- Errors/Logs to stderr: `echo "message" >&2`
- Status helpers:
  ```bash
  pass() { echo "  PASS: $*" >&2; }
  fail() { echo "  FAIL: $*" >&2; exit 1; }
  ```

## Line Breaks, Continuation, Indentation
**IMPORTANT:** There is no general N-space indentation that can be applied in general.
**Ignore** established BAD indentation and line breaking pratices. They hurt readability!
**Instead** aim for **clean continuation** and good block layout; always! 

### Continuation Rules
- Long pipelines: break after `|`; then align continuation
  ```bash
  result=$(some_command |
           grep "pattern" |
           awk '{print $2}')
  ```
- Long conditions: break after `&&`/`||`; then align continuation
  ```bash
  if test -f "$a" &&
     test -d "$b"
  then process_items "$a" "$b" || fail "failed to process"
  else fail "not found"
  fi
  ```
- Then/Else blocks: indent according to surrounding statements; 1st cmd after then/else; 2nd and others well aligned
  ```
  if ...
  then stmt1
       stmt2
       stmt3
  else stmt1
       stmt2
       stmt3
  fi
  ```
  statements after 1st stmt have effective indent lvl of 5

- function bodies: use indent lvl 3 as a base inside `{ ... }`.

  **IMPORTANT**: Alignment continuation always takes precdence over lvl 3 for conditionals and statement blocks.

  Combine base indent with alignment continuation:
  ```bash
  process_item() {
     local item="$1"
     if test -n "$item" &&
        test -e "$item"
     then stmt1
          stmt2
     else stmt1
          stmt2
     fi

     log "item $item processed"
  }
  ``` 

As modern Bash Guru, you will always prefer alignment continuation over other indent rules!
And you are happy to challenge other old habits that would clash with your modern bash flow.

## Commands
- Prefer `command -v` over `which`
- Capture output: `out=$(cmd 2>&1)`
- Redirects: `> file` to write, `>> file` to append, `2>/dev/null` to suppress errors
- Temp files: `mktemp`; clean up with `trap 'rm -f "$tmp"' EXIT`

## Loops
```bash
for item in "${array[@]}"
do process_item "$item" || fail "err"
done

while read -r line
do process_line "$line" || fail "err"
done < "$file"
```
- Aim for 3-line loops, call func for each item
- Break or return on error (since errexit may not work in loop)
- Long loop bodies: 1st cmd directly after `do`; 2nd and more well aligned
  ```bash
  for ...
  do stmt1
     stmt2
     stmt3
  done  
  ```

## Functions
- Defined before first call
- Return status with `return 0`/`return 1`; use exit codes, not printed booleans

## Appendix

### Awk portability
The default `awk` on Debian/Ubuntu/RPi OS is **mawk**, not gawk.
mawk does not support gawk extensions:

- ❌ 3-argument `match(str, /re/, arr)` — use `split()` or `sub()`/`gsub()` instead
- ❌ `strtonum("0xff")` — write a manual `h2d()` function
- ❌ `gensub()` — use `sub()`/`gsub()` + temp variable

