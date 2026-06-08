<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [InlineTuiGuide.md](file:///home/uwe/projects/emojig/docs/InlineTuiGuide.md)
> - **Extra Content Covered Here:** Architectural plan for fuzzy search optimizations, ZWJ sequences support, and scroll restoration patterns.
> - **Outdated Information:** None.

---


# Search & Layout Enhancements for Quasi-Emojis

This document outlines the design considerations, implementations, and key learning points from expanding Emojig to support quasi-emoji characters (arrows, symbols, checkmarks, etc.) and optimizing its search ranking and terminal layout alignment.

---

## 1. Database Expansion (Quasi-Emojis)

While standard emoji pickers focus strictly on full-color Unicode emoji glyphs (which usually require Variation Selector 16 or are in the emoji-specific blocks), developers and writers frequently need quick access to common text-based symbols.

We expanded [data/emoji.json](file:///home/uwe/projects/emojig/data/emoji.json) with **106 quasi-emoji symbols**, categorized under a new `"Quasi-Emoji"` group:
*   **Arrows**: `←`, `↑`, `↓`, `→`, `↔`, `↕`, `↖`, `↗`, `↘`, `↙`, `↩`, `↪`, `↻`, `↺`, `⇄`, `⇅`, `⇌`, `⇒`, `⇐`, `⇔`, `➔`, `➜`
*   **Checkmarks & Stars**: `✓`, `✔`, `✗`, `✘`, `✖`, `★`, `☆`, `✦`, `✧`
*   **Card Suits**: `♥`, `♦`, `♣`, `♠`, `♡`, `♢`, `♧`, `♤`
*   **Music Notes**: `♪`, `♫`, `♬`, `♩`, `♭`, `♮`, `♯`
*   **Math Operators**: `∞`, `π`, `∑`, `∏`, `√`, `∆`, `≈`, `≠`, `≤`, `≥`, `±`, `÷`, `×`, `°`
*   **Technical & Marks**: `§`, `¶`, `†`, `‡`, `•`, `™`, `®`, `©`
*   **Chess Pieces**: `♔`, `♕`, `♖`, `♗`, `♘`, `♙`, `♚`, `♛`, `♜`, `♝`, `♞`, `♟`
*   **Dice Faces**: `⚀`, `⚁`, `⚂`, `⚃`, `⚄`, `⚅`
*   **Currency**: `$`, `€`, `£`, `¥`, `¢`, `₽`, `₹`, `₩`, `₪`, `₿`, `¤`
*   **Greek Letters**: `α`, `β`, `γ`, `λ`, `θ`, `μ`, `ω`, `Δ`, `Ω`

The binary database [src/emojis.bin](file:///home/uwe/projects/emojig/src/emojis.bin) remains extremely compact at **89.66 KB**, loaded entirely at compile-time with zero heap allocation overhead.

---

## 2. Terminal Layout Alignment (Visual Width)

### The Problem
Emojig's borderless 2D grid relies on a strictly aligned column system. Standard emojis render as **double-width** (2 columns wide) in terminal emulators. Therefore, the visual layout logic was hardcoded to assume each cell was exactly 4 columns wide:
*   **Unselected**: ` emoji ` (space, 2-col emoji, space) = 4 columns.
*   **Selected**: `[emoji]` (bracket, 2-col emoji, bracket) = 4 columns.

When we introduced quasi-emoji symbols (e.g. `←` or `✓`), which have a visual width of **1 column** in standard terminals, the visual spacing collapsed to 3 columns, causing subsequent grid cells to shift left and skewing the entire grid.

### The Solution
We implemented a zero-allocation UTF-8 character width checker `getEmojiWidth` in [src/root.zig](file:///home/uwe/projects/emojig/src/root.zig):
1.  If the string contains the **Variation Selector 16** (`\xef\xb8\x8f`), it is rendered as a double-width emoji.
2.  If the first codepoint is standard ASCII, arrows, math, chess, CJK punctuation/enclosed symbols, or other BMP-based text symbols, it is classified as **single-width** (1).
3.  Otherwise, standard emojis (starting at `U+1F000` or specific BMP emojis like `☕`, `⚡`, `✅`) default to **double-width** (2).

Using this classification, the terminal drawer in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) dynamically pads cells featuring single-width characters to preserve the 4-column visual cell size:
*   **Unselected (Single-Width)**: ` arrow  ` (space, 1-col arrow, two spaces) = 4 columns.
*   **Selected (Single-Width)**: `[arrow ]` (bracket, 1-col arrow, space, bracket) = 4 columns.

---

## 3. Search Engine Ranking Optimizations

To deliver a high-quality ranking experience, we adopted two major heuristics in [src/root.zig](file:///home/uwe/projects/emojig/src/root.zig):

### A. Exact Word Match Bonus
A common limitation of subsequence fuzzy matching is that it ranks sparse substring matches similarly to exact word matches.
*   We added an **exact-word match detector**: when a search term matches a target word consecutively without gaps, and is bounded by spaces or string start/end, the match receives a **`+100` score bonus**.
*   This ensures that searching `"dog"` immediately prioritizes dog emojis over emojis whose description happens to contain those characters in order (like `"hotdog"` or `"underdog"`).

### B. Description Length Tie-Breaker
When multiple emojis match a query equally (e.g., both contain the exact word `"heart"` at start), the picker should prioritize the most specific emoji:
*   We introduced a target length penalty (`score -= target.len`).
*   This acts as a tie-breaker, ranking shorter, more direct descriptions higher (e.g., `"heart"` ❤️ ranks higher than `"heart with ribbon"` 💝 for the search query `"heart"`).

---

## 4. Compilation & Platform Lessons

*   **Libc Dependency**: When any test block in a Zig library references code calling `std.c.getenv`, the test target must explicitly link libc. We added `mod.link_libc = true;` to the build graph in [build.zig](file:///home/uwe/projects/emojig/build.zig) to ensure standalone test blocks compile cleanly.
*   **Headless Clipboard Tooling**: In non-interactive test environments (like CI/CD or background tasks), clipboard utilities like `wl-copy` or `xclip` can block or hang if a display compositor connection is not present. This was mitigated by unsetting display environment variables or running tests with PTY timeouts.
