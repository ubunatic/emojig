.PHONY: help build run picker test clean pack

help:
	@zig build --list-steps

build:
	zig build -Doptimize=ReleaseSmall

run:
	zig build run

picker:
	zig build picker

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache

pack:
	go run scripts/pack_emojis.go
