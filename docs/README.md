<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Emojig Project Documentation

This directory contains the evergreen documentation for the **Emojig** zero-allocation GUI/TUI emoji picker. These documents record design philosophy, architecture, implementation guides, and language-specific conventions.

---

## 📖 Core Architecture & Design

* [**Why & Niche**](WhyAndNiche.md): Rationale behind Emojig's existence, target audience, design philosophy, and standalone architecture constraints (no background daemon/IPC).
* [**Search Engine**](SearchEngine.md): Inner workings of the subsequence scoring, plural/stem fallbacks, query stems, tag tradeoffs, and the box art filter.
* [**Spec-Driven Config**](SpecDrivenConfig.md): Structure and code generation from specification files (`colors.json`, `layout.json`, `strings.json`, etc.) to control application appearance.
* [**Terminal Integration**](TerminalIntegration.md): Detection and communication mechanisms with graphical terminals (e.g. `foot`, `kitty`, `alacritty`), spawning configurations, and the Twemoji CBDT color-emoji font requirement for `foot`.
* [**Terminal State & Restoration**](TerminalRestore.md): Mechanisms for raw mode activation, mouse tracking, signal trapping, and standard termios restoration.
* [**Environment Detection**](EnvironmentDetection.md): What environment is actually present in the two real launch paths (raw desktop-shell spawn vs. run inside an already-open terminal) vs. what the source reads at each decision point, source-line by source-line. Read before touching mode/theme/terminal auto-detection.
* [**Spec System**](Spec.md): Why `spec/*.yaml` is the single source of truth for application behavior, generated into `spec/.gen/` — the general convention `Spec-Driven Config` below applies specifically to colors/layout.

## 🛠️ Components & Features

* [**Advanced Usage & CLI**](Advanced.md): Command-line arguments, environment variable overrides, layout, theme settings, and window integration.
* [**Inline Height Mode**](MojigoInlineHeight.md): Details of the inline-TUI (`--height`) layout rendering directly in `/dev/tty`.
* [**Skim Inline TUI**](SkimInlineTui.md): Analysis of the `skim` tool's inline TUI mechanics which inspired Emojig.
* [**Simple List Mode**](SimpleListMode.md): Design notes on displaying a clean, single-column scrollable layout.
* [**Alias Strategy**](AliasStrategy.md): Commands alias and shell execution helpers.
* [**Half-Block Pixel Art**](HalfBlockPixelArt.md): Spec and mechanics for drawing block art logos and graphics inside the terminal.
* [**Key Dispatch**](KeyDispatch.md): Handling and mapping of keyboard input events and ANSI sequences in the interactive loop.

## 💻 Developer & Language Conventions

* [**Agentic Workflows**](AgenticWorkflows.md): Coding guidelines, prompt limits, automated workflows, and workspace conventions for coding agents.
* [**Zig API Pitfalls**](Zig.md): Non-obvious Zig 0.16 API shapes for pipes, subprocess spawning, file descriptors, and common type-resolution errors. Read before writing any fd/process code.
* [**Bash Style Guide**](Bash.md): Code conventions and formatting rules for POSIX/Bash scripts.
* [**Build Speed**](BuildSpeed.md): Compilation caching and incremental compiler performance adjustments.
* [**Go Scripts**](GoScripts.md) & [**Go Language**](Go.md): Standalone script style, standard library constraints, and Go environment conventions.
* [**Rust Guide**](Rust.md): Standards for Rust-based system utilities.
* [**Make Guide**](Make.md): Custom build tasks and target specifications in the `Makefile`.
* [**Git Conventions**](Git.md): Conventional commits, default-branch workflow, and push-on-request policy.
* [**Markdown Style**](Markdown.md): PascalCase for evergreen docs, kebab-case for ephemeral ones, and general formatting conventions.
* [**Worktrees**](Worktrees.md): Using git worktrees for isolated parallel task workspaces.
* [**Web Sandbox**](WebSandbox.md): Sandbox configurations and security restrictions for browser-based components.
* [**Website**](Website.md): Structure, static assets, and build setup for Emojig's website.

## 🧪 Testing & Diagnostics

* [**Canary-First Development**](Canary.md): The isolate-observe-document-then-build pattern for validating an external mechanism before writing feature code on top of it.
* [**Headless Recording**](HeadlessRecording.md): Setting up headless PTY recording via `wf-recorder` or `x11grab` for visual verification and testing; wayreel `crop_colors` pixel-coverage verification; GTK3-vs-GTK4 headless isolation gotcha.
* [**Emoji Width Research**](EmojiWidthResearch.md): Survey of how other terminals/TUIs/width libraries handle emoji-width determinism, the `disable_zwj` VTE workaround, and follow-on source-inspection findings from the sibling `../fontwidth` project (a proposed fourth robustness tier, a corrected stale claim about kitty's clustering behavior).
* [**Canary Tooling Design**](CanaryToolingDesign.md): Retrospective on the font-width canaries' iterative build (why it felt like circling), the since-superseded declarative pixel/measurement-spec proposal, and an epilogue on the completed migration to `../fontwidth` and the findings now flowing back from it.
