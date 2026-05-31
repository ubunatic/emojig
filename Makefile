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

install-verbose: ⚙️
	zig build shell-install

preflight: ⚙️
	reuse lint
	zig build test
	zig fmt --check src/

release-fj: ⚙️
	MINISIGN_KEY_FILE=~/.minisign/minisign.key goreleaser release --clean --skip=publish
	fj release create "emojig v$(VERSION)" --tag "v$(VERSION)" --draft \
	  $(addprefix --attach ,$(wildcard dist/*.tar.gz dist/*.deb dist/*.rpm dist/SHA256SUMS dist/SHA256SUMS.minisig))

