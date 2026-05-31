.PHONY: ⚙️  # make all targets phony

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker screenshot pack test tui gui reuse deps test-minisign release clean: ⚙️
	zig build $@

install: ⚙️  # silent install for testing during development
	@zig build shell-install >/dev/null && echo "✅ emojig installed" || \
	 zig build shell-install  # fallback to non-silent on error

