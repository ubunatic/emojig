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
                const frame = document.getElementById('wasm-frame');
                frame.style.display = '';
                document.getElementById('wasm-unavailable').style.display = 'none';

                // Lazy load the iframe on first switch to WASM mode
                if (!wasmFrameLoaded) {
                    frame.src = '/wasm-out/index.html';
                    wasmFrameLoaded = true;
                    // Focus after load so the inner xterm receives keyboard events
                    frame.addEventListener('load', () => frame.focus(), { once: true });
                } else {
                    frame.focus();
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
func runCmd(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// stopContainer stops the named container, ignoring errors (may not be running).
func stopContainer(rt string) {
	_ = exec.Command(rt, "stop", containerName).Run()
}

const c2wRepo = "https://github.com/ktock/container2wasm.git"

// c2wBuildContainer is the (privileged, nested-dockerd) container that runs the
// WASM compile. It must be force-removed on every exit path: killing the
// `docker run` client does NOT stop the container, so on Ctrl+C it would
// otherwise orphan with a dockerd + buildkit still running inside it.
const c2wBuildContainer = "emojig-c2w-build-temp"

// c2wCacheVolume persists the nested dockerd's /var/lib/docker (pulled base
// images + buildkit layer cache) across runs. Without it every WASM build
// starts with an empty daemon and re-pulls/re-builds everything. Clear it with
// `docker volume rm emojig-c2w-dind-cache` if it ever gets corrupted or large.
const c2wCacheVolume = "emojig-c2w-dind-cache"

// c2wBuilderImage is the image whose containers run the nested-dockerd WASM
// build. Only one may run at a time — they share c2wCacheVolume.
const c2wBuilderImage = "emojig-c2w-builder"

// stopGrace is the `docker stop -t` timeout (seconds) the nested dockerd gets
// to flush /var/lib/docker before it's SIGKILLed. Generous so a stop during
// heavy build I/O still shuts down cleanly and keeps the cache intact.
const stopGrace = "30"

// The c2w build must run as root: c2w's rootfs stage uses mknod, which the
// kernel forbids inside the rootless podman user namespace (EPERM regardless of
// --privileged). So the build subsystem (builder image, stale-stop, run,
// cleanup) is invoked rootfully via sudo; only the app-image export stays
// rootless, since emojig-demo lives in the user's rootless storage.

// sudoCtx builds a context-bound `sudo <rt> <args...>` command. Stdin is the
// terminal so sudo can prompt if cached credentials have expired.
func sudoCtx(ctx context.Context, rt string, args ...string) *exec.Cmd {
	c := exec.CommandContext(ctx, "sudo", append([]string{rt}, args...)...)
	c.Stdin = os.Stdin
	return c
}

// sudoBare is sudoCtx without a context, for cleanup that must survive ctx
// cancellation (Ctrl+C).
func sudoBare(rt string, args ...string) *exec.Cmd {
	c := exec.Command("sudo", append([]string{rt}, args...)...)
	c.Stdin = os.Stdin
	return c
}

// primeSudo validates sudo credentials once up front so the multi-minute build
// doesn't pause to prompt midway.
func primeSudo(ctx context.Context) error {
	fmt.Println("🔑 WASM build needs real root (mknod is blocked in rootless podman) — priming sudo...")
	c := exec.CommandContext(ctx, "sudo", "-v")
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

// chownToUser restores ownership of a path written by the rootful build back to
// the invoking user, so the output dir isn't left root-owned.
func chownToUser(path string) {
	owner := fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
	c := exec.Command("sudo", "chown", "-R", owner, path)
	c.Stdin = os.Stdin
	if err := c.Run(); err != nil {
		fmt.Printf("⚠️  Could not restore ownership of %s (try: sudo chown -R %s %s): %v\n", path, owner, path, err)
	}
}

// stopStaleBuilds gracefully stops any container created from the c2w builder
// image — e.g. a build orphaned by a previous Ctrl+C. They must be gone before
// a new build starts: a second nested dockerd on the shared c2wCacheVolume
// (/var/lib/docker) would corrupt it. We `stop` (SIGTERM) rather than `rm -f`
// (SIGKILL) so the nested dockerd flushes and the cache stays intact; the
// containers are `--rm`, so stopping also removes them. Reports what it
// stopped so it's visible.
func stopStaleBuilds(rt string) {
	out, err := sudoBare(rt, "ps", "-aq", "--filter", "ancestor="+c2wBuilderImage).Output()
	if err != nil {
		// Fall back to the well-known name if the filter isn't supported.
		_ = sudoBare(rt, "stop", "-t", stopGrace, c2wBuildContainer).Run()
		return
	}
	ids := strings.Fields(string(out))
	if len(ids) == 0 {
		return
	}
	fmt.Printf("🧹 Stopping %d stale c2w build container(s) from a previous run...\n", len(ids))
	_ = sudoBare(rt, append([]string{"stop", "-t", stopGrace}, ids...)...).Run()
}

// buildC2WBuilderImage ensures the c2w builder image is built and current.
// Rootful: the image must live in root's storage, since the rootful `docker run`
// looks for it there. We always invoke build (not a presence check) so changes
// to scripts/Dockerfile.c2w are picked up; the layer cache makes an unchanged
// build near-instant.
func buildC2WBuilderImage(ctx context.Context, rt string) bool {
	fmt.Printf("🔨 Ensuring c2w builder image is up to date...\n")
	buildCmd := sudoCtx(ctx, rt, "build", "-t", c2wBuilderImage, "-f", "scripts/Dockerfile.c2w", ".")
	if out, err := buildCmd.CombinedOutput(); err != nil {
		fmt.Printf("⚠️  Failed to build c2w builder: %v\n%s", err, out)
		return false
	}
	fmt.Printf("✅ c2w builder ready\n")
	return true
}

// humanSize renders a byte count as a short human-readable string.
func humanSize(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGT"[exp])
}

// watchOutDir polls dir until ctx is cancelled, reporting files in the
// mounted output directory as they first appear and as they grow. This gives
// "a bit" of visible progress for the otherwise-silent c2w compile.
func watchOutDir(ctx context.Context, dir string) {
	seen := map[string]int64{}
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
				if err != nil || d.IsDir() {
					return nil
				}
				info, err := d.Info()
				if err != nil {
					return nil
				}
				rel, _ := filepath.Rel(dir, path)
				size := info.Size()
				prev, ok := seen[rel]
				if !ok {
					fmt.Printf("   📄 %s (%s)\n", rel, humanSize(size))
				} else if size != prev {
					fmt.Printf("   📈 %s (%s)\n", rel, humanSize(size))
				}
				seen[rel] = size
				return nil
			})
		}
	}
}

// buildC2WInDocker builds WASM using the cached c2w builder image.
func buildC2WInDocker(ctx context.Context, rt, imageName, outDir string) bool {
	fmt.Printf("🔄 Compiling to WebAssembly (this may take 1-5 minutes)...\n")

	// Prime sudo once: the build subsystem below runs rootfully (mknod needs
	// real root) and we don't want a password prompt interrupting it midway.
	if err := primeSudo(ctx); err != nil {
		fmt.Printf("⚠️  rootful WASM build needs sudo: %v\n", err)
		return false
	}

	// Build or reuse the c2w builder image
	if !buildC2WBuilderImage(ctx, rt) {
		return false
	}

	absOutDir, _ := filepath.Abs(outDir)
	tmpDir, _ := os.MkdirTemp("", "c2w-dind-*")
	defer os.RemoveAll(tmpDir)

	imageTarPath := filepath.Join(tmpDir, "image.tar")

	// Export image from host — rootless, since emojig-demo lives in the user's
	// rootless storage. The rootful build only needs the resulting tar file.
	fmt.Printf("   Exporting %s...\n", imageName)
	exportCmd := exec.CommandContext(ctx, rt, "save", "-o", imageTarPath, imageName)
	if err := exportCmd.Run(); err != nil {
		fmt.Printf("⚠️  Failed to export image: %v\n", err)
		return false
	}

	// Stop any stale build containers from a previous (e.g. interrupted) run —
	// they'd otherwise hold the shared cache volume and corrupt it.
	stopStaleBuilds(rt)
	// Guarantee this run's container is stopped on every exit path — including
	// Ctrl+C, where killing the `docker run` client below does NOT stop the
	// (privileged, nested-dockerd) container. `stop` (SIGTERM) lets the nested
	// dockerd flush so the cache stays intact; the fresh, uncancelled command
	// still runs after ctx is cancelled. The container is `--rm`, so stopping
	// also removes it.
	defer func() { _ = sudoBare(rt, "stop", "-t", stopGrace, c2wBuildContainer).Run() }()

	// Run c2w in the builder image (rootful — mknod needs real root). The nested
	// dockerd stores pulled base images and the buildkit layer cache in
	// /var/lib/docker; back that with a persistent named volume so subsequent
	// runs reuse the cache instead of re-pulling ubuntu/rust/golang and
	// re-running every apt-get layer.
	// NOTE: the host output dir is mounted at /export, NOT /out. c2w's buildx
	// exports with --output type=local,dest=/ and replaces the top-level /out
	// entry — which fails with "device or resource busy" if /out is a bind
	// mountpoint. So c2w writes to a real /out inside the container and we copy
	// the result to the mounted /export afterward.
	cmd := sudoCtx(ctx, rt, "run", "--name", c2wBuildContainer, "--rm", "--privileged",
		"-v", imageTarPath+":/tmp/image.tar",
		"-v", absOutDir+":/export",
		"-v", c2wCacheVolume+":/var/lib/docker",
		c2wBuilderImage,
		"sh", "-c", `
export DOCKER_HOST=unix:///var/run/docker.sock
dockerd --log-level=error > /tmp/dockerd.log 2>&1 &
DOCKER_PID=$!

# On 'docker stop' (SIGTERM to this PID 1 shell), shut the nested dockerd down
# gracefully and wait for it, so /var/lib/docker (the cache volume) is flushed
# cleanly instead of being SIGKILLed mid-write.
trap 'kill -TERM $DOCKER_PID 2>/dev/null; wait $DOCKER_PID; exit 143' TERM INT

# Wait for daemon
i=0
while test $i -lt 60; do
  if docker ps > /dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if ! docker ps > /dev/null 2>&1; then
  echo "ERROR: Docker daemon failed to start"
  cat /tmp/dockerd.log
  exit 1
fi

docker load -q < /tmp/image.tar > /dev/null 2>&1
docker tag localhost/emojig-demo:latest emojig-demo:latest > /dev/null 2>&1

# Build a WASM-specific variant: same image but with /bin/bash as entrypoint.
# The Dockerfile entrypoint is 'ttyd' (a WebSocket server) which is correct for
# Docker/live mode but leaves WASM stdin/stdout unconnected. This trivial overlay
# (one config layer) doesn't bust the c2w Bochs toolchain cache.
docker build -q -t emojig-demo-wasm - << 'WASM_DOCKERFILE'
FROM emojig-demo
ENTRYPOINT ["/bin/bash", "--login"]
WASM_DOCKERFILE

# Run c2w, keeping the full log via tee while showing a filtered live view:
# only the first line of each buildkit step plus DONE/CACHED/ERROR markers.
# fflush() keeps awk from block-buffering so the view stays live, not bursty.
# The exit file captures c2w's real status (not tee/awk's).
echo "Running c2w (filtered live log — step headers + DONE)..."
{ c2w emojig-demo-wasm /out/out.wasm 2>&1; echo $? > /tmp/c2w.exit; } | tee /tmp/c2w.log | awk '
/^[[:space:]]*$/        { next }
/ DONE| CACHED| ERROR/  { print; fflush(); next }
/^#[0-9]+ /             { if (!seen[$1]++) print; fflush(); next }
                        { print; fflush() }
'
EXIT_CODE=$(cat /tmp/c2w.exit)

if test "$EXIT_CODE" -ne 0; then
  echo "── c2w failed — full log ──"
  cat /tmp/c2w.log
else
  # Assemble a servable page: drop the WASI-browser htdocs (index.html + loader
  # JS, kept in the builder image) alongside the generated /out/out.wasm.
  if ! cp -a /opt/c2w-htdocs/. /out/; then
    echo "ERROR: failed to copy htdocs"
    EXIT_CODE=1
  fi
  # The htdocs files hardcode paths from server root, but the demo serves them
  # from /wasm-out/ — repoint all root-relative imports there.
  # Also add DOCTYPE to avoid Quirks Mode in the iframe.
  sed -i '1s/^/<!DOCTYPE html>\n/' /out/index.html
  sed -i 's#/out.wasm"#/wasm-out/out.wasm"#' /out/index.html
  sed -i \
    's#"/browser_wasi_shim/#"/wasm-out/browser_wasi_shim/#g
     s#"/worker-util\.js"#"/wasm-out/worker-util.js"#g
     s#"/wasi-util\.js"#"/wasm-out/wasi-util.js"#g' \
    /out/worker.js /out/stack-worker.js
  # c2w wrote to the real (non-mounted) /out; copy everything into the
  # bind-mounted /export so it lands in the host output dir.
  if cp -a /out/. /export/; then
    echo "📦 Copied WASM + htdocs to host."
    echo "── build artifacts ──"
    du -sh /out/* /out/browser_wasi_shim/* 2>/dev/null | sort -rh
  else
    echo "ERROR: failed to copy output to /export"
    EXIT_CODE=1
  fi
fi

# Stop the nested dockerd and WAIT for it to finish flushing /var/lib/docker
# (the cache volume) before the container exits. Without the wait, PID 1 exits
# immediately, the container is torn down, and dockerd is SIGKILLed mid-write —
# leaving the buildkit cache uncommitted, so the next run starts cold.
kill -TERM $DOCKER_PID 2>/dev/null || true
wait $DOCKER_PID 2>/dev/null || true
exit "$EXIT_CODE"
`,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	// If ctx is cancelled and the `docker run` client doesn't exit promptly
	// after SIGKILL, force Wait to return so cmd.Run() unblocks and the
	// deferred rmBuildContainer cleanup can run.
	cmd.WaitDelay = 10 * time.Second

	// Watch the mounted output dir for progress while c2w runs silently.
	watchCtx, stopWatch := context.WithCancel(ctx)
	go watchOutDir(watchCtx, absOutDir)

	err := cmd.Run()
	stopWatch()
	// The rootful build writes into /out as root; hand the files back to the
	// user so the output dir isn't left root-owned (success or failure).
	chownToUser(absOutDir)
	if err != nil {
		fmt.Printf("⚠️  WASM compilation failed: %v\n", err)
		return false
	}

	fmt.Println("✅ Container compiled to WebAssembly!")
	return true
}

// ensureC2W checks if c2w is in PATH; if not, builds and installs it from source.
// Returns true if c2w is available (or was successfully installed), false otherwise.
func ensureC2W(ctx context.Context) bool {
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

	if err := runCmd(ctx, "git", "clone", "--depth=1", c2wRepo, tmpDir); err != nil {
		fmt.Printf("⚠️  Failed to clone c2w repo: %v\n", err)
		return false
	}

	homeDir, _ := os.UserHomeDir()
	binDir := filepath.Join(homeDir, ".local", "bin")
	_ = os.MkdirAll(binDir, 0755)
	binPath := filepath.Join(binDir, "c2w")

	cmd := exec.CommandContext(ctx, "go", "build", "-o", binPath, "./cmd/c2w")
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
func runC2W(ctx context.Context, imageName, outDir string) bool {
	fmt.Printf("🔄 Compiling container image to WebAssembly (this may take 1-5 minutes)...\n")
	cmd := exec.CommandContext(ctx, "c2w", imageName, outDir, "--to-js")
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

// crossOriginIsolated adds the COOP/COEP headers that put the page in a
// cross-origin-isolated context. The WASI-browser runtime uses SharedArrayBuffer
// and Atomics, which the browser only exposes when these headers are present.
func crossOriginIsolated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
		next.ServeHTTP(w, r)
	})
}

func main() {
	fmt.Println("====================================================")
	fmt.Println("      Emojig TUI Browser Sandbox — All Modes        ")
	fmt.Println("====================================================")

	// Cancel in-flight builds when the user hits Ctrl+C.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Step 1: Build static Musl binary for container compatibility.
	fmt.Println("Building statically linked Musl binary (zig-out/bin/emojig)...")
	if err := runCmd(ctx, "zig", "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseSmall"); err != nil {
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
		// Step 4: Build the container image (quiet; dump the log only on failure).
		fmt.Printf("🐳 Using runtime: %s — building image %q...\n", rt, imageName)
		buildCmd := exec.CommandContext(ctx, rt, "build", "-q", "-t", imageName, "-f", dockerfilePath, ".")
		if out, err := buildCmd.CombinedOutput(); err != nil {
			fmt.Printf("❌ Image build failed: %v\n%s", err, out)
			os.Exit(1)
		}
		fmt.Printf("✅ Image %q ready\n", imageName)

		// Step 5: Build WASM (cached unless deleted).
		wasmIndexPath := filepath.Join(wasmOutDir, "index.html")
		if _, err := os.Stat(wasmIndexPath); err == nil {
			fmt.Println("✅ WASM already built (cached)")
		} else {
			os.MkdirAll(wasmOutDir, 0755)
			fmt.Println("Building WebAssembly version...")
			if !buildC2WInDocker(ctx, rt, imageName, wasmOutDir) {
				fmt.Println("❌ Failed to build WASM. Exiting.")
				os.Exit(1)
			}
		}

		// Step 6: Stop any stale container, then start a fresh one.
		fmt.Printf("Starting container %q on port %s...\n", containerName, ttydPort)
		stopContainer(rt)
		if err := runCmd(ctx, rt, "run", "--rm", "-d", "-t",
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
	mux.Handle("/", crossOriginIsolated(http.FileServer(http.Dir("scripts"))))
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
	<-ctx.Done()

	fmt.Println("\n🛑 Shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	// deferred stopContainer / ttydCmd.Kill run here.
	fmt.Println("✅ All services stopped.")
}
