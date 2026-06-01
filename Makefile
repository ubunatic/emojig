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

tui: ⚙️  # run TUI mode in the current terminal
	zig build tui

gui: ⚙️  # launch the floating terminal picker window (requires foot)
	zig build gui

screenshot: ⚙️ build  # capture TUI screenshot for agent frame inspection
	@timeout 10 go run scripts/screenshot.go zig-out/bin/emojig

pack: ⚙️  # compress and pack emoji database json into src/emojis.bin
	@go run scripts/pack_emojis.go

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

install: ⚙️  # silent install for testing during development
	@zig build shell-install -Doptimize=ReleaseSmall >/dev/null && echo "✅ emojig installed" || \
	 zig build shell-install -Doptimize=ReleaseSmall  # fallback to non-silent on error

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
	@$(MAKE) tag
	git push origin main --tags
	@$(MAKE) release-publish

bump-patch: ⚙️  # bump patch version in build.zig.zon
	@go run scripts/bump_version.go patch

bump-minor: ⚙️  # bump minor version in build.zig.zon
	@go run scripts/bump_version.go minor

bump-major: ⚙️  # bump major version in build.zig.zon
	@go run scripts/bump_version.go major

tag: ⚙️  # commit version/changelog changes and tag the release
	git commit -am "release: v$(VERSION)" --allow-empty
	git tag -a v$(VERSION) -m "emojig v$(VERSION)"
	@echo "✅ Committed and tagged v$(VERSION)"

