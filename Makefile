.PHONY: ⚙️

help: ⚙️
	@zig build --list-steps

build: ⚙️
	zig build -Doptimize=ReleaseSmall

run picker test: ⚙️
	zig build $@

clean: ⚙️
	rm -rf zig-out .zig-cache

pack: ⚙️  ## packs ...
	go run scripts/pack_emojis.go
