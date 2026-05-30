.PHONY: ⚙️  # make all targets phony

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker screenshot test pack: ⚙️
	zig build $@

reuse: ⚙️
	reuse lint

tui: ⚙️
	./zig-out/bin/emojig --tui

gui: ⚙️
	./zig-out/bin/emojig --gui

clean: ⚙️
	rm -rf zig-out .zig-cache
