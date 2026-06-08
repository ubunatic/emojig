<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [WebSandbox.md](file:///home/uwe/projects/emojig/docs/WebSandbox.md)
> - **Extra Content Covered Here:** Comparison of Path A (ttyd), Path B (container2wasm), and Path C (WebVM); detailed Dockerfile for sandbox container; inline HTML/JS example using `AttachAddon` and websocket interface.
> - **Outdated Information:** None.

---


# Interactive Browser Sandbox and Demo Pathways

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Details the research, comparative analysis, and integration patterns for running the native `emojig` Terminal User Interface (TUI) inside a sandboxed web browser environment.

This document reviews the technical research, architectural choices, and step-by-step implementation pathways for delivering an interactive, sandboxed web-based demo of the **Emojig** TUI (`emojig --tui`). Because `emojig` is a high-performance, zero-allocation terminal application that relies on low-level POSIX systems (such as `termios` configuration, raw mouse event capture via SGR VT100 sequences, `/proc` memory logging, and interactive standard input/output), running it in a web browser requires dedicated bridging or sandboxing.

---

## 1. Architectural Comparison

Three primary pathways exist for running a native compiled Zig TUI in a web browser. The table below compares these approaches:

| Feature / Metric | Path A: Server-Side Container + WebSocket Stream (`ttyd`) | Path B: Standalone WASM Container Emulation (`container2wasm`) | Path C: Client-Side OS JIT / Syscall Translation (`WebVM`) |
| :--- | :--- | :--- | :--- |
| **Execution Context** | Backend Linux Server / Container | Client-side Browser Wasm Runtime | Client-side Browser Wasm JIT |
| **Fidelity / Compatibility** | **Perfect**. Uses a real Linux kernel, terminal device, and full PTY. | **High**. Emulates a physical CPU and Linux kernel client-side. | **High**. JIT-compiles x86 system calls client-side. |
| **Mouse Hover & Click Support** | **Full**. Perfect translation of SGR raw mouse sequences. | **Full**. Passes keyboard/mouse sequences through `xterm-pty`. | **Full**. Emulates standard terminal input. |
| **Host Setup & Scale Cost** | **High**. Requires running servers/containers for active sessions. | **Zero**. Standard static hosting (GitHub Pages, Cloudflare Pages). | **Zero**. Standard static hosting with range requests. |
| **Initial Asset Download** | **Minimal** (under 1 MB; only standard CSS, JS, and HTML). | **Medium** (10 MB to 20 MB; compressed Wasm CPU and kernel image). | **High** (30 MB to 50 MB; ext2 system image and JIT libraries). |
| **Startup Latency** | **Instant** (<100 ms to spawn container and connect). | **Moderate** (2 to 5 seconds; CPU boots and initializes kernel). | **Slow** (3 to 8 seconds; virtual disk partition mounting). |
| **Target Build Requirements** | Standard Linux Native binary (e.g. x86_64 or aarch64). | Standard Linux Native binary packed inside a Docker image. | 32-bit `i386-linux` static native binary. |

---

## 2. Implementation Pathways

### Path A: Server-Side Sandbox with WebSocket Streaming (`ttyd`)

This is the standard and most responsive solution. A backend server runs the compiled native binary inside a sandboxed Linux container, and standard terminal I/O is streamed over WebSockets using `ttyd` to an `xterm.js` canvas in the browser.

#### The Sandbox Container (`Dockerfile`)
```dockerfile
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

# Stage 1: Build the native binary
FROM --platform=$BUILDPLATFORM alpine:3.20 AS builder
RUN apk add --no-cache zig build-base go

WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseSmall

# Stage 2: Create runtime sandbox container
FROM alpine:3.20

# Install ttyd and system tools (including standard emoji-compatible fonts)
RUN apk add --no-cache ttyd shadow font-noto-emoji

# Create a non-root unprivileged demo user
RUN useradd -m -s /sbin/nologin demo-user
WORKDIR /home/demo-user

# Copy native executable
COPY --from=builder /app/zig-out/bin/emojig /usr/local/bin/emojig

# Expose default ttyd port
EXPOSE 7681

# Run the app under ttyd as the demo-user with strict bounds:
# - '--once': exit the container when the session finishes or Ctrl-C is pressed.
# - '--writable': allow terminal inputs (required for interactive pickers).
# - '--tui': force ttyd to use raw/TUI mode properties.
USER demo-user
ENTRYPOINT ["ttyd", "-p", "7681", "--once", "--writable", "/usr/local/bin/emojig", "--tui"]
```

#### Client Interface (`index.html`)
The frontend loads `xterm.js` and its styling, connecting directly to the container's WebSocket server:
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Emojig - Interactive Sandbox Demo</title>
    <!-- Include xterm.js stylesheets -->
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css" />
    <style>
        body {
            background-color: #1a1a1a;
            color: #e0e0e0;
            font-family: 'Inter', sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            margin: 0;
        }
        #terminal-container {
            width: 500px;
            height: 250px;
            padding: 10px;
            border-radius: 8px;
            background-color: #1c1c1c;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
            border: 1px solid #333;
        }
        .header {
            margin-bottom: 20px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Emojig Interactive Sandbox</h1>
        <p>A zero-allocation premium TUI demo running in a sandboxed container.</p>
    </div>
    
    <div id="terminal-container"></div>

    <!-- Include xterm.js and its websocket attach addon -->
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xterm-addon-attach@0.9.0/lib/xterm-addon-attach.js"></script>
    
    <script>
        // Set up the terminal to match Emojig's optimal 25 columns by 10 rows
        const term = new Terminal({
            cols: 25,
            rows: 10,
            cursorBlink: true,
            theme: {
                background: '#1c1c1c',
                foreground: '#a8a8a8',
                cursor: '#ffffff'
            },
            fontFamily: '"JetBrains Mono", monospace'
        });

        const container = document.getElementById('terminal-container');
        term.open(container);

        // Connect WebSocket to ttyd stream
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}/ws`;
        const socket = new WebSocket(wsUrl);

        socket.onopen = () => {
            const attachAddon = new AttachAddon.AttachAddon(socket);
            term.loadAddon(attachAddon);
        };
    </script>
</body>
</html>
```

---

### Path B: Client-Side Standalone WASM Container (`container2wasm`)

This architecture allows packaging the Alpine image containing `emojig` into a WebAssembly application that executes purely in the browser without a backend server.

1.  **Build the Container Image:**
    Create a standard container containing `emojig` and static dependencies.
2.  **Compile Container to WASM:**
    Use `container2wasm` (`c2w`) to compile the image into a directory containing `emscripten` / JS outputs:
    ```bash
    c2w --to-js --architecture riscv64 --entrypoint "/usr/local/bin/emojig --tui" ubunatic/emojig-image:latest ./dist-web/
    ```
3.  **Embed in the Webpage:**
    Serve the `./dist-web/` directory. It uses a virtualized `xterm.js` environment backed by an Emscripten-compiled CPU emulator (TinyEMU) executing the kernel and container entirely client-side.

---

### Path C: Client-Side OS-Syscall JIT Sandbox (`WebVM`)

For maximum client-side performance, CheerpX implements a x86 JIT virtualizer in WebAssembly that translates standard 32-bit Linux binaries on-the-fly.

1.  **Build static 32-bit binary:**
    Compile `emojig` targeting 32-bit x86:
    ```bash
    zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall
    ```
2.  **Generate ext2 filesystem image:**
    Package the application into an ext2 disk image alongside an i386 Debian container structure (see `scripts/browser_demo.go`).
3.  **Integrate CheerpX in HTML:**
    Configure CheerpX to boot your ext2 file:
    ```javascript
    import { CxTerm } from 'https://cdn.leaningtech.com/cxterm/cxterm.js';
    
    const term = new CxTerm(document.getElementById('terminal'));
    term.run({
        image: 'https://yourhost.com/emojig-image.ext2',
        cmd: '/usr/local/bin/emojig --tui'
    });
    ```

---

## 3. Resolving TUI Web-Terminal Challenges

When executing a rich TUI application in a browser terminal emulator, three technical issues must be handled:

### A. Emoji Rendering and Character Grid Alignment
In a standard TUI layout, double-width emoji glyphs can cause text alignment issues. Modern browser terminals (like `xterm.js`) divide the grid into uniform monospaced character blocks. If the browser font does not support the emoji glyph or uses a different character boundary representation (such as missing a variation selector sequence like `U+FE0F`), the TUI selection bracket layout may appear misaligned.

**Actionable Mitigations:**
*   **Web Font Injections:** Configure `xterm.js` to prioritize an emoji-rich monospaced font, such as **Noto Color Emoji** or **Twemoji**, which guarantees uniform glyph scaling.
*   **Safe Mode Flag (`--safe`):** When launching the web demo, execute `emojig --tui --safe` or set `EMOJIG_SAFE=true`. This strips variation selectors from characters, forcing the host browser font to fallback cleanly to safe standard grid symbols.

### B. Interactive Mouse Tracking
`emojig` configures standard terminal input to read raw mouse tracking sequences:
*   Enables any-event mouse reporting (`\x1b[?1003h`) and SGR coordinate parsing (`\x1b[?1006h`).
*   Processes movement codes in its central loop to handle emoji hovers and button-press coordinates to copy/select an emoji.

**Actionable Mitigations:**
*   `xterm.js` fully supports VT100 / SGR mouse tracking protocols. However, you must make sure that no wrapper elements in the frontend block mouse events (clicks or scrolls) from reaching the terminal container canvas.
*   The WebSocket bridge in `ttyd` properly transmits SGR mouse escape sequences back and-forth, keeping mouse selection responsive.

### C. Standard Terminal and Viewport Dimensions
By default, `emojig` runs optimally inside a strict **25 columns by 10 rows** window (or similar compact footprints depending on `--border` config).
If the browser window or the `xterm.js` component has arbitrary columns or rows, the TUI's spacing could look misaligned because `emojig` bases its row offsetting on custom math.

**Actionable Mitigations:**
*   Enforce a fixed sizing option in the `xterm.js` configuration (`cols: 25, rows: 10`).
*   Configure the container styles with a static CSS `width` and `height` matching this column/row proportion so that no scrollbars or layout gaps are introduced.

---

## 4. Local Prototyping Script

To facilitate easy testing of this setup during local development, an automation script is provided under `scripts/browser_demo.go`. 

Running this script:
1.  Verifies the local Zig TUI application is compiled.
2.  Dynamically generates an optimized `Dockerfile` and a premium web dashboard file (`index.html`) implementing Path A.
3.  Exposes an internal HTTP web server to serve the frontend and orchestrate `ttyd` interactions locally for instant visual feedback.

To run the interactive developer server:
```bash
go run scripts/browser_demo.go
```
