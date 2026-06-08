<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Why Emojig? Design Philosophy & Niche

This document explains the motivations behind Emojig, its architectural tradeoffs, and why a low-resource hybrid Zig/Go system is chosen for this utility.

---

## 1. The Niche: Keyboard-Centric Speed and Low Footprint

Standard emoji pickers on Linux (like `ibus-emoji`, `rofi`, `wofi`, or web-based electron pickers) present several operational friction points:
1. **Startup Latency**: Many GUI toolkits or background daemons take over 500ms to open, disrupting developer flow.
2. **Resource Consumption**: Running a background service just to wait for occasional emoji inputs wastes precious memory pages.
3. **Alternate Buffer Disruption**: Command-line alternatives (like using `fzf` directly over JSON lists) hijack the entire terminal terminal state, wiping the shell's active prompt from sight during search.

### Emojig's Core Value Propositions

* **Sub-100ms Startup**: Launches instantly in-place or as a borderless window, keeping the developer's fingers on the keyboard.
* **Inline Cohabitation**: Sits cleanly below the active prompt without alternate screen buffer switches, maintaining prompt visibility.
* **Minimal Memory Budget**: Operates with a Resident Set Size (RSS) under **2.0 MB** and a statically compiled binary size under **350 KB**.
* **Zero Background Daemons**: The picker runs as a self-contained, fire-and-forget process. State (such as Most Recently Used lists or theme selections) is persisted to local files on disk at exit rather than keeping a daemon running.

---

## 2. Compile-Time Database Embedding

Conventional applications read JSON, CSV, or SQLite files from disk at runtime. This introduces file I/O overhead, parsing overhead, and heap allocations.

### Embedded Binary Stream (`emojis.bin`)
Emojig avoids runtime parsing by pre-compiling the emoji database.
1. During build time, an offline packer tool (`scripts/pack_emojis.go`) parses Unicode emoji specifications, deduplicates keyword strings, and packs them into a compressed binary file (`src/emojis.bin`) consisting of a flat string table and a fixed little-endian offset array.
2. At compile time, Zig embeds this file directly into the executable memory segment using `@embedFile("emojis.bin")`.
3. At runtime, querying matches is done by performing zero-copy, direct-offset lookups. The program reads slices pointing directly into the embedded read-only segment, executing the entire search with **zero heap allocations**.

---

## 3. Go vs. Zig Architectural Division of Labor

The repository utilizes a hybrid architecture: Zig is used for the runtime binary, and Go is used for build-time operations and automated testing.

```mermaid
flowchart TD
    subgraph Build Phase (Go)
        A["data/emoji.json"] --> B["pack_emojis.go"]
        B --> C["src/emojis.bin"]
    end
    
    subgraph Compilation (Zig)
        C --> D["zig build"]
        E["src/main.zig"] --> D
        D --> F["dist/emojig (Static Binary <350KB)"]
    end
    
    subgraph Validation (Go)
        F --> G["test_tui.go (PTY Simulator)"]
    end
```

### Why Zig for the Runtime?
* **Zero-Allocation Execution Loop**: Stack-only allocations in the interactive rendering loop prevent heap fragmentation.
* **Exact POSIX System Call Control**: The ability to override Zig's panic handler ensures the terminal uncooked mode is restored even when a low-level crash occurs.
* **Tiny Binary Footprint**: Zig does not compile garbage collection or complex scheduler bookkeeping into the target binary, allowing the release executable to fit within 350 KB.

### Why Go for the Tooling?
* **High-Level Standard Libraries**: Writing deduplicated string tables and parsing complex JSON structures is highly efficient in Go using `encoding/json` and `bytes.Buffer`.
* **Reliable PTY Simulation**: Go's robust Unix pseudo-terminal (PTY) libraries enable programmatic testing of raw inputs and ANSI escape buffers.
* **Developer Velocity**: Using Go for offline compilation tasks and pre-flight validation scripts prevents low-level boilerplate code from slowing down development.

---

## 4. Architectural Comparison Matrix

| Metric | Emojig (Zig runtime) | Typical Go CLI | Why the difference matters |
| :--- | :--- | :--- | :--- |
| **Static Size** | **~340 KB** | **> 1.2 MB** | Small binaries load faster from storage and fit easily in container/WASM builds. |
| **Active RSS** | **~1.9 MB** | **~6.0 MB** | Essential for instant graphical popups under lightweight window managers. |
| **Heap Alloc** | **0** in main TUI loop | **> 0** (implicit) | Prevents runtime GC latency spikes during keypress event processing. |
| **Panic Handling** | Custom overridden handler | Runtime traceback | Ensures raw terminal attributes are restored under all failure modes. |
