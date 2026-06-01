.PHONY: ⚙️  # make all targets phony

VERSION = $(shell grep '\.version' build.zig.zon | grep -o '[0-9][0-9.]*')

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker screenshot pack test tui gui reuse deps test-minisign release clean: ⚙️
	zig build $@

install: ⚙️  # silent install for testing during development
	@zig build shell-install >/dev/null && echo "✅ emojig installed" || \
	 zig build shell-install  # fallback to non-silent on error

SSH_ARCH ?= aarch64-linux-musl

install-ssh: ⚙️  # install to remote host via SSH (usage: make install-ssh HOST=hostname [SSH_ARCH=aarch64-linux-musl])
	zig build -Doptimize=ReleaseSmall -Dtarget=$(SSH_ARCH)
	ssh $(HOST) 'mkdir -p ~/.local/bin'
	scp zig-out/bin/emojig $(HOST):~/.local/bin/emojig

install-verbose: ⚙️
	zig build shell-install

preflight: ⚙️
	reuse lint
	zig build test
	zig fmt --check src/

release-build: ⚙️
	MINISIGN_KEY_FILE=~/.minisign/minisign.key goreleaser release --clean --skip=publish --skip=sign
	cp dist/emojig-linux_x86_64-linux-musl/emojig dist/emojig-x86_64-linux-musl
	cp dist/emojig-linux_aarch64-linux-musl/emojig dist/emojig-aarch64-linux-musl

release-publish: release-build ⚙️
	minisign -S -s "$${MINISIGN_KEY_FILE:-$$HOME/.minisign/minisign.key}" -m dist/SHA256SUMS -t "emojig v$(VERSION)"
	fj release create "emojig v$(VERSION)" --tag "v$(VERSION)" --draft \
	  $(addprefix --attach ,$(wildcard dist/*.tar.gz dist/*.deb dist/*.rpm dist/SHA256SUMS dist/SHA256SUMS.minisig dist/emojig-x86_64-linux-musl dist/emojig-aarch64-linux-musl))

bump-patch: ⚙️  # bump patch version in build.zig.zon
	@go run scripts/bump_version.go patch

bump-minor: ⚙️  # bump minor version in build.zig.zon
	@go run scripts/bump_version.go minor

bump-major: ⚙️  # bump major version in build.zig.zon
	@go run scripts/bump_version.go major

tag: ⚙️  # commit version/changelog changes and tag the release
	git commit -am "release: v$(VERSION)"
	git tag -a v$(VERSION) -m "emojig v$(VERSION)"
	@echo "✅ Committed and tagged v$(VERSION)"


