<!-- claudeconfig:bundled -->
# Make conventions

Default language assumed: Go.
Apply to other languages accordingly.

## Structure

- First target is the default goal — always `help`
- All targets declared `.PHONY` using the `⚙️` sentinel trick (see below)
- One blank line between targets

## Variables

Example:

```makefile
BINARY  := claudeconfig        # output binary name
CONFIG  := config.yaml         # default config file
TARGET  := $(HOME)/.claude     # installation target dir
PROJECT := .                   # project root (passed to tool as -p)
PREFIX  ?= /usr/local          # overridable install prefix
```

- Use  `:=` for immediate assignment (most vars)
- Use  `?=` for env-overridable vars (`PREFIX`)
- Align `=` signs for readability

## Phony declaration — `⚙️` sentinel

```makefile
.PHONY: ⚙️  # make all commands phony
```

Adding `⚙️` as a prerequisite on every target (e.g. `help: ⚙️  ## …`) causes Make
to treat all targets as phony without listing each name twice. The Unicode
character is never a real file, so the rule fires unconditionally.

## Self-documenting help target

```makefile
help: ⚙️  ## show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'
```

Every target that should appear in help gets a `  ## description` comment on the
same line as the rule header.  `help` scrapes them automatically.

## Build dependency pattern

Action targets depend on `build` so the binary is always fresh:

```makefile
build: ⚙️  ## build the binary
	go build -o $(BINARY) .

apply: ⚙️ build  ## apply config.yaml to the Claude Code config directory
	./$(BINARY) apply -c $(CONFIG) -t $(TARGET) -p $(PROJECT)
```

- `build` rebuilds only when sources change (Make's normal rules apply)
- Action targets invoke `./$(BINARY)` — the locally-built binary, not the one
  on `$PATH`

## Install target (Go)

```makefile
install: ⚙️ build  ## install the binary to PREFIX/bin (default: /usr/local/bin)
	go install .
	@sudo install -m 0755 $(BINARY) $(PREFIX)/bin/$(BINARY) && \
	  echo "✅ Installed for all users" || echo "⚠️ System install failed"
```

- `go install` puts the binary in `$(GOPATH)/bin` (user-local)
- `sudo install -m 0755` copies to `$(PREFIX)/bin` for system-wide availability
- `|| echo …` degrades gracefully when `sudo` is unavailable

## Test target

```makefile
test: ⚙️  ## run linter and tests
	go vet ./...
	go test ./...
```

Always run `go vet` before `go test`; vet catches issues tests may not exercise.
