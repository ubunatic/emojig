# Go Scripts Layout

## Why subdirectories?

Go requires every `package main` in its own directory. The `scripts/` folder
contains multiple independent entry points (one `main()` each), so each script
lives in its own subdirectory:

```
scripts/
  pack_emojis/main.go
  bump_version/main.go
  screenshot/main.go
  ...
```

Keeping them flat (`scripts/foo.go`) causes a build failure — Go treats all
`.go` files in a directory as one package and rejects multiple `main()`
functions.

## Running scripts

```sh
go run ./scripts/pack_emojis/
go run ./scripts/bump_version/ patch
```

The Makefile targets (`make pack`, `make bump-patch`, etc.) do this internally.

## Testing and vetting

`make test` runs zig and Go tests (`go vet ./...` + `go test ./...`).
`make preflight` runs everything in `test` plus license and formatting checks.

Packages with tests: `internal/emoji`, `internal/spec`, `scripts/pack_emojis`.

### Coverage gaps and why

| Package | Reason no tests |
|---|---|
| `internal/term` | All syscall/TTY ioctls — requires a real tty, nothing pure to unit test |
| `scripts/bump_version` | Version-bump logic is inside `main()` — needs extraction before it's testable |
| `scripts/*` (rest) | Orchestration only — no pure helper functions worth isolating |
| `internal/tui` | Renders to a live terminal — integration/screenshot testing only |
| `cmd/mojigo` | Thin CLI entry point — no logic beyond flag parsing |

## Naming convention

Demo scripts drop the `_demo` suffix in the directory name (`fade_demo.go` →
`scripts/fade/`). All others match the original file name.
