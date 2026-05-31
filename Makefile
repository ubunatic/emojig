.PHONY: ⚙️  # make all targets phony

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker screenshot test pack: build ⚙️
	zig build $@

reuse: ⚙️
	reuse lint

tui: build ⚙️
	./zig-out/bin/emojig --tui

gui: build ⚙️
	./zig-out/bin/emojig --gui

install: build ⚙️
	cp zig-out/bin/emojig ~/.local/bin/emojig

clean: ⚙️
	rm -rf zig-out .zig-cache
