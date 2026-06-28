.PHONY: ⚙️  # make all targets phony

SHELL = bash
VERSION = $(shell grep '\.version' build.zig.zon | grep -o '[0-9][0-9.]*')

export WAYREEL_FAST ?= 3
export GOCACHE ?= /tmp/emojig-gocache
export ZIG_GLOBAL_CACHE_DIR ?= /tmp/emojig-zig-global
export ZIG_LOCAL_CACHE_DIR ?= /tmp/emojig-zig-local

# `make install` defaults to a fast dev build: ReleaseFast without LLVM's
# optimizer (zig's self-hosted backend), since LLVM codegen — not linking —
# is what makes ReleaseSmall installs slow. Runtime speed is unaffected
# (self-hosted ReleaseFast matches LLVM ReleaseFast in benchmarks); only the
# binary is bigger (~6MB stripped vs ~700KB). Use `make install-small` for
# the smallest possible local binary, e.g. to sanity-check before a release.
OPTIMIZE ?= ReleaseFast
LLVM ?= false

help: ⚙️
	@printf "Emojig Makefile Targets:\n\n"
	@awk -F':.*# ' '/^[a-zA-Z0-9_-]+:.*# / { printf "  %-18s %s\n", $$1, $$2 }' Makefile

status: ⚙️  # show open issues, recent commits, and working-tree state
	@go run ./scripts/status/

zig-help: ⚙️  # show zig build targets
	zig build --list-steps
	@echo
	@echo "ℹ️ 'zig build <step>' is used internally to manage building and testing."
	@echo "   Most zig build steps have a convenience Makefile target (see 'make help')."

build: gen-spec ⚙️  # compile the application (OPTIMIZE=ReleaseFast, LLVM=false by default)
	zig build -Doptimize=$(OPTIMIZE) -Dllvm=$(LLVM)

run: gen-spec ⚙️  # run the inline TUI picker in current terminal
	zig build run

picker: gen-spec ⚙️  # launch the emoji picker in a floating foot window (non-blocking)
	zig build picker

export EDITOR ?= nvim
ED_TUI  := $(EDITOR)
ED_GUI  := nvim-qt
ED_FILE := Makefile

edit: ⚙️  # edit ED_FILE in terminal or desktop editor
	($(ED_TUI) "$(ED_FILE)" || setsid $(ED_GUI) "$(ED_FILE)" >/dev/null 2>&1)

watch: ⚙️  # watch ED_FILE for changes and recompile
	@scripts/watch.sh $(ED_FILE)

watch-run: ⚙️  # watch source and spec files, and run the gui app afterwards
	@scripts/watch_run.sh

edit-strings: ⚙️  # open spec/strings/en.yaml in nvim-qt for editing
	($(ED_TUI) "spec/strings/en.yaml" || setsid $(ED_GUI) "spec/strings/en.yaml" >/dev/null 2>&1)
edit-art:     ⚙️  # open spec/art.yaml in nvim-qt, then recompile and rebuild on save
	($(ED_TUI) "spec/art.yaml" || setsid $(ED_GUI) "spec/art.yaml" >/dev/null 2>&1)
edit-strings-%:
	($(ED_TUI) "spec/strings/$*.yaml" || setsid $(ED_GUI) "spec/strings/$*.yaml" >/dev/null 2>&1)
edit-%:
	($(ED_TUI) "spec/$*.yaml" || setsid $(ED_GUI) "spec/$*.yaml" >/dev/null 2>&1)

edit-input: ⚙️  # open spec/input.yaml in nvim-qt for editing
	($(ED_TUI) "spec/input.yaml" || setsid $(ED_GUI) "spec/input.yaml" >/dev/null 2>&1)

watch-strings: ⚙️
	@scripts/watch.sh spec/strings/en.yaml
watch-art:     ⚙️
	@scripts/watch.sh spec/art.yaml
watch-strings-%:
	@scripts/watch.sh spec/strings/$*.yaml
watch-%:
	@scripts/watch.sh spec/$*.yaml

watch-input: ⚙️  # watch spec/input.yaml and regenerate the embedded input spec
	@scripts/watch.sh spec/input.yaml

gen-spec: ⚙️  # compile YAML spec sources to generated JSON artifacts
	go run ./scripts/convert_spec/ spec/layout.yaml spec/layout.json
	go run ./scripts/convert_spec/ spec/theme.yaml spec/theme.json
	go run ./scripts/convert_spec/ spec/keys.yaml spec/keys.json
	go run ./scripts/convert_spec/ spec/commands.yaml spec/commands.json
	go run ./scripts/convert_spec/ spec/settings.yaml spec/settings.json
	go run ./scripts/convert_spec/ spec/categories.yaml spec/categories.json
	go run ./scripts/convert_spec/ spec/styles.yaml spec/styles.json
	go run ./scripts/convert_spec/ spec/art.yaml spec/art.json
	go run ./scripts/convert_spec/ spec/boxart.yaml spec/boxart.json
	go run ./scripts/convert_spec/ spec/braille.yaml spec/braille.json
	go run ./scripts/convert_spec/ spec/synonyms.yaml spec/synonyms.json
	go run ./scripts/convert_spec/ spec/jsdemo.yaml spec/jsdemo.json
	go run ./scripts/convert_spec/ spec/crt-theme.yaml spec/crt-theme.json
	go run ./scripts/convert_spec/ spec/strings/en.yaml spec/strings.json
	go run ./scripts/convert_spec/ spec/strings/de.yaml spec/strings_de.json
	go run ./scripts/convert_spec/ spec/strings/es.yaml spec/strings_es.json
	go run ./scripts/convert_spec/ spec/strings/fr.yaml spec/strings_fr.json
	go run ./scripts/convert_spec/ spec/strings/it.yaml spec/strings_it.json
	go run ./scripts/convert_spec/ spec/strings/nl.yaml spec/strings_nl.json
	go run ./scripts/convert_spec/ spec/strings/pl.yaml spec/strings_pl.json
	go run ./scripts/convert_spec/ spec/strings/pt.yaml spec/strings_pt.json
	go run ./scripts/convert_spec/ spec/strings/ru.yaml spec/strings_ru.json
	go run ./scripts/convert_spec/ spec/strings/tr.yaml spec/strings_tr.json
	go run ./scripts/convert_spec/ spec/strings/uk.yaml spec/strings_uk.json
	go run ./scripts/gen_input_spec/
	go run ./scripts/gen_about_art/

gen-art: gen-spec ⚙️  # compile spec/art.json → spec/art.generated.json
	@true

gen-input: ⚙️  # compile spec/input.yaml → spec/input.generated.json
	go run ./scripts/gen_input_spec/

gen-colors: ⚙️  # regenerate spec/colors.json (full xterm-256 palette)
	go run ./scripts/gen_colors/ > spec/colors.json

test: gen-spec ⚙️  # run the unit tests
	zig build test
	go vet ./...
	go test ./...

bench: gen-spec ⚙️  # run search benchmarks comparing debug vs release (5 s per query)
	EMOJIG_BENCH=5000 zig build test
	EMOJIG_BENCH=5000 zig build test -Doptimize=ReleaseFast

tui: gen-spec ⚙️  # run TUI mode (stdout path: prints selected emoji to terminal)
	zig build && zig-out/bin/emojig --tui | cat

tui-rust: ⚙️  # run Rust TUI demo in the current terminal
	cargo run --bin inline-demo -- --height 10

gui: gen-spec ⚙️  # launch the floating terminal picker window (requires foot)
	zig build gui

gui-watch: ⚙️  # tail /tmp/emojig.log live while using the gui picker
	tail -f /tmp/emojig.log

gtkdemo: ⚙️  # open GTK4 text field to explore the built-in emoji picker (Ctrl+.)
	python3 explore_gtk_emoji.py

jsdemo: gen-spec ⚙️  # regenerate website/jsdemo.js from spec/jsdemo.yaml
	@printf '// generated from spec/jsdemo.json — do not edit by hand\nconst jsdemoSpec = %s;\n' "$$(cat spec/jsdemo.json)" > website/jsdemo.js

browse: ⚙️ jsdemo  # open the website homepage in the default web browser
	@xdg-open website/index.html 2>/dev/null || open website/index.html 2>/dev/null || echo "Please open website/index.html in your browser"

screenshot: gen-spec build  # capture TUI screenshot for agent frame inspection
	@timeout 10 go run ./scripts/screenshot/ zig-out/bin/emojig

termstate: ⚙️  # print active terminal mode snapshot (scroll region, mouse, raw mode, cursor)
	@sh scripts/termstate.sh

termstate-watch: ⚙️  # watch terminal modes live, refreshing every 2 s (Ctrl-C to stop)
	@sh scripts/termstate.sh --watch

WAYREEL      := $(HOME)/go/bin/wayreel

wayreel-install: ⚙️  # build and install wayreel from ../wayreel
	cd ../wayreel && go install .

record: ⚙️ wayreel-install  # record all three demos (tui-dark, tui-light, gui)
	$(WAYREEL) record spec/reels/tui-dark.json
	$(WAYREEL) record spec/reels/tui-light.json
	$(WAYREEL) record spec/reels/gui.json
	open website

record-dark: ⚙️ wayreel-install  # record TUI demo (dark theme)
	$(WAYREEL) record spec/reels/tui-dark.json
	open website/emojig-tui-dark.webm

record-light: ⚙️ wayreel-install  # record TUI demo (light theme)
	$(WAYREEL) record spec/reels/tui-light.json
	open website/emojig-tui-light.webm

record-gui: ⚙️ wayreel-install  # record GUI desktop scenario
	$(WAYREEL) record spec/reels/gui.json
	open website/emojig-gui-light.webm

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

pack: gen-spec ⚙️  # compress and pack emoji database json into src/emojis.bin
	@go run ./scripts/pack_emojis/

reuse: ⚙️  # verify license compliance linting
	@reuse --no-multiprocessing lint

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

install-debug: ⚙️  # install with a debug build (slowest binary, safety checks on)
	@$(MAKE) install OPTIMIZE=Debug

install-small: ⚙️  # install the smallest possible binary (LLVM ReleaseSmall, slow build) — use before releases
	@$(MAKE) install OPTIMIZE=ReleaseSmall LLVM=true

install: ⚙️  # install binary, shell integrations, and desktop launcher (fast build, default)
	@$(MAKE) gen-spec >/dev/null
	@zig build shell-install -Doptimize=$(OPTIMIZE) -Dllvm=$(LLVM) >/dev/null || (zig build shell-install -Doptimize=$(OPTIMIZE) -Dllvm=$(LLVM) && exit 1)
	@echo "✅ Emojig installed successfully!"
	@echo "   - Binary:    ~/.local/bin/emojig"
	@echo "   - Shells:    ~/.local/share/emojig/shell/emojig.{bash,zsh,fish}"
	@echo "   - Launcher:  ~/.local/share/applications/emojig-picker.desktop"

SSH_ARCH ?= aarch64-linux-musl

update: ⚙️  # update emojig from source: git pull + rebuild + reinstall
	@git pull 2>/dev/null && echo "✅ pulled changes" || echo "⚠️ ignoring failed pull"
	$(MAKE) install

install-ssh: ⚙️  # install to remote host via SSH (usage: make install-ssh HOST=hostname [SSH_ARCH=aarch64-linux-musl])
	@$(MAKE) gen-spec >/dev/null
	zig build -Doptimize=ReleaseSmall -Dtarget=$(SSH_ARCH)
	test -n "$(HOST)"  # ensure HOST var is set
	ssh $(HOST) 'mkdir -p ~/.local/bin'
	scp zig-out/bin/emojig $(HOST):~/.local/bin/emojig
	@echo "✅ emojig copied to $(HOST):~/.local/bin/emojig"

install-verbose: gen-spec ⚙️  # install with verbose compilation output
	zig build shell-install -Doptimize=ReleaseSmall

preflight: gen-spec ⚙️  # run license check, unit tests, and code formatting lint
	reuse --no-multiprocessing lint
	zig build test
	@echo "Note: 'failed command' message above is OK (Zig test runner info, all tests pass)"
	zig fmt --check src/
	go vet ./...
	go test ./...
	@echo "✅ preflight OK"

export MINISIGN_KEY_FILE ?= $(HOME)/.minisign/minisign.key

release-build: gen-spec ⚙️  # build release binaries locally using GoReleaser
	goreleaser release --clean --skip=publish --skip=sign
	cp dist/emojig-linux_x86_64-linux-musl/emojig dist/emojig-x86_64-linux-musl
	cp dist/emojig-linux_aarch64-linux-musl/emojig dist/emojig-aarch64-linux-musl
	@echo "✅ binaries built and copied to dist/ root"

release-snapshot: gen-spec ⚙️  # build local snapshot release artifacts (no tag, no publish, no sign)
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
