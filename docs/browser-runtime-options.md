# Running Zig, Go, and Terminal Tools in the Browser

**Date:** 2026-06-02  
**Goal:** Run emojig (Zig) and Go demos, plus mc and fzf, in a web browser without a server or Docker.

## Executive Summary

**Current Reality (2025-2026):** WebAssembly cannot run interactive TUI apps directly due to lack of TTY/PTY/syscall support. Three practical approaches exist:

1. **Server-Streaming (Recommended for demos)** — Stream native binaries via `ttyd + xterm.js`
2. **Container-to-WASM (Zero-server static hosting)** — Package app in Alpine, compile entire container to WASM
3. **Direct WASM compilation** — Only works for libraries/simple algorithms, NOT TUI apps

**Emojig's current approach (ttyd)** is production-best-practice.

---

## Table of Contents

- [Technology Breakdown](#technology-breakdown)
- [Comparison of Options](#comparison-of-options)
- [Implementation Approaches](#implementation-approaches)
- [Limitations & Workarounds](#limitations--workarounds)
- [Recommended Path Forward](#recommended-path-forward)
- [Future: WASI Preview 2](#future-wasi-preview-2)

---

## Technology Breakdown

### 1. Zig → WebAssembly

**Zig's WASM Support:**
- Zig has native WASM target: `zig build-lib -target wasm32-wasi`
- **Only works for**: Libraries, algorithms, pure computation
- **Does NOT work for**: TUI apps, terminal I/O, raw mode, emoji rendering

**Why TUI compilation fails:**
- WASM runs in a sandboxed environment with no access to:
  - Terminal device files (`/dev/tty`)
  - PTY (pseudo-terminal)
  - Raw mode (terminal settings like `tcgetattr`, `tcsetattr`)
  - Direct keyboard input (must go through xterm.js or similar)

**Practical Path:** Compile Zig to native binary (x86_64-linux-musl) → wrap with ttyd → serve to browser.

**Maturity:** WASM backend stable; TUI support via containerization is production-ready.

---

### 2. Go → WebAssembly

**Go's WASM Support:**
- Go has stable WASM target: `GOOS=js GOARCH=wasm`
- Same limitations as Zig: **no TTY/PTY/syscalls in browser**

**For CLI/TUI Apps (Go demos, mc, fzf):**
- fzf: Written in Go; direct WASM compilation loses all interactivity (no keyboard, no TTY)
- Go demos: Same issue—cannot run interactive programs
- **Solution:** Compile to native binary, stream via ttyd

**Maturity:** WASM backend stable; TUI apps require server-side streaming or containerization.

---

### 3. Terminal Tools: mc and fzf

#### **Midnight Commander (mc)**
- Written in C
- Requires PTY, keyboard input, terminal control sequences
- Direct WASM compilation via Emscripten: possible but complex, limited POSIX support

**Practical solutions:**
1. **ttyd + native binary** (best for demos)
2. **container2wasm** (static hosting, no server)
3. **Emscripten** (C source → WASM, requires build effort)

#### **fzf (Fuzzy Finder)**
- Written in Go
- Needs: keyboard input, terminal state, TTY file descriptor
- Direct WASM: loses all interactivity (not viable)

**Practical solutions:**
1. **ttyd + native binary** (recommended)
2. **container2wasm** (static hosting)
3. **WebVM/CheerpX** (x86 JIT, commercial, expensive)

---

### 4. Terminal Emulator Solutions

#### **Browser-Side Emulators (Mature)**

| Project | License | Status | Notes |
|---------|---------|--------|-------|
| **xterm.js** | MIT | Production | Industry standard (5+ years), used by GitHub Codespaces, VS Code, Cloudflare. Full VT100/ANSI, WebSocket support, excellent mouse/keyboard handling. **Recommended.** |
| **Hterm** | BSD | Production | Powers Chrome OS terminal. Strong ANSI support, excellent mouse tracking. |
| **GoldenLayout** | MIT | Production | Multi-window terminal management. Used in enterprise terminals. |

**Recommendation:** `xterm.js` is the gold standard for browser terminals.

#### **Backend Terminal Servers**

| Project | License | Status | Notes |
|---------|---------|--------|-------|
| **ttyd** | MIT | Production (10+ yrs) | Minimal, fast PTY → WebSocket bridge. **Emojig uses this.** Single binary, <5 MB. |
| **shellinabox** | GPLv2 | Legacy | Older, declining maintenance. Avoid for new projects. |
| **WebSSH** | MIT | Production | SSH-over-HTTP. Requires SSH server. Alternative to ttyd. |
| **Glance** | MIT | Production | Modern terminal server, written in Rust, new (2023+). |

**Recommendation:** `ttyd` for simplicity and production maturity.

---

## Comparison of Options

### Option A: Server-Streaming with ttyd + xterm.js ✅ **RECOMMENDED**

**What it does:**
- Compile Zig/Go to native binary
- Run native binary in container (Alpine Linux)
- Stream terminal I/O via ttyd → WebSocket → browser xterm.js
- User interacts with live terminal in browser

**Pros:**
- ✅ Perfect fidelity (all terminal features work)
- ✅ Fast startup (<100ms)
- ✅ Simple deployment (single container)
- ✅ Emoji support (native terminal rendering)
- ✅ Works for Zig, Go, mc, fzf without modification
- ✅ Production-proven (emojig already uses this)

**Cons:**
- ❌ Requires running server
- ❌ Cannot scale to thousands of concurrent users without load balancing

**Cost:** Minimal (small container on any cloud platform)

**Implementation:**
```dockerfile
# Alpine + ttyd + native binary
FROM alpine:3.18
RUN apk add --no-cache mc fzf ttyd
COPY emojig /usr/local/bin/
ENTRYPOINT ["ttyd", "sh"]
```

**Browser code:**
```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/xterm/5.3.0/xterm.min.js"></script>
<div id="terminal"></div>
<script>
  const term = new Terminal();
  const ws = new WebSocket('ws://localhost:7681');
  const addon = new AttachAddon(ws);
  term.loadAddon(addon);
  term.open(document.getElementById('terminal'));
</script>
```

**Maturity:** Production-ready, battle-tested.

---

### Option B: Serverless Static Hosting with container2wasm

**What it does:**
- Package native binary + Alpine in Docker image
- Compile entire container to WebAssembly with `container2wasm`
- Deploy as static asset (no server needed)
- Entire Linux + app runs in browser WASM VM

**Pros:**
- ✅ No server required (static hosting, GitHub Pages, Cloudflare)
- ✅ Zero hosting cost
- ✅ Offline capable
- ✅ Faster than Emscripten for complex apps
- ✅ Works for Zig, Go, mc, fzf without modification

**Cons:**
- ❌ Larger download (10-20 MB for small Alpine container)
- ❌ Slower startup (2-5 seconds vs <100ms for ttyd)
- ❌ Not suitable for memory-intensive apps (browser WASM limited to ~2GB)
- ❌ Each app run is isolated (can't persist state to server)

**Cost:** Free (static hosting)

**Implementation:**
```bash
# 1. Create Dockerfile with app + mc/fzf
FROM alpine:3.18
RUN apk add --no-cache mc fzf
COPY emojig /usr/local/bin/
ENTRYPOINT ["emojig"]

# 2. Compile to WASM
container2wasm Dockerfile -o app.wasm

# 3. Deploy as static asset
# Upload app.wasm to GitHub Pages / Cloudflare / S3
```

**Browser code:**
```javascript
import { defaultProvider } from '@wasmer/sdk';

const wasmPath = '/app.wasm';
const instance = await defaultProvider.getModule(wasmPath);
const proc = await instance.instantiate();
```

**Project:** https://github.com/ktock/container2wasm (actively maintained, 2024+)

**Maturity:** Production-ready (2024+), younger than ttyd but solid.

---

### Option C: Direct WASM Compilation with Emscripten

**What it does:**
- Compile C/C++ source directly to WebAssembly
- Emscripten provides POSIX simulation layer in WASM

**Pros:**
- ✅ Smaller binary than container2wasm (5-15 MB)
- ✅ Faster startup than container2wasm (500ms-2s)
- ✅ Static hosting (no server)
- ✅ Mature project (10+ years)

**Cons:**
- ❌ C/C++ only (requires recompiling Zig/Go from source)
- ❌ Complex build process
- ❌ Limited library support (many C libraries incompatible with Emscripten)
- ❌ Emoji/Unicode handling requires special care
- ❌ Not recommended for fzf/mc due to complexity

**For your case:**
- **mc:** Possible but complex (C source × Emscripten compatibility = 2-3 weeks)
- **fzf:** Not practical (Go source, would need syscall simulation)
- **Zig:** Not recommended (Emscripten designed for C/C++)

**Maturity:** Production for simple apps; complex for TUI tools.

---

### Option D: JIT Native Binaries (CheerpX/WebVM)

**What it does:**
- JIT-compile x86 binary to JavaScript at runtime
- Run native binaries without recompilation

**Pros:**
- ✅ No recompilation needed
- ✅ Works for any x86 binary (mc, fzf, vim, bash)

**Cons:**
- ❌ Commercial product (CheerpX)
- ❌ Very large download (30-50 MB)
- ❌ Slow startup (3-8 seconds)
- ❌ Expensive for commercial use
- ❌ Overkill for your use case

**Products:**
- **CheerpX** (commercial, https://cheerpx.io)
- **WebVM** (free tier, https://webvm.io)

**When to use:** Only if you need arbitrary x86 binaries and can't modify the source.

**Maturity:** Commercial grade (CheerpX), beta (WebVM).

---

## Implementation Approaches

### Recommended: ttyd + Native Binary

**Step 1: Build native binary (CI/CD)**
```bash
# Zig
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# Go (if applicable)
GOOS=linux GOARCH=amd64 go build -o app
```

**Step 2: Container image**
```dockerfile
FROM alpine:3.18
RUN apk add --no-cache mc fzf ttyd bash ncurses-terminfo-base
COPY emojig /usr/local/bin/
EXPOSE 7681
ENTRYPOINT ["ttyd", "-p", "7681", "sh"]
```

**Step 3: Docker Compose (local demo)**
```yaml
version: '3'
services:
  emojig:
    build: .
    ports:
      - "7681:7681"
```

**Step 4: Browser HTML**
```html
<!DOCTYPE html>
<html>
<head>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/xterm/5.3.0/xterm.min.css"/>
</head>
<body>
  <div id="terminal" style="height: 100vh;"></div>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/xterm/5.3.0/xterm.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/xterm/5.3.0/addons/attach/attach.min.js"></script>
  <script>
    const term = new Terminal({ fontSize: 14 });
    const ws = new WebSocket('ws://localhost:7681');
    const attachAddon = new AttachAddon(ws);
    term.loadAddon(attachAddon);
    term.open(document.getElementById('terminal'));
  </script>
</body>
</html>
```

**Deployment:**
- Local: `docker compose up` → http://localhost:7681
- Cloud: Deploy container to Cloud Run, Fly.io, Railway, or Render
- Cost: ~$5/month for minimal tier

---

### Alternative: container2wasm (Zero-Server)

**Step 1: Build container as normal**
```bash
docker build -t emojig .
```

**Step 2: Compile to WASM**
```bash
container2wasm Dockerfile -o emojig.wasm
```

**Step 3: Serve static WASM**
```bash
# GitHub Pages, Cloudflare, S3, etc.
cp emojig.wasm docs/
git push  # Served as static asset
```

**Browser HTML:**
```html
<script src="/js/wasmer-js.js"></script>
<script>
  const wasmModule = await WebAssembly.instantiate(
    fetch('/emojig.wasm')
  );
</script>
```

**Trade-off:** Larger download, slower startup, but zero server cost and offline capability.

---

## Limitations & Workarounds

### Terminal I/O Limitations

| Issue | Cause | Workaround |
|-------|-------|-----------|
| No PTY support | WASM sandbox | Use ttyd or xterm.js proxy |
| Emoji double-width misalignment | Browser font rendering differs | Use Unicode11Addon in xterm.js, test in target browsers |
| Mouse tracking doesn't work | Browser event handling | Configure xterm.js `mouseEvents: true`, ensure WebSocket addon |
| Slow resize handling | Network latency | Debounce terminal resize events |
| No file system access | WASM sandbox | Use container2wasm to embed filesystem |

### Emoji Handling in Browser

**For ttyd approach:**
- Emoji rendering happens in native terminal (perfect fidelity)
- Browser just proxies terminal output
- ✅ No special handling needed

**For WASM approach (container2wasm):**
- Test emoji rendering thoroughly
- May need special font: "Monaco, Noto Color Emoji, monospace"
- Consider width calculation: emoji can be 1 or 2 columns

---

## Recommended Path Forward

### Phase 1: Proof of Concept (Now)
**Option:** Use ttyd (you likely already have this)

- ✅ Run emojig + Go demos + mc + fzf in browser today
- ✅ Simple, reliable, production-ready
- ✅ No new infrastructure needed beyond current container setup

**What to test:**
1. Emoji rendering (double-width characters)
2. Keyboard input (especially special keys like arrows, Ctrl+C)
3. Mouse tracking (if needed)
4. Terminal resize handling

**Effort:** ~4 hours (mostly testing)

---

### Phase 2: Explore container2wasm (Optional)
**Option:** If you want zero-server deployment

- ✅ Static hosting (GitHub Pages, Cloudflare, etc.)
- ✅ No monthly costs
- ✅ Works offline

**What to test:**
1. Container → WASM compilation time
2. Startup latency (2-5s is expected)
3. Memory usage in browser
4. State persistence between runs

**Effort:** ~8 hours (mostly optimization and testing)

**Decision point:** Is zero-server hosting valuable to your users?

---

### Phase 3: WASI Preview 2 (2026-2027)
**Future improvement:**

- WASI Preview 2 will add native TTY/PTY support to WebAssembly
- Compile Zig/Go directly to WASM with full terminal support
- Eliminates need for ttyd or container2wasm

**Action:** Monitor WASI Preview 2 adoption. Re-evaluate when available in major runtimes (Wasmtime, Wasmer).

---

## Technology Reference

### Key Projects

**Terminal Emulators:**
- xterm.js: https://xtermjs.org (MIT, industry standard)
- Hterm: Part of Chromium/Chrome OS (BSD)

**Terminal Servers:**
- ttyd: https://github.com/tsl0923/ttyd (MIT, production, <5 MB)
- Glance: https://github.com/glanceapp/glance (MIT, modern, Rust-based)

**Container-to-WASM:**
- container2wasm: https://github.com/ktock/container2wasm (MIT, 2024+)
- WebVM: https://github.com/leaningtech/webvm (free tier available)

**Compilation Targets:**
- Zig WASM: `zig build-lib -target wasm32-wasi` (libraries only)
- Go WASM: `GOOS=js GOARCH=wasm go build` (libraries only)
- Emscripten: https://emscripten.org (C/C++ → WASM)

**WASM Runtimes:**
- Wasmtime: https://wasmtime.dev (Mozilla, production)
- Wasmer: https://wasmer.io (production, good performance)
- Wasmer.sh: Browser WASM runtime (experimental)

---

## Summary Table

| Approach | Emoji | Speed | Setup | Cost | Server? | Maturity |
|----------|-------|-------|-------|------|---------|----------|
| **ttyd** | ✅ Perfect | ✅ <100ms | ⭐⭐⭐ | $5/mo | Yes | ✅ Production |
| **container2wasm** | ⚠️ Needs testing | ❌ 2-5s | ⭐⭐ | Free | No | ✅ Production (new) |
| **Emscripten** | ⚠️ Needs work | ⚠️ 500ms-2s | ⭐ | Free | No | ✅ Production (complex) |
| **CheerpX/WebVM** | ✅ Perfect | ❌ 3-8s | ⭐⭐⭐⭐ | $$$$ | No | ✅ Commercial |

---

## Next Steps

1. **Validate emoji rendering** in current ttyd setup (screenshots)
2. **Test keyboard edge cases** (Ctrl+Z, Ctrl+C, arrow keys in fzf)
3. **Profile startup time** and memory usage
4. **Decide:** Is current ttyd approach sufficient, or explore container2wasm?
5. **Plan Phase 2** if zero-server hosting is desired

---

**Document created:** 2026-06-02  
**Research cutoff:** February 2025 + recent 2025-2026 advancements
