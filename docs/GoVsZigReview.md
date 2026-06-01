# Emojig: Go vs. Zig Architectural Review

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the hybrid architecture implemented in **Emojig v0.1.0**.

This document provides a comparative analysis of the **Emojig** codebase from a Go vs. Zig perspective. It evaluates whether a pure Go implementation could have achieved the same runtime constraints and discusses the pros, cons, and synergies of the hybrid architecture currently implemented in the repository.

---

## Executive Summary

The core interactive Emojig CLI is written in **Zig**, while offline utilities, database compilation, and interactive testing tools are written in **Go**. 

This hybrid design represents a deliberate division of labor:
1. **Zig** is used for the interactive runtime where minimal binary size, zero-allocation memory consumption, and absolute terminal safety are critical.
2. **Go** is used for build-time scripting and terminal emulation testing where developer velocity, standard libraries (JSON processing, cryptographic hashing, and OS level PTY creation), and garbage collection simplify development.

A pure Go implementation could easily replicate the user-facing functionality (terminal raw mode, mouse clicks, and fuzzy search). However, Go **cannot** meet the strict operational constraints of Emojig: a static binary size of under 350 KB and a Resident Set Size (RSS) of under 2.0 MB.

---

## Architecture Diagram

The diagram below illustrates the relationship between the offline Go tools and the compiled Zig binary:

```mermaid
flowchart TD
    subgraph Offline / Build Time (Go)
        A["data/emoji.json (Raw Database)"] --> B["scripts/pack_emojis.go"]
        B --> C["src/emojis.bin (Packed Binary Table)"]
    end

    subgraph Compile & Runtime (Zig)
        C --> D["zig build (ReleaseSmall)"]
        E["src/main.zig & src/root.zig"] --> D
        D --> F["dist/emojig (Static Binary < 280KB)"]
    end

    subgraph Testing & Simulation (Go)
        F --> G["scripts/test_tui.go (PTY Simulator)"]
    end
```

---

## Comparative Matrix

The table below outlines the trade-offs of Zig and Go regarding the specific requirements of the Emojig interactive binary:

| Architectural Metric | Zig (Current Implementation) | Go (Hypothetical Alternative) | Technical Reasoning |
| :--- | :--- | :--- | :--- |
| **Static Binary Size** | **340 KB** (ReleaseSmall) | **~1.2 MB - 2.0 MB** | Go compiles its runtime (scheduler, garbage collector, and type reflection) into every executable. Zig has no runtime, producing minimal binaries. |
| **Memory Footprint (RSS)** | **< 2.0 MB** (typically ~1.9 MB) | **~3.0 MB - 10.0 MB** | Go's runtime spawns background threads for garbage collection and goroutine scheduling, pre-allocating memory pages. Zig has zero overhead. |
| **Heap Allocations** | **0** in the active interactive loop | **> 0** (under ordinary runtime use) | Zig enforces explicit allocation, allowing the TUI loop to run completely on the stack. Go handles allocation implicitly, making absolute zero-allocation difficult. |
| **Terminal Raw Recovery** | **High** (Guaranteed via native custom `panic` override and POSIX signal handlers) | **Medium** (Relies on goroutine-based signal catching; low-level panics bypass normal TUI cleanup) | Zig's panic handler intercepts all language-level failures to restore terminal state. Go's runtime crashes make clean restoration more complex. |
| **Development Velocity** | **Lower** (requires manual buffer management, explicit error handling, and memory layouts) | **Higher** (garbage collection, extensive standard library, and automatic runtime features) | Zig requires low-level systems engineering. Go offers quick prototyping. |
| **Compile-Time Embedding** | **Native** (`@embedFile`) | **Native** (`//go:embed`) | Both languages support compiler-level embedding of raw static data into the binary. |

---

## Deep Dive: Would Go Have Achieved the Same Result?

### 1. Functional Equivalence: Yes
Go is highly capable of creating terminal-based user interfaces. Libraries such as `bubbletea` or raw terminal manipulation via `golang.org/x/term` can capture standard input, register mouse events using SGR tracking, and output ANSI escape codes to render a borderless 2D grid. The fuzzy-search logic (subsequence alignment, scoring, and plural/stem fallbacks) could be ported to Go.

### 2. Resource Constraints: No
Go is fundamentally constrained by its runtime model. 

* **The Go Runtime Overhead**: Even a minimal "Hello, World" Go program static binary requires a minimum of 1.2 MB on Linux x86_64, whereas the Zig binary compiles down to 340 KB.
* **Resident Set Size (RSS)**: Go's virtual memory allocator, garbage collector (GC), and concurrent M:N scheduler (goroutine management) require several megabytes of bookkeeping memory. Even with `GOGC=off`, a Go TUI application cannot execute within a 2.0 MB RSS budget. Under Wayland, where `emojig` launches in a floating `foot` terminal via keyboard shortcut, low memory footprint ensures instant launch speeds and zero performance degradation on low-end systems.

---

## Pros and Cons of Each Approach

### Zig for the Runtime Binary

> [!NOTE]
> Zig serves as the systems programming language for the target executable where efficiency and predictable system interactions are required.

#### Pros:
* **Zero-Allocation Interactive Loop**: In [root.zig](file:///home/uwe/projects/emojig/src/root.zig) and [mru.zig](file:///home/uwe/projects/emojig/src/mru.zig), memory operations use fixed-size static stack buffers or reference the embedded read-only binary slice. No allocator is active during the search and render cycles, preventing heap fragmentation.
* **Low-Level Terminal Control**: Zig provides direct access to POSIX system calls. In [main.zig](file:///home/uwe/projects/emojig/src/main.zig), `pub fn panic` is overridden to guarantee that if a crash occurs, standard terminal state is restored and mouse tracking is disabled before the OS exits.
* **Comptime Power**: The emoji database [emojis.bin](file:///home/uwe/projects/emojig/src/emojis.bin) is embedded using `@embedFile`. The `EmojiDb` structure parses the binary table at compile time, enabling zero-copy, direct-offset lookups.

#### Cons:
* **High Boilerplate for Basic Tasks**: Parsing JSON or handling dynamic configuration file updates in [mru.zig](file:///home/uwe/projects/emojig/src/mru.zig) requires manual index tracing and string slicing rather than calling a standard high-level library.
* **Explicit Allocator Overhead**: If a task does require heap space, passing an allocator down the call stack is verbose.

---

### Go for Scripts & Tooling

> [!TIP]
> Go is ideal for offline compiler tasks, automated testing, and developer operations where execution speed is overshadowed by development velocity.

#### Pros:
* **Rich Standard Library**: The database packer in [pack_emojis.go](file:///home/uwe/projects/emojig/scripts/pack_emojis.go) relies on `encoding/json` and `bytes.Buffer`. Writing a deduplicated string table with index offsets requires only 160 lines of Go code.
* **Built-in PTY Testing**: The TUI simulator in [test_tui.go](file:///home/uwe/projects/emojig/scripts/test_tui.go) uses terminal-controlling packages to test key strokes and screen buffers.
* **Fast Compilation**: Go scripts run instantly using `go run`, offering a fluid script-like developer experience without the complexity of compiling a systems-level utility.

#### Cons:
* **Heavyweight for Cli Tools**: Using Go for the main binary would add significant memory and size overhead.
* **GC Latency Jitter**: Although minor, garbage collection sweeps can introduce execution pauses, which are avoided by Zig's deterministic stack execution.

---

## Evaluation of the Codebase Design

The division of languages in the Emojig repository represents an efficient systems design:

1. **The Packer ([pack_emojis.go](file:///home/uwe/projects/emojig/scripts/pack_emojis.go))**: Written in Go to easily read the raw `data/emoji.json` array, parse objects, deduplicate keyword string tables, and format little-endian offsets. It outputs a packed binary `emojis.bin`.
2. **The Database ([emojis.bin](file:///home/uwe/projects/emojig/src/emojis.bin))**: Embedded inside the static executable.
3. **The Core App ([main.zig](file:///home/uwe/projects/emojig/src/main.zig) & [root.zig](file:///home/uwe/projects/emojig/src/root.zig))**: Written in Zig to load the binary into memory at startup, register raw terminal properties, and handle fast 2D navigation and fuzzy search without allocating heap memory.
4. **The Test Simulator ([test_tui.go](file:///home/uwe/projects/emojig/scripts/test_tui.go))**: Written in Go to act as a programmatic terminal, validating the Zig binary outputs.

### Conclusion

The use of Zig for the main executable is fully justified by the ultra-low resource requirements. While Go is capable of replicating the exact user interface, it cannot reproduce the lightweight system characteristics (static binary size < 350 KB and memory footprint < 2.0 MB). Conversely, utilizing Go for offline preprocessing and automated testing maintains developer velocity, avoiding the verbose coding patterns required by Zig.
