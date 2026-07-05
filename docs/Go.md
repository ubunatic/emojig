---
title: Go Conventions
weight: 60
---

<!-- claudeconfig:bundled -->
# Go Conventions

## Language & Deps
- Modern Go — use current language features (`any`, generics where they reduce noise)
- Minimise external deps; stdlib first
- Allowed: `github.com/spf13/cobra` for CLI, `gopkg.in/yaml.v3` for config
- No ORM, no logging framework, no DI container

## Project Layout
- Small: root `main.go` with features split by concern (`apply.go`, `config.go`, `status.go`)
- Med: root `main.go` with `internal/` sub-packages; no `pkg/`
- Large/Multi: tools in `cmd/<name>/main.go` with features in split files or `internal/`
- Embed static assets with `//go:embed`
- **Never commit binaries** — `go build` drops binaries in the repo root.
  Add it to `.gitignore` at project setup time:
  ```
  # ignore Go binaries
  /mybinary
  ```
  Use the `BINARY` variable from the Makefile as the canonical name so the
  `.gitignore` entry and the build output always match.

## Spec-Driven Apps
- Avoid hard-coding labels, controls, user-focussed text, icons, etc.
- Better define such in `spec/<feature>.yaml` with a `$schema` in `spec/schemas/`.
- Disregard this concept only if you are sure it does not apply, or the user demanded it.
- Go `embed` the `spec/`; It **IS** part of the code!
- Write tests and guards against the spec to make spec <-> Go interaction resilient.
- Add `spec/<feature>.yaml` to drive compile-time features:
  - `spec/strings.yaml` defines labels, titles, messages
  - `spec/labels.yaml` composite lines of text
  - `spec/controls.yaml` buttons, actions mappings, default hotkeys
  - `spec/layout.yaml` defines app layout, ordering, and more
  - `spec/screen-help.yaml` home screen content
  - `spec/screen-home.yaml` help screen content
  - add more as needed and create structs for parsing
  - for small projects start with a single `spec/config.yaml`

Again: this is not just runtime config. It is a key part of the codebase!

## CLI
- Use Cobra; one `*cobra.Command` per verb, flags defined on that command
- `RunE` not `Run` — return errors, don't `os.Exit` inside commands
- `SilenceUsage: true` on commands where error is not a usage mistake

## Error Handling
- Wrap with context: `fmt.Errorf("settings: %w", err)`
- No `panic` except truly unrecoverable init failures
- Return errors up; print only at the top level

## State Management
- **No package-level mutable variables.**
  Pass state explicitly via function parameters or a named struct.
  Package-level vars create hidden coupling and break concurrent use.
  ```go
  // bad
  var globalClient *http.Client
  // good
  type App struct { client *http.Client }
  ```
- `init()` only for truly static, side-effect-free registration (e.g. `flag.Var`).
  Never use `init()` to connect to services or load files.

## Types & Style
- Unexported types for internal results; exported only when crossing package boundary
- Pointer fields (`*bool`, `*int`) for optional struct values; add `boolPtr`/`intPtr` helpers
- Section banners: `// ── Section name ────────────────────────────────────────────`
- Doc comments on all exported symbols

## Output Discipline
- Functions return results; callers own printing
- Print changed items with two-space indent: `fmt.Printf("  wrote %s\n", path)`
- Sub-details indented four spaces

## Tests
- Table-driven tests with `t.Run`
- Test files in same package (`package main`)
- Helpers: `t.Helper()`, `t.Fatalf` for setup failures, `t.Errorf` for assertion failures
- No test frameworks — stdlib `testing` only

