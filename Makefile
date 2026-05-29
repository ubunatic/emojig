.PHONY: ⚙️  # make all targets phony

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker test pack: ⚙️
	zig build $@

clean: ⚙️
	rm -rf zig-out .zig-cache
