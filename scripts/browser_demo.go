// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	containerName = "test-env"
	imageName     = "emojig-demo"
	ttydPort      = "7681"
	httpPort      = "8080"
	wasmOutDir    = "scripts/wasm-out"
)

const dockerfileContent = `# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

FROM alpine:3.20

# Configure environment locale for proper UTF-8 rendering
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Layer 1: heavy/slow packages — cached independently so they survive most Dockerfile edits.
# go, gcc, and the emoji font are the largest downloads; put them first.
RUN apk add --no-cache go gcc font-noto-emoji

# Layer 2: lighter runtime tools — add or remove these without busting the layer above.
RUN apk add --no-cache ttyd shadow mc fzf bash sudo curl

# Create a non-root unprivileged demo user with bash shell
RUN useradd -m -s /bin/bash demo-user
WORKDIR /home/demo-user

# Copy native executable from the host build as emojig-dev (public install provides the real emojig)
COPY zig-out/bin/emojig /usr/local/bin/emojig-dev

# Copy shell integration scripts
COPY src/shell /usr/local/share/emojig/shell

# Copy Go and helper scripts
COPY scripts /home/demo-user/scripts

# Allow demo-user to install packages with apk (no password required)
RUN echo 'demo-user ALL=(root) NOPASSWD: /sbin/apk add *, /sbin/apk update, /sbin/apk search *' \
    > /etc/sudoers.d/demo-user && chmod 0440 /etc/sudoers.d/demo-user

# Configure bash_profile and bashrc for demo-user:
#   - runs the public install script first (visual first action in the demo terminal)
#   - then shows the help banner
RUN echo 'export EMOJIG_SAFE=true' >> /home/demo-user/.bash_profile && \
    echo 'export PATH=$HOME/.local/bin:$PATH' >> /home/demo-user/.bash_profile && \
    echo 'export LANG=C.UTF-8' >> /home/demo-user/.bash_profile && \
    echo 'export LC_ALL=C.UTF-8' >> /home/demo-user/.bash_profile && \
    echo 'export PS1="\[\033[01;32m\]➜  \[\033[01;34m\]\W\[\033[00m\] "' >> /home/demo-user/.bash_profile && \
    echo 'source /usr/local/share/emojig/shell/emojig.bash' >> /home/demo-user/.bash_profile && \
    echo '# Auto-run the public install script so it is the first visible action' >> /home/demo-user/.bash_profile && \
    echo 'echo ""' >> /home/demo-user/.bash_profile && \
    echo 'printf "\033[01;34m\$ curl -fsSL https://ubunatic.com/emojig/install.sh | sh\033[0m\n"' >> /home/demo-user/.bash_profile && \
    echo 'curl -fsSL https://ubunatic.com/emojig/install.sh | sh' >> /home/demo-user/.bash_profile && \
    echo 'echo ""' >> /home/demo-user/.bash_profile && \
    echo 'echo "👋 Welcome to the Emojig TUI Sandbox!"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Press: Ctrl-E                 (to trigger the Emojig shell widget!)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: emojig --tui --safe    (to run the installed emoji picker)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: emojig-dev --tui --safe (to run the local dev build)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: mc                    (to run Midnight Commander)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: fzf                   (to run fuzzy finder)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Install packages: sudo apk add <package>"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Go Demos: go run scripts/test_tui.go"' >> /home/demo-user/.bash_profile && \
    echo 'echo ""' >> /home/demo-user/.bash_profile && \
    cp /home/demo-user/.bash_profile /home/demo-user/.bashrc && \
    chown -R demo-user:demo-user /home/demo-user

# Expose default ttyd port
EXPOSE 7681

# Run the app under ttyd as the demo-user.
# '--writable': allow terminal inputs (required for interactive pickers).
# Note: '--once' is intentionally omitted so the Reset Session button can reconnect.
USER demo-user
ENTRYPOINT ["ttyd", "-p", "7681", "--writable", "/bin/bash", "--login"]
`

const wasmHtmlContent = `<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Emojig - Interactive TUI Browser Sandbox (Docker & WASM)</title>
    {{FAVICON}}
    <link href="/vendor/fonts.css" rel="stylesheet">
    <link rel="stylesheet" href="/vendor/xterm.css" />
    <style>
        :root {
            --bg-color: #0f1015;
            --panel-color: #16171e;
            --text-color: #e2e8f0;
            --accent-color: #3b82f6;
            --accent-glow: rgba(59, 130, 246, 0.4);
            --border-color: #242735;
        }

        body {
            background-color: var(--bg-color);
            color: var(--text-color);
            font-family: 'Outfit', sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
            overflow-x: hidden;
        }

        .bg-glow {
            position: absolute;
            width: 600px;
            height: 600px;
            background: radial-gradient(circle, rgba(59, 130, 246, 0.1) 0%, rgba(0,0,0,0) 70%);
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            z-index: -1;
            pointer-events: none;
        }

        .container {
            max-width: 900px;
            width: 100%;
            display: flex;
            flex-direction: column;
            align-items: center;
            z-index: 1;
        }

        .header {
            text-align: center;
            margin-bottom: 30px;
        }

        .header h1 {
            font-size: 3rem;
            font-weight: 800;
            margin: 0 0 10px 0;
            background: linear-gradient(135deg, #60a5fa 0%, #3b82f6 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            letter-spacing: -0.05em;
        }

        .header p {
            font-size: 1.1rem;
            color: #94a3b8;
            margin: 0;
            font-weight: 300;
        }

        .card {
            background-color: var(--panel-color);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            padding: 24px;
            width: 100%;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4);
            display: flex;
            flex-direction: column;
            align-items: center;
            transition: border-color 0.3s ease, box-shadow 0.3s ease;
        }

        .card:hover {
            border-color: #3b82f6;
            box-shadow: 0 20px 40px rgba(59, 130, 246, 0.1);
        }

        .mode-toggle {
            display: flex;
            gap: 0;
            margin-bottom: 16px;
            background: rgba(0, 0, 0, 0.3);
            padding: 4px;
            border-radius: 8px;
            width: fit-content;
            margin-left: auto;
            margin-right: auto;
            border: 1px solid rgba(59, 130, 246, 0.2);
        }

        .mode-btn {
            background: transparent;
            color: #94a3b8;
            border: none;
            padding: 10px 20px;
            border-radius: 6px;
            font-family: 'Outfit', sans-serif;
            font-size: 0.95rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.15s ease;
            user-select: none;
        }

        .mode-btn:hover {
            color: #60a5fa;
            background: rgba(59, 130, 246, 0.05);
        }

        .mode-btn.active {
            background: linear-gradient(135deg, rgba(59, 130, 246, 0.3) 0%, rgba(59, 130, 246, 0.15) 100%);
            color: #60a5fa;
            border: 1px solid rgba(59, 130, 246, 0.4);
            box-shadow: 0 0 12px rgba(59, 130, 246, 0.3), inset 0 1px 2px rgba(255, 255, 255, 0.1);
        }

        .mode-btn::after {
            content: attr(data-shortcut);
            display: inline;
            margin-left: 6px;
            font-size: 0.75rem;
            color: #64748b;
            opacity: 0.6;
        }

        .mode-btn.active::after {
            opacity: 1;
            color: #94a3b8;
        }

        #terminal-wrapper {
            position: relative;
            width: 100%;
            max-width: 840px;
            background-color: #12131a;
            border-radius: 12px;
            padding: 12px;
            border: 1px solid #1f2937;
            box-shadow: inset 0 2px 8px rgba(0, 0, 0, 0.8);
        }

        #terminal {
            width: 100%;
            height: 420px;
        }

        #wasm-frame {
            width: 100%;
            height: 420px;
            border: none;
            border-radius: 12px;
            background-color: #12131a;
        }

        .wasm-unavailable {
            display: none;
            width: 100%;
            max-width: 840px;
            background-color: #12131a;
            border-radius: 12px;
            padding: 40px;
            border: 1px solid #1f2937;
            text-align: center;
            color: #94a3b8;
        }

        .wasm-unavailable h3 {
            color: #f87171;
            margin-top: 0;
        }

        .instructions {
            width: 100%;
            max-width: 600px;
            margin-top: 30px;
            background: rgba(22, 23, 30, 0.6);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 20px;
            box-sizing: border-box;
        }

        .instructions h3 {
            margin: 0 0 12px 0;
            font-weight: 600;
            color: #60a5fa;
            font-size: 1.1rem;
        }

        .instructions ul {
            margin: 0;
            padding-left: 20px;
            color: #94a3b8;
            font-size: 0.95rem;
            line-height: 1.6;
        }

        .instructions li {
            margin-bottom: 8px;
        }

        .badge {
            background-color: rgba(59, 130, 246, 0.2);
            color: #60a5fa;
            padding: 4px 10px;
            border-radius: 9999px;
            font-size: 0.8rem;
            font-weight: 600;
            margin-bottom: 16px;
            border: 1px solid rgba(59, 130, 246, 0.3);
        }

        .resize-handle {
            height: 10px;
            width: 100%;
            background: transparent;
            cursor: ns-resize;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.2s ease;
        }

        .resize-handle.bottom {
            margin-top: 6px;
            border-top: 2px dashed rgba(31, 41, 55, 0.8);
        }

        .ctrl-btn {
            background: rgba(59, 130, 246, 0.1);
            color: #60a5fa;
            border: 1px solid rgba(59, 130, 246, 0.3);
            padding: 6px 12px;
            border-radius: 6px;
            font-family: 'Outfit', sans-serif;
            font-size: 0.85rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
        }

        .ctrl-btn:hover {
            background: rgba(59, 130, 246, 0.2);
            border-color: #3b82f6;
            box-shadow: 0 0 8px rgba(59, 130, 246, 0.2);
        }

        .resize-handle::after {
            content: "";
            width: 40px;
            height: 4px;
            background: rgba(156, 163, 175, 0.2);
            border-radius: 2px;
            transition: all 0.2s ease;
        }

        .resize-handle:hover {
            background: rgba(59, 130, 246, 0.1);
        }

        .resize-handle:hover::after {
            background: #60a5fa;
            width: 60px;
            box-shadow: 0 0 8px rgba(59, 130, 246, 0.6);
        }
    </style>
</head>
<body>
    <div class="bg-glow"></div>

    <div class="container">
        <div class="header">
            <h1>Emojig</h1>
            <p>Premium Zero-Allocation Emoji TUI Browser Sandbox</p>
        </div>

        <div class="card">
            <span class="badge">Interactive TUI Environment</span>

            <!-- Mode Toggle -->
            <div class="mode-toggle">
                <button id="btn-docker" class="mode-btn active" onclick="setMode('docker')" data-shortcut="Press D" title="Docker mode (Press D)">🐳 Docker (Live)</button>
                <button id="btn-wasm" class="mode-btn" onclick="setMode('wasm')" data-shortcut="Press W" title="WASM mode (Press W)">🧊 WASM (Offline)</button>
            </div>

            <!-- Docker Terminal Area -->
            <div id="terminal-wrapper" style="position: relative;">
                <div id="terminal"></div>
            </div>
            <div id="resize-bottom" class="resize-handle bottom" style="display: none;"></div>

            <!-- WASM Unavailable Message -->
            <div id="wasm-unavailable" class="wasm-unavailable">
                <h3>⚠️ WASM Build Not Available</h3>
                <p>container2wasm (c2w) was not installed or the build failed.</p>
                <p>The Docker (Live) mode is fully functional. To use WASM, ensure <code>c2w</code> is in your PATH.</p>
            </div>

            <!-- WASM iframe (loaded lazily on tab switch) -->
            <iframe id="wasm-frame" style="display: none;"></iframe>

            <div style="display: flex; gap: 16px; align-items: center; justify-content: center; width: 100%; margin-top: 8px; flex-wrap: wrap; flex-direction: column;">
                <div style="color: #94a3b8; font-size: 0.9rem; text-align: center;">
                    <div><b>Terminal:</b> Arrow Keys to navigate • Enter to copy • Ctrl-C to exit</div>
                    <div><b>Mode:</b> Press <b>D</b> for Docker • Press <b>W</b> for WASM</div>
                </div>
                <button id="btn-reset" class="ctrl-btn">Reset Session 🔄</button>
            </div>
        </div>

        <div class="instructions">
            <h3>💡 Quick Tips</h3>
            <ul>
                <li><b>Switch Modes Instantly:</b> Press <b>D</b> for Docker (Live) or <b>W</b> for WASM (Offline) — anytime, anywhere</li>
                <li><b>Docker Mode:</b> Full streaming terminal via ttyd. Perfect for real-time testing.</li>
                <li><b>WASM Mode:</b> Zero-server environment. Offline capable. Everything runs in your browser.</li>
                <li><b>Reset:</b> Click "Reset Session 🔄" to reconnect (Docker mode) or reload (WASM mode)</li>
            </ul>
        </div>
    </div>

    <!-- Load xterm.js and Unicode 11 addon from local vendor (no external CDN calls) -->
    <script src="/vendor/xterm.js"></script>
    <script src="/vendor/addon-unicode11.js"></script>
    <script>
        let currentMode = 'docker';
        let wasmAvailable = false;
        let wasmFrameLoaded = false;

        // Setup xterm.js instance matching standard ANSI layout (80x24)
        const term = new Terminal({
            cols: 80,
            rows: 24,
            cursorBlink: true,
            allowProposedApi: true,
            theme: {
                background: '#12131a',
                foreground: '#a8a8a8',
                cursor: '#ffffff'
            },
            fontFamily: '"JetBrains Mono", "Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji", monospace'
        });

        term.open(document.getElementById('terminal'));

        // Load Unicode 11 addon for correct double-width emoji widths
        if (typeof Unicode11Addon !== 'undefined') {
            const unicode11 = new Unicode11Addon.Unicode11Addon();
            term.loadAddon(unicode11);
            term.unicode.activeVersion = '11';
        }

        // Register custom OSC 52 handler to copy text to the host system clipboard
        term.parser.registerOscHandler(52, (data) => {
            const parts = data.split(';');
            if (parts.length >= 2) {
                const b64 = parts[1];
                try {
                    const text = atob(b64);
                    navigator.clipboard.writeText(text);
                    console.log("OSC 52 copy successful (target buffer: " + parts[0] + "):", text);
                    return true;
                } catch (e) {
                    console.error("OSC 52 copy failed:", e);
                }
            }
            return false;
        });

        // Log and automatically copy when user selects text inside the terminal screen
        term.onSelectionChange(() => {
            const selection = term.getSelection();
            if (selection) {
                console.log("Text selected in terminal:", JSON.stringify(selection));
                navigator.clipboard.writeText(selection).catch(err => {
                    console.error("Text selection copy failed:", err);
                });
            }
        });

        // Connect directly to the local ttyd websocket endpoint using standard subprotocol 'tty'
        let socket;
        const decoder = new TextDecoder('utf-8');

        function connectWebSocket() {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            const hostname = window.location.hostname || '127.0.0.1';
            const wsUrl = protocol + '//' + hostname + ':7681/ws';

            console.log("WebSocket connecting to: " + wsUrl);
            socket = new WebSocket(wsUrl, 'tty');
            socket.binaryType = 'arraybuffer';

            socket.onopen = () => {
                console.log("WebSocket connection established successfully!");
                term.focus();

                const handshake = JSON.stringify({ AuthToken: "" });
                socket.send(new TextEncoder().encode(handshake));

                const resizeMsg = JSON.stringify({ columns: term.cols, rows: term.rows });
                const payload = new Uint8Array([0x31, ...new TextEncoder().encode(resizeMsg)]);
                socket.send(payload);
            };

            socket.onmessage = (event) => {
                const raw = new Uint8Array(event.data);
                if (raw.length === 0) return;

                const opcode = raw[0];
                const payload = raw.slice(1);

                if (opcode === 48) { // OUTPUT data (ASCII '0')
                    const text = decoder.decode(payload, { stream: true });
                    term.write(text);
                } else if (opcode === 49) { // SET_WINDOW_TITLE (ASCII '1')
                    const title = new TextDecoder().decode(payload);
                    console.log("Terminal window title update:", title);
                } else if (opcode === 50) { // SET_PREFERENCES (ASCII '2')
                    const prefs = new TextDecoder().decode(payload);
                    console.log("Terminal preferences updated:", prefs);
                }
            };

            socket.onerror = (err) => {
                console.error("WebSocket connection error:", err);
                term.write('\r\n\x1b[31mError: Connection to ttyd WebSocket failed.\x1b[0m\r\n');
                term.write('Please ensure the Docker sandbox or local ttyd server is running on port 7681.\r\n');
            };

            socket.onclose = (event) => {
                console.log("WebSocket connection closed. Code: " + event.code + ", Reason: " + event.reason);
            };
        }

        // Establish the initial connection
        connectWebSocket();

        // Handle user input from client-to-server prefixed with ttyd opcode '0' (0x30)
        term.onData((data) => {
            const payload = new Uint8Array([0x30, ...new TextEncoder().encode(data)]);
            if (socket && socket.readyState === WebSocket.OPEN) {
                socket.send(payload);
            }
        });

        // Handle resize events from client-to-server prefixed with ttyd opcode '1' (0x31)
        term.onResize((size) => {
            const resizeMsg = JSON.stringify({ columns: size.cols, rows: size.rows });
            const payload = new Uint8Array([0x31, ...new TextEncoder().encode(resizeMsg)]);
            if (socket && socket.readyState === WebSocket.OPEN) {
                socket.send(payload);
            }
        });

        // Drag-to-resize terminal layout handling
        const termElement = document.getElementById('terminal');
        const termWrapper = document.getElementById('terminal-wrapper');
        const setupResize = (handleElement) => {
            let startY = 0;
            let startHeight = 0;

            const onMouseMove = (e) => {
                const dy = e.clientY - startY;
                const newHeight = startHeight + dy;
                const clampedHeight = Math.max(200, Math.min(1200, newHeight));
                termElement.style.height = clampedHeight + 'px';
                termWrapper.style.height = clampedHeight + 'px';
                document.getElementById('wasm-frame').style.height = clampedHeight + 'px';

                const charHeight = 17.5;
                const newRows = Math.floor(clampedHeight / charHeight);
                if (newRows !== term.rows) {
                    term.resize(term.cols, newRows);
                }
            };

            const onMouseUp = () => {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
                document.body.style.cursor = 'default';
                termElement.style.pointerEvents = 'auto';
            };

            handleElement.addEventListener('mousedown', (e) => {
                e.preventDefault();
                startY = e.clientY;
                startHeight = termWrapper.clientHeight;
                document.body.style.cursor = 'ns-resize';
                termElement.style.pointerEvents = 'none';
                document.addEventListener('mousemove', onMouseMove);
                document.addEventListener('mouseup', onMouseUp);
            });
        };

        setupResize(document.getElementById('resize-bottom'));

        // Handle reset button click to restart the terminal and reconnect
        const btnReset = document.getElementById('btn-reset');
        btnReset.addEventListener('click', () => {
            console.log("Resetting terminal...");
            if (socket) {
                socket.close();
            }
            term.reset();
            connectWebSocket();
        });

        // Mode toggle functionality — WASM availability is checked lazily on first switch,
        // so Docker mode (the default) never triggers a 404 probe on page load.
        let wasmChecked = false;

        function setMode(mode) {
            currentMode = mode;
            const isDocker = mode === 'docker';

            document.getElementById('terminal-wrapper').style.display = isDocker ? '' : 'none';
            document.getElementById('resize-bottom').style.display = isDocker ? '' : 'none';

            if (isDocker) {
                document.getElementById('wasm-frame').style.display = 'none';
                document.getElementById('wasm-unavailable').style.display = 'none';
                term.focus();
            } else {
                // WASM mode
                if (wasmChecked) {
                    applyWasmMode();
                } else {
                    // Check if WASM output is available first
                    fetch('/wasm-out/index.html', { method: 'HEAD' })
                        .then(response => {
                            wasmChecked = true;
                            if (response.ok) {
                                wasmAvailable = true;
                                console.log("WASM build is available");
                            } else {
                                console.log("WASM build not available (404)");
                            }
                            applyWasmMode();
                        })
                        .catch(err => {
                            wasmChecked = true;
                            console.log("WASM build not available:", err);
                            applyWasmMode();
                        });
                }
            }

            // Update button states
            document.getElementById('btn-docker').classList.toggle('active', isDocker);
            document.getElementById('btn-wasm').classList.toggle('active', !isDocker);
        }

        function applyWasmMode() {
            if (wasmAvailable) {
                document.getElementById('wasm-frame').style.display = '';
                document.getElementById('wasm-unavailable').style.display = 'none';

                // Lazy load the iframe on first switch to WASM mode
                if (!wasmFrameLoaded) {
                    document.getElementById('wasm-frame').src = '/wasm-out/index.html';
                    wasmFrameLoaded = true;
                }
            } else {
                document.getElementById('wasm-unavailable').style.display = '';
                document.getElementById('wasm-frame').style.display = 'none';
            }
        }

        // Keyboard shortcuts: D for Docker, W for WASM
        document.addEventListener('keydown', (e) => {
            // Only if not typing in an input/textarea
            if (e.target === document.body || e.target === document.documentElement) {
                if (e.key === 'd' || e.key === 'D') {
                    e.preventDefault();
                    setMode('docker');
                } else if (e.key === 'w' || e.key === 'W') {
                    e.preventDefault();
                    setMode('wasm');
                }
            }
        });
    </script>
</body>
</html>
`

// findRuntime returns the first container runtime found in PATH (podman preferred).
func findRuntime() string {
	for _, rt := range []string{"podman", "docker"} {
		if _, err := exec.LookPath(rt); err == nil {
			return rt
		}
	}
	return ""
}

// runCmd runs a command with inherited stdout/stderr and returns any error.
func runCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// stopContainer stops the named container, ignoring errors (may not be running).
func stopContainer(rt string) {
	_ = exec.Command(rt, "stop", containerName).Run()
}

const c2wRepo = "https://github.com/ktock/container2wasm.git"

// buildC2WInDocker builds WASM using docker:dind.
// Exports the image to tar, then loads and compiles it inside the container.
func buildC2WInDocker(rt, imageName, outDir string) bool {
	fmt.Printf("🔄 Compiling to WebAssembly (this may take 1-5 minutes)...\n")

	absOutDir, _ := filepath.Abs(outDir)
	tmpDir, _ := os.MkdirTemp("", "c2w-dind-*")
	defer os.RemoveAll(tmpDir)

	imageTarPath := filepath.Join(tmpDir, "image.tar")

	// Step 1: Export image from host
	fmt.Printf("   Exporting %s image...\n", imageName)
	exportCmd := exec.Command(rt, "save", "-o", imageTarPath, imageName)
	if err := exportCmd.Run(); err != nil {
		fmt.Printf("⚠️  Failed to export image: %v\n", err)
		return false
	}

	// Step 2: Run docker:dind with the tar file and output dir mounted
	cmd := exec.Command(rt, "run", "--rm",
		"--privileged",
		"-v", imageTarPath + ":/tmp/image.tar",
		"-v", absOutDir + ":/out",
		"docker:dind",
		"/bin/sh", "-c", fmt.Sprintf(`
set -e
# Start dockerd daemon in background
dockerd --storage-driver=overlay2 &
DOCKER_PID=$!

# Wait for docker daemon to be ready
for i in $(seq 1 60); do
  if docker ps > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Build and run c2w
apk add --no-cache git go bash
git clone --depth=1 https://github.com/ktock/container2wasm.git /tmp/c2w
cd /tmp/c2w
go build -o /usr/local/bin/c2w ./cmd/c2w
docker load < /tmp/image.tar
c2w %s /out --to-js

# Clean up
kill $DOCKER_PID || true
`, imageName),
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Printf("⚠️  WASM compilation failed: %v\n", err)
		return false
	}

	fmt.Println("✅ Container compiled to WebAssembly!")
	return true
}

// ensureC2W checks if c2w is in PATH; if not, builds and installs it from source.
// Returns true if c2w is available (or was successfully installed), false otherwise.
func ensureC2W() bool {
	if _, err := exec.LookPath("c2w"); err == nil {
		return true
	}

	fmt.Println("⚙️  c2w not found — building from source (one-time setup)...")

	tmpDir, err := os.MkdirTemp("", "c2w-build-*")
	if err != nil {
		fmt.Printf("⚠️  Failed to create temp dir: %v\n", err)
		return false
	}
	defer os.RemoveAll(tmpDir)

	if err := runCmd("git", "clone", "--depth=1", c2wRepo, tmpDir); err != nil {
		fmt.Printf("⚠️  Failed to clone c2w repo: %v\n", err)
		return false
	}

	homeDir, _ := os.UserHomeDir()
	binDir := filepath.Join(homeDir, ".local", "bin")
	_ = os.MkdirAll(binDir, 0755)
	binPath := filepath.Join(binDir, "c2w")

	cmd := exec.Command("go", "build", "-o", binPath, "./cmd/c2w")
	cmd.Dir = tmpDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Printf("⚠️  Failed to build c2w: %v\n", err)
		return false
	}

	// Ensure the new binary is found on subsequent exec calls
	if err := os.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH")); err != nil {
		fmt.Printf("⚠️  Failed to update PATH: %v\n", err)
	}

	fmt.Println("✅ c2w installed to " + binPath)
	return true
}

// runC2W compiles a container image to WASM using container2wasm.
// Returns true if successful, false otherwise.
func runC2W(imageName, outDir string) bool {
	fmt.Printf("🔄 Compiling container image to WebAssembly (this may take 1-5 minutes)...\n")
	cmd := exec.Command("c2w", imageName, outDir, "--to-js")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Printf("⚠️  container2wasm (c2w) compilation failed: %v\n", err)
		fmt.Println("   WASM mode will not be available, but Docker mode will still work.")
		return false
	}
	fmt.Println("✅ Container compiled to WebAssembly!")
	return true
}

func main() {
	fmt.Println("====================================================")
	fmt.Println("      Emojig TUI Browser Sandbox — All Modes        ")
	fmt.Println("====================================================")

	// Step 1: Build static Musl binary for container compatibility.
	fmt.Println("Building statically linked Musl binary (zig-out/bin/emojig)...")
	if err := runCmd("zig", "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseSmall"); err != nil {
		fmt.Printf("❌ Failed to compile emojig: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("✅ Musl compilation successful!")

	// Step 2: Generate demo files.
	dockerfilePath := filepath.Join("scripts", "demo.Dockerfile")
	if err := os.WriteFile(dockerfilePath, []byte(dockerfileContent), 0644); err != nil {
		fmt.Printf("❌ Failed to write Dockerfile: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("📝 Generated sandbox Dockerfile: %s\n", dockerfilePath)

	var faviconTag string
	svgPath := filepath.Join("src", "assets", "emojig-icon.web.svg")
	if svgBytes, err := os.ReadFile(svgPath); err == nil {
		base64Svg := base64.StdEncoding.EncodeToString(svgBytes)
		faviconTag = fmt.Sprintf("\n    <link rel=\"icon\" type=\"image/svg+xml\" href=\"data:image/svg+xml;base64,%s\" />", base64Svg)
	}
	finalHtml := strings.ReplaceAll(wasmHtmlContent, "{{FAVICON}}", faviconTag)
	htmlPath := filepath.Join("scripts", "wasm-demo.html")
	if err := os.WriteFile(htmlPath, []byte(finalHtml), 0644); err != nil {
		fmt.Printf("❌ Failed to write demo HTML: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("📝 Generated client-side HTML:   %s\n", htmlPath)

	// Step 3: Find a container runtime and run the ttyd container.
	rt := findRuntime()
	if rt == "" {
		// Fallback: try local ttyd directly.
		fmt.Println("⚠️  No container runtime (podman/docker) found. Trying local ttyd...")
		binPath := filepath.Join("zig-out", "bin", "emojig")
		ttydCmd := exec.Command("ttyd", "-p", ttydPort, "--writable", binPath, "--tui", "--safe")
		ttydCmd.Stdout = os.Stdout
		ttydCmd.Stderr = os.Stderr
		if err := ttydCmd.Start(); err != nil {
			fmt.Printf("❌ No container runtime or local ttyd found. Cannot start ttyd server.\n")
			os.Exit(1)
		}
		defer func() { _ = ttydCmd.Process.Kill() }()
		fmt.Printf("✅ Local ttyd running on :%s\n", ttydPort)
	} else {
		// Step 4: Build the container image.
		fmt.Printf("🐳 Using runtime: %s — building image %q...\n", rt, imageName)
		if err := runCmd(rt, "build", "-t", imageName, "-f", dockerfilePath, "."); err != nil {
			fmt.Printf("❌ Image build failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("✅ Image %q ready\n", imageName)

		// Step 5: Build WASM using Docker (works with both docker and podman on host).
		_ = os.RemoveAll(wasmOutDir)
		os.MkdirAll(wasmOutDir, 0755)

		fmt.Println("Building WebAssembly version...")
		buildC2WInDocker(rt, imageName, wasmOutDir)

		// Step 6: Stop any stale container, then start a fresh one.
		fmt.Printf("Starting container %q on port %s...\n", containerName, ttydPort)
		stopContainer(rt)
		if err := runCmd(rt, "run", "--rm", "-d", "-t",
			"-p", ttydPort+":"+ttydPort,
			"--name", containerName,
			imageName,
		); err != nil {
			fmt.Printf("❌ Failed to start container: %v\n", err)
			os.Exit(1)
		}
		defer stopContainer(rt)
		fmt.Printf("✅ Container %q running (ttyd on :%s)\n", containerName, ttydPort)
	}

	// Step 7: Start HTTP file server to serve the scripts/ directory.
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.Dir("scripts")))
	srv := &http.Server{Addr: ":" + httpPort, Handler: mux}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("HTTP server error: %v\n", err)
		}
	}()
	fmt.Printf("✅ HTTP server running on :%s\n", httpPort)

	// Give ttyd a moment to initialise before printing the URL.
	time.Sleep(time.Second)

	fmt.Println()
	fmt.Println("====================================================")
	fmt.Printf("  🌐  Open Browser  →  http://localhost:%s/wasm-demo.html\n", httpPort)
	fmt.Println()
	fmt.Println("  🐳 Press D for Docker (Live)    • Full streaming")
	fmt.Println("  🧊 Press W for WASM (Offline)   • Zero-server")
	fmt.Println()
	fmt.Printf("  (ttyd direct access: http://localhost:%s)\n", ttydPort)
	fmt.Println("====================================================" )
	fmt.Println("  Press Ctrl+C to stop all services.")
	fmt.Println()

	// Step 8: Wait for SIGINT or SIGTERM, then tear down.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	fmt.Println("\n🛑 Shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	// deferred stopContainer / ttydCmd.Kill run here.
	fmt.Println("✅ All services stopped.")
}
