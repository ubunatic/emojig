---
title: Bash Conventions
weight: 61
---

<!-- harnez:bundled -->
# Bash Conventions

> **Who this is for** — anyone writing a canary, a build script, or any glue in these repositories. Reference material: grep it, don't read it.
>
> **Read this if** — you are about to type `[[`.
>
> **Takeaways**
> 1. `set -euo pipefail`, always, on line two.
> 2. `if test …` — never `[ … ]`, never `[[ … ]]`, and `then`/`else`/`do` on their own lines.
> 3. Quote every expansion; declare `local` separately for command substitutions; assume default `awk` is mawk.

---

## 1. Header & Strict Mode
```bash
#!/usr/bin/env bash
set -euo pipefail
```
- `-e`: Exit immediately if any command returns a non-zero status.
- `-u`: Exit if an uninitialized variable is referenced.
- `-o pipefail`: Ensure pipeline return codes reflect the last non-zero command in the chain.

## 2. Conditionals — Always `if test`, Never `[[ ]]` or `[ ]`

**This is the most important rule!**
**NEVER** use `[ ... ]` or `[[ ... ]]` for conditionals. Forget all legacy usages!
Use the clean, standard `test` **command**:

```bash
if test -f "$file"
then printf 'Found %s\n' "$file"
fi

if test "$a" = "$b"
then printf 'Equal\n'
else printf 'Not equal\n'
fi

while test "$x" != "$y"
do process "$x"
done
```

- Aim for 3-line if-then-fi or 4-line if-then-else-fi statements.
- Put `then`/`else`/`do` always on their own lines — never after `;`.
- Avoid semicolons where possible.

## 3. Variables & Local Scope
- Always double-quote variable expansions: `"$var"`, `"${var}"`.
- Handle required arguments with default error patterns:
  `pattern="${1:?Usage: script.sh PATTERN}"`
- **Local variables in functions**:
  - Assign literal values directly: `local name="$1"`
  - **Command substitutions MUST declare first, then assign**, to prevent `local` from masking execution exit codes:
    ```bash
    local result
    result=$(command args)
    ```

## 4. Output Discipline
- Prefer `printf` over `echo` for printing variables: `printf '%s\n' "$var"`.
- Log errors to stderr: `printf 'ERROR: %s\n' "$msg" >&2`.
- Status helpers used across repository scripts:
  ```bash
  pass() {
     printf '  ✓ %s\n' "$*"
  }

  fail() {
     printf 'ERROR: %s\n' "$*" >&2
     exit 1
  }
  ```

## 5. Line Breaks, Continuation & Indentation
Avoid arbitrary fixed indentation for command blocks. Prefer **alignment continuation**:

### Continuation Rules
- **Long pipelines**: break after `|`; line up under the start of the chain:
  ```bash
  result=$(some_command |
           grep "pattern" |
           awk '{print $2}')
  ```
- **Long conditions**: break after `&&`/`||`; line up conditions under the first test:
  ```bash
  if test -f "$a" &&
     test -d "$b"
  then stmt1
       stmt2
  else fail "not found"
  fi
  ```
- **Then/Else & Loop blocks**: 1st command directly after `then`/`else`/`do`; subsequent commands aligned:
  ```bash
  for item in "${array[@]}"
  do process_item "$item" || fail "err"
     log_item "$item"
  done
  ```
- **Function bodies**: base indent level 3 inside `{ ... }`. Alignment continuation takes precedence over fixed indents for conditionals.

## 6. Commands & Traps
- Prefer `command -v` over `which`.
- Capture output cleanly: `out=$(cmd 2>&1)`.
- Redirects: `> file` to write, `>> file` to append, `2>/dev/null` to suppress errors.
- Temp files: `mktemp`; clean up with `trap 'rm -f "$tmp"' EXIT`.

## 7. Functions
- Define functions before first invocation.
- Return status with `return 0` / `return 1` (exit codes, never printed booleans).

## Appendix — Awk Portability
The default `awk` on Debian, Ubuntu, and Raspberry Pi OS is **mawk**, not gawk.
Avoid gawk extensions:
- ❌ Do not use 3-argument `match(str, /re/, arr)` — use `split()` or `sub()`/`gsub()` instead.
- ❌ Do not use `strtonum("0xff")` — write a manual `h2d()` converter.
- ❌ Do not use `gensub()` — use `sub()`/`gsub()` with a temporary variable.


