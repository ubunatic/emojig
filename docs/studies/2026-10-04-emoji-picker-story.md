<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# A tiny emoji picker with a surprisingly large surface area

An emoji picker sounds like a small interface problem: show a grid, let someone search, copy a character. On Linux, the details quickly multiply. The same picker should fit into an existing terminal session or appear as a desktop popup; render wide emoji consistently; leave raw terminal settings intact after a crash; and work across terminals with different window and font behavior. Emojig takes that on as a standalone Linux utility, without a background daemon.

Its runtime is Zig 0.16, while Go handles the emoji database packer and much of the test and build tooling. The emoji data is packed ahead of time and embedded into the executable, so searches do not need to parse a database from disk. The app offers an inline terminal interface and a GUI mode that launches a terminal window. It detects Wayland or X11 sessions, supports several terminal emulators, and can copy selections through available clipboard tools. Its browser demo is a separate JavaScript simulator generated from the same search specifications.

The interesting work is often at the boundary between those pieces. On September 14, 2026, a website search bug showed why shared product behavior still needs explicit parity checks. Emojig had added superscript digits to its box-art data, but the native app classified box art by Unicode ranges and deliberately excluded those digits. The website generator instead derived ranges from the data entries, so the `b:` filter and ordinary search ranking disagreed with the native app. The fix exported the same classification bands as Zig and added JavaScript regression checks for both superscripts and actual box-art glyphs. The regression checks run through Go tests, which also track the JavaScript inputs in their cache. Commits `96e62ec`, `658cb7e`, and `2ffabfc` document the fix, test integration, and follow-up documentation.

A different kind of boundary appeared in a September 19 flicker fix. Fast redraws could expose partially written terminal frames. The implementation switched frame presentation to synchronized terminal output, using mode 2026, so the terminal presents each frame atomically. The issue record explicitly deferred removing the preceding clear; the change solved the immediate presentation problem without claiming that every redraw optimization was complete (`d24100f`, issue 016).

These episodes sit inside a workflow that makes problems traceable. The repository has 72 numbered issue records, 30 marked closed in its index, and documents for issue lifecycle, agentic loop practices, and agentic workflow learnings. The docs describe ticket-based work, verification before closure, review stages, and capturing technical lessons. The recent six-week history contains 25 commits, including a September 14 v0.2.2 release and fixes for startup focus reporting and dynamically loaded Wayland function pointers. The project’s current tests include 13 Go test functions and 137 Zig test blocks by a simple source count; those counts do not imply equal test weight or coverage.

This is a useful example of what agentic development can contribute: not a claim that one feature would be impossible for one developer, but capacity to keep many kinds of work connected. The codebase combines a low-level terminal runtime, data generation, multi-terminal integration, a browser simulator, and focused regression checks. Agents can help investigate one seam, implement a bounded fix, and review evidence while the issue tracker preserves the reasoning. The hard part remains deciding what counts as the same behavior across platforms and proving it with the right test. The superscript bug was caught precisely because those two implementations were compared rather than assumed equivalent.

## Facts

| Item | Verified fact |
|---|---|
| Stack | Zig 0.16 runtime; Go tooling and tests; YAML specs; JavaScript browser simulator |
| Platform | Linux; terminal UI plus desktop popup through Wayland/X11 terminal emulators |
| Database | 2,249 embedded emojis, as stated by the project README |
| Activity | 25 commits in the six weeks before 2026-10-04; latest listed commit 2026-09-19 |
| Releases | v0.2.1 and v0.2.2 release bumps dated 2026-09-14 |
| Tests and issues | 13 Go test functions, 137 Zig test blocks, 72 issue records (source/index counts) |
