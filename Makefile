.PHONY: ⚙️  # make all targets phony

SHELL = bash
VERSION = $(shell grep '\.version' build.zig.zon | grep -o '[0-9][0-9.]*')

help: ⚙️
	@printf "Emojig Makefile Targets:\n\n"
	@awk -F':.*# ' '/^[a-zA-Z0-9_-]+:.*# / { printf "  %-18s %s\n", $$1, $$2 }' Makefile

zig-help: ⚙️  # show zig build targets
	zig build --list-steps
	@echo
	@echo "ℹ️ 'zig build <step>' is used internally to manage building and testing."
	@echo "   Most zig build steps have a convenience Makefile target (see 'make help')."

build: ⚙️  # compile the application in ReleaseSmall mode
	zig build -Doptimize=ReleaseSmall

run: ⚙️  # run the inline TUI picker in current terminal
	zig build run

picker: ⚙️  # launch the emoji picker in a floating foot window (non-blocking)
	zig build picker

test: ⚙️  # run the unit tests
	zig build test
	go vet ./...
	go test ./...

tui: ⚙️  # run TUI mode (stdout path: prints selected emoji to terminal)
	zig build && zig-out/bin/emojig --tui | cat

tui-go: ⚙️  # run Go TUI port (mojigo) in the current terminal
	go run ./cmd/mojigo/ --height 10

tui-rust: ⚙️  # run Rust TUI demo in the current terminal
	cargo run --bin inline-demo -- --height 10

gui: ⚙️  # launch the floating terminal picker window (requires foot)
	zig build gui

jsdemo: ⚙️  # regenerate website/jsdemo.js from spec/jsdemo.json
	@printf '// generated from spec/jsdemo.json — do not edit by hand\nconst jsdemoSpec = %s;\n' "$$(cat spec/jsdemo.json)" > website/jsdemo.js

browse: ⚙️ jsdemo  # open the website homepage in the default web browser
	@xdg-open website/index.html 2>/dev/null || open website/index.html 2>/dev/null || echo "Please open website/index.html in your browser"

screenshot: ⚙️ build  # capture TUI screenshot for agent frame inspection
	@timeout 10 go run ./scripts/screenshot/ zig-out/bin/emojig

termstate: ⚙️  # print active terminal mode snapshot (scroll region, mouse, raw mode, cursor)
	@sh scripts/termstate.sh

termstate-watch: ⚙️  # watch terminal modes live, refreshing every 2 s (Ctrl-C to stop)
	@sh scripts/termstate.sh --watch

WAYREEL      := $(HOME)/go/bin/wayreel
WAYREEL_FAST ?=

wayreel-install: ⚙️  # build and install wayreel from ../wayreel
	cd ../wayreel && go install .

record: ⚙️ wayreel-install  # record all three demos (tui-dark, tui-light, gui)
	WAYREEL_SPEC=spec/reels/tui-dark.json $(WAYREEL) -mode tui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))
	WAYREEL_SPEC=spec/reels/tui-light.json $(WAYREEL) -mode tui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))
	WAYREEL_SPEC=spec/reels/gui.json $(WAYREEL) -mode gui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))

record-tui: ⚙️ wayreel-install  # record TUI demo (dark theme)  [WAYREEL_FAST=2 for 2x speed]
	WAYREEL_SPEC=spec/reels/tui-dark.json $(WAYREEL) -mode tui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))

record-tui-light: ⚙️ wayreel-install  # record TUI demo (light theme)  [WAYREEL_FAST=2 for 2x speed]
	WAYREEL_SPEC=spec/reels/tui-light.json $(WAYREEL) -mode tui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))

record-gui: ⚙️ wayreel-install  # record GUI desktop scenario  [WAYREEL_FAST=2 for 2x speed]
	WAYREEL_SPEC=spec/reels/gui.json $(WAYREEL) -mode gui $(if $(WAYREEL_FAST),-fast $(WAYREEL_FAST))

ttylaunch: ⚙️ build  # launch kitty/ghostty/gnome-terminal/alacritty/ptyxis/xfce4-terminal/tilix with emojig TUI and benchmark memory
	@echo "Launching 8 terminal emulators with emojig TUI..."
	@kitty -d $$HOME \
	    -o initial_window_width=50c -o initial_window_height=20c \
	    -o confirm_os_window_close=0 \
	    zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5; killall kitty' &
	@ghostty --working-directory=$$HOME \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@gnome-terminal --working-directory=$$HOME --geometry=50x20 \
	    -- zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@alacritty --working-directory $$HOME \
	    -o 'window.dimensions.columns=50' -o 'window.dimensions.lines=20' \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@ptyxis -d $$HOME \
	    -- zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@foot -D $$HOME -W 50x20 \
	    zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@xfce4-terminal --default-working-directory=$$HOME --geometry=50x20 \
	    -x zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@tilix --working-directory=$$HOME --geometry=50x20 \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@crt --workdir $$HOME \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@echo "Waiting 3s for terminals to settle..."
	@sleep 3
	@go run ./scripts/tty_bench/

ttylaunch-borderless: ⚙️ build  # launch terminals in borderless mode with emojig TUI and benchmark memory
	@echo "Launching 8 terminal emulators in borderless mode with emojig TUI..."
	@kitty -d $$HOME \
	    -o initial_window_width=50c -o initial_window_height=20c \
	    -o confirm_os_window_close=0 \
	    -o hide_window_decorations=titlebar-only \
	    zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5; killall kitty' &
	@ghostty --working-directory=$$HOME \
	    --window-decoration=false \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@gnome-terminal --working-directory=$$HOME --geometry=50x20 \
	    -- zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@alacritty --working-directory $$HOME \
	    -o 'window.dimensions.columns=50' -o 'window.dimensions.lines=20' \
	    -o 'window.decorations=None' \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@ptyxis -d $$HOME \
	    -- zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@foot -D $$HOME -W 50x20 \
	    --override=csd.size=0 --override=csd.preferred=client --override=csd.border-width=1 \
	    zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@xfce4-terminal --default-working-directory=$$HOME --geometry=50x20 \
	    -x zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@tilix --working-directory=$$HOME --geometry=50x20 \
	    -e zsh -lc '$(CURDIR)/zig-out/bin/emojig --tui | cat; sleep 0.5' &
	@echo "Waiting 3s for terminals to settle..."
	@sleep 3
	@go run ./scripts/tty_bench/

pack: ⚙️  # compress and pack emoji database json into src/emojis.bin
	@go run ./scripts/pack_emojis/

reuse: ⚙️  # verify license compliance linting
	@reuse lint

deps: ⚙️  # install package manager and CLI binary tooling dependencies
	@sudo apt-get install -y foot minisign reuse
	@go install github.com/goreleaser/goreleaser/v2@latest
	@go install codeberg.org/forgejo-contrib/forgejo-cli@latest

test-minisign: ⚙️  # verify minisign signature keypair validity
	@printf 'emojig minisign test' > /tmp/emojig-minisign-test.txt
	@minisign -S -s "$(MINISIGN_KEY_FILE)" -m /tmp/emojig-minisign-test.txt
	@minisign -V -p minisign.pub -m /tmp/emojig-minisign-test.txt
	@rm -f /tmp/emojig-minisign-test.txt /tmp/emojig-minisign-test.txt.minisig
	@echo "✅ minisign keypair OK"

clean: ⚙️  # purge compile, release, and cache folders
	@rm -rf zig-out .zig-cache dist
	@echo "🧹 Cleaned build artifacts"

WORKTREE_DIR ?= ../emojig-$(NAME)
WORKTREE_BRANCH ?= $(NAME)

worktree: ⚙️  # create a sibling git worktree ready to build (usage: make worktree NAME=feature [WORKTREE_BRANCH=branch])
	test -n "$(NAME)"  # ensure NAME var is set, e.g. make worktree NAME=my-feature
	git worktree add -b $(WORKTREE_BRANCH) $(WORKTREE_DIR)
	@# data/ holds the raw emoji datasets; it is gitignored, so a fresh worktree
	@# lacks it. Link it so `make pack` works there too (builds/tests need only the
	@# tracked src/emojis.bin and work without this link).
	@test -d data && ln -sfn $(CURDIR)/data $(WORKTREE_DIR)/data && echo "🔗 linked data/ into worktree" || true
	@echo "✅ worktree ready at $(WORKTREE_DIR) on branch $(WORKTREE_BRANCH)"
	@echo "   cd $(WORKTREE_DIR) && zig build test"
	@echo "   remove later with: git worktree remove $(WORKTREE_DIR)"

uninstall: ⚙️  # remove binary, shell integration, and desktop entry
	@rm -f  ~/.local/bin/emojig
	@rm -rf ~/.local/share/emojig
	@rm -f  ~/.local/share/applications/emojig-picker.desktop
	@echo "✅ emojig uninstalled"

install: ⚙️  # install binary, shell integrations, and desktop launcher
	@zig build shell-install -Doptimize=ReleaseSmall >/dev/null || (zig build shell-install -Doptimize=ReleaseSmall && exit 1)
	@echo "✅ Emojig installed successfully!"
	@echo "   - Binary:   ~/.local/bin/emojig"
	@echo "   - Shells:   ~/.local/share/emojig/shell/emojig.{bash,zsh,fish}"
	@echo "   - Launcher: ~/.local/share/applications/emojig-picker.desktop"

SSH_ARCH ?= aarch64-linux-musl

install-ssh: ⚙️  # install to remote host via SSH (usage: make install-ssh HOST=hostname [SSH_ARCH=aarch64-linux-musl])
	zig build -Doptimize=ReleaseSmall -Dtarget=$(SSH_ARCH)
	test -n "$(HOST)"  # ensure HOST var is set
	ssh $(HOST) 'mkdir -p ~/.local/bin'
	scp zig-out/bin/emojig $(HOST):~/.local/bin/emojig
	@echo "✅ emojig copied to $(HOST):~/.local/bin/emojig"

install-verbose: ⚙️  # install with verbose compilation output
	zig build shell-install -Doptimize=ReleaseSmall

preflight: ⚙️  # run license check, unit tests, and code formatting lint
	reuse lint
	zig build test
	zig fmt --check src/
	go vet ./...
	go test ./...
	@echo "✅ preflight OK"

export MINISIGN_KEY_FILE ?= $(HOME)/.minisign/minisign.key

release-build: ⚙️  # build release binaries locally using GoReleaser
	goreleaser release --clean --skip=publish --skip=sign
	cp dist/emojig-linux_x86_64-linux-musl/emojig dist/emojig-x86_64-linux-musl
	cp dist/emojig-linux_aarch64-linux-musl/emojig dist/emojig-aarch64-linux-musl
	@echo "✅ binaries built and copied to dist/ root"

release-snapshot: ⚙️  # build local snapshot release artifacts (no tag, no publish, no sign)
	goreleaser release --snapshot --clean --skip=sign

_dist_files = $(wildcard \
	dist/*.tar.gz dist/*.deb dist/*.rpm \
	dist/SHA256SUMS dist/SHA256SUMS.minisig \
	dist/emojig-x86_64-linux-musl \
	dist/emojig-aarch64-linux-musl)

_url_latest = https://codeberg.org/api/v1/repos/ubunatic/emojig/releases/latest
_url_tags = https://codeberg.org/api/v1/repos/ubunatic/emojig/tags

VERSION_PUBLISHED = $(shell \
	curl -sSfL $(_url_latest) | \
	grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4 || \
	echo "(failed to fetch latest release)" >/dev/stderr)

VERSION_TAGGED = $(shell \
	curl -sSfL $(_url_tags) | \
	grep -o '"name":"[^"]*"' | head -n 1 | cut -d'"' -f4 || \
	echo "(failed to fetch latest tag)" >/dev/stderr)

info: ⚙️  # show detailed info about release files and related vars
	# VERSION: $(VERSION)
	# VERSION_PUBLISHED (latest public release): $(VERSION_PUBLISHED)
	# VERSION_TAGGED (latest tag / draft): $(VERSION_TAGGED)
	# codeberg release page: https://codeberg.org/ubunatic/emojig/releases
	# latest release API url: $(_url_latest)
	# latest tag API url: $(_url_tags)
	# MINISIGN_KEY_FILE: $(MINISIGN_KEY_FILE)
	# MAKE: $(MAKE)
	# _dist_files: $(_dist_files)
	# git status:
	@git status --short | sed 's/^/#  /g'
	# git diff:
	@git diff --numstat | sed 's/^/#   /g'

release-diff: ⚙️  # show a git summary of changes since the last published release
	@VERSION_PUBLISHED="$(VERSION_PUBLISHED)" go run ./scripts/release_diff/

release-publish: release-build ⚙️  # sign SHA256SUMS and publish draft release to Codeberg
	minisign -S -s "$${MINISIGN_KEY_FILE:-$$HOME/.minisign/minisign.key}" -m dist/SHA256SUMS -t "emojig v$(VERSION)"
	@echo "✅ SHA256SUMS signed"
	fj release create "emojig v$(VERSION)" --tag "v$(VERSION)" --draft $(addprefix --attach ,$(_dist_files))
	@echo "✅ dist/ files published for version $(VERSION)"
	@echo
	@echo "Visit https://codeberg.org/ubunatic/emojig/releases to manage releases."

release: preflight ⚙️  # interactive fully automated release flow (commit, tag, push, build, sign, and publish draft)
	@echo "==============================================="
	@echo "Ready to release Emojig v$(VERSION)"
	@echo "==============================================="
	@echo "The release process will:"
	@echo " 1. Commit and tag the release locally as v$(VERSION)"
	@echo " 2. Push main branch and the v$(VERSION) tag to Codeberg"
	@echo " 3. Build, sign, and create a draft release on Codeberg"
	@echo "==============================================="
	@printf "Do you want to proceed with this release? (y/N) "; read confirm && \
	if test "$$confirm" = "y" || test "$$confirm" = "Y"; \
	then $(MAKE) release-full; \
	else echo "Release aborted."; exit 1; \
	fi

release-full: ⚙️  # tag, push, build, and publish release
	@$(MAKE) tag  # commit and tag
	git push origin main --tags  # push code and tag for $(VERSION)
	@$(MAKE) release-publish  # build, sign, and publish

bump-patch: ⚙️  # bump patch version in build.zig.zon
	@go run ./scripts/bump_version/ patch

bump-minor: ⚙️  # bump minor version in build.zig.zon
	@go run ./scripts/bump_version/ minor

bump-major: ⚙️  # bump major version in build.zig.zon
	@go run ./scripts/bump_version/ major

tag: ⚙️  # commit version/changelog changes and tag the release
	git commit -am "release: v$(VERSION)" --allow-empty
	git tag -a v$(VERSION) -m "emojig v$(VERSION)"
	@echo "✅ Committed and tagged v$(VERSION)"
