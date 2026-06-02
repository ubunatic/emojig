// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const dockerfileContent = `# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later

FROM alpine:3.20

# Configure environment locale for proper UTF-8 rendering
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install ttyd and system tools (including standard emoji-compatible fonts, mc, fzf, bash, and Go)
RUN apk add --no-cache ttyd shadow font-noto-emoji mc fzf bash go

# Create a non-root unprivileged demo user with bash shell
RUN useradd -m -s /bin/bash demo-user
WORKDIR /home/demo-user

# Copy native executable from the host build
COPY zig-out/bin/emojig /usr/local/bin/emojig

# Copy shell integration scripts
COPY src/shell /usr/local/share/emojig/shell

# Copy Go and helper scripts
COPY scripts /home/demo-user/scripts

# Configure bash_profile and bashrc for demo-user to automatically source Emojig keybinds and show help
RUN echo 'export EMOJIG_SAFE=true' >> /home/demo-user/.bash_profile && \
    echo 'export LANG=C.UTF-8' >> /home/demo-user/.bash_profile && \
    echo 'export LC_ALL=C.UTF-8' >> /home/demo-user/.bash_profile && \
    echo 'export PS1="\[\033[01;32m\]➜  \[\033[01;34m\]\W\[\033[00m\] "' >> /home/demo-user/.bash_profile && \
    echo 'source /usr/local/share/emojig/shell/emojig.bash' >> /home/demo-user/.bash_profile && \
    echo 'echo "👋 Welcome to the Emojig TUI Sandbox!"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Press: Ctrl-E                (to trigger the Emojig shell widget!)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: emojig --tui --safe   (to run the emoji picker manually)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: mc                   (to run Midnight Commander)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Type: fzf                  (to run fuzzy finder)"' >> /home/demo-user/.bash_profile && \
    echo 'echo "💡 Go Demos: go run scripts/test_tui.go"' >> /home/demo-user/.bash_profile && \
    echo 'echo ""' >> /home/demo-user/.bash_profile && \
    cp /home/demo-user/.bash_profile /home/demo-user/.bashrc && \
    chown -R demo-user:demo-user /home/demo-user

# Expose default ttyd port
EXPOSE 7681

# Run the app under ttyd as the demo-user with strict bounds:
# - '--once': exit the container when the session finishes or Ctrl-C is pressed.
# - '--writable': allow terminal inputs (required for interactive pickers).
USER demo-user
ENTRYPOINT ["ttyd", "-p", "7681", "--once", "--writable", "/bin/bash", "--login"]
`

const htmlContent = `<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Emojig - Interactive TUI Browser Sandbox</title>
    {{FAVICON}}
    <!-- Premium Fonts and Tailwind/Custom styles for the WOW factor -->
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css" />
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

        /* Subtle animated background gradient glow */
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
            position: relative;
            z-index: 10;
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
            
            <div id="terminal-wrapper" style="position: relative;">
                <div id="terminal"></div>
            </div>
            <div id="resize-bottom" class="resize-handle bottom"></div>

            <div style="display: flex; gap: 16px; align-items: center; justify-content: center; width: 100%; margin-top: 8px; flex-wrap: wrap;">
                <div style="color: #94a3b8; font-size: 0.9rem; text-align: center;">
                    Use <b>Arrow Keys</b> to navigate • Press <b>Enter</b> to copy/select • Press <b>Ctrl-C</b> to exit
                </div>
                <button id="btn-reset" class="ctrl-btn">Reset Session 🔄</button>
            </div>
        </div>

        <div class="instructions">
            <h3>Terminal Sandbox Features</h3>
            <ul>
                <li><b>High Fidelity:</b> Powered by <code>ttyd</code> streaming standard POSIX pseudoterminal (PTY) boundaries.</li>
                <li><b>Interactive Mouse:</b> Fully supports hover interactions and click-to-copy sequences via SGR mouse coordinates.</li>
                <li><b>Safe Mode:</b> Automatically runs with <code>--safe</code> to strip browser emoji variations for pixel-perfect column grid alignment.</li>
            </ul>
        </div>
    </div>

    <!-- Load xterm.js and Unicode 11 addon from CDN -->
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xterm-addon-unicode11@0.7.0/lib/xterm-addon-unicode11.js"></script>
    <script>
        // Setup xterm.js instance matching standard ANSI layout (80x24)
        const term = new Terminal({
            cols: 80,
            rows: 24,
            cursorBlink: true,
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
                
                // Send initial JSON handshake to ttyd to spawn the child process
                // The JSON string itself starts with '{' (0x7B), which acts as the ttyd JSON opcode.
                const handshake = JSON.stringify({ AuthToken: "" });
                socket.send(new TextEncoder().encode(handshake));
                
                // Send terminal resize command to ttyd
                // Format: '1' (0x31) + JSON containing columns and rows
                const resizeMsg = JSON.stringify({ columns: term.cols, rows: term.rows });
                const payload = new Uint8Array([0x31, ...new TextEncoder().encode(resizeMsg)]);
                socket.send(payload);
            };

            // Handle TTYD protocol opcode-based server-to-client frames
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

        // Drag-to-resize terminal layout handling (syncs xterm rows and ttyd container sizes)
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

                // Proportional monospace JetBrains Mono line-height mapping
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
                termElement.style.pointerEvents = 'none'; // Disable pointer events to prevent xterm selecting issues during drag
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
    </script>
</body>
</html>
`

func main() {
	fmt.Println("====================================================")
	fmt.Println("       Emojig TUI Browser Sandbox Prototyper        ")
	fmt.Println("====================================================")

	// Step 1: Ensure static Musl binary is compiled for container compatibility
	binPath := filepath.Join("zig-out", "bin", "emojig")
	fmt.Println("Ensuring statically linked Musl binary (zig-out/bin/emojig) is compiled...")
	buildCmd := exec.Command("zig", "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseSmall")
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		fmt.Printf("❌ Failed to compile emojig: %v\n", err)
		fmt.Println("Please ensure Zig is installed and try again.")
		os.Exit(1)
	}
	fmt.Println("✅ Musl compilation successful!")

	// Step 2: Auto-generate the demo files
	dockerfilePath := filepath.Join("scripts", "demo.Dockerfile")
	err := os.WriteFile(dockerfilePath, []byte(dockerfileContent), 0644)
	if err != nil {
		fmt.Printf("❌ Failed to write Dockerfile: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("📝 Generated sandbox Dockerfile: %s\n", dockerfilePath)

	// Read the SVG icon and encode it as a base64 favicon
	var faviconTag string
	svgPath := filepath.Join("src", "assets", "emojig-icon.web.svg")
	if svgBytes, err := os.ReadFile(svgPath); err == nil {
		base64Svg := base64.StdEncoding.EncodeToString(svgBytes)
		faviconTag = fmt.Sprintf("\n    <link rel=\"icon\" type=\"image/svg+xml\" href=\"data:image/svg+xml;base64,%s\" />", base64Svg)
	}
	finalHtml := strings.ReplaceAll(htmlContent, "{{FAVICON}}", faviconTag)

	htmlPath := filepath.Join("scripts", "demo.html")
	err = os.WriteFile(htmlPath, []byte(finalHtml), 0644)
	if err != nil {
		fmt.Printf("❌ Failed to write demo HTML: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("📝 Generated client-side HTML:   %s\n", htmlPath)

	// Step 3: Check if local ttyd is installed
	_, ttydErr := exec.LookPath("ttyd")

	if ttydErr != nil {
		// Local ttyd is missing - serve Docker instruction
		fmt.Println("\n----------------------------------------------------")
		fmt.Println("ℹ️  Local 'ttyd' installation not found in PATH.")
		fmt.Println("   To run the interactive browser demo in a secure container sandbox:")
		fmt.Println("----------------------------------------------------")
		fmt.Println("1. Build the Docker container image:")
		fmt.Printf("   $ docker build -t emojig-demo -f %s .\n\n", dockerfilePath)
		fmt.Println("2. Run the sandboxed container:")
		fmt.Println("   $ docker run --rm -d -t -p 7681:7681 emojig-demo\n")
		fmt.Println("3. Open the client interface in your browser:")
		fmt.Printf("   Simply open the file in your browser or run a simple local webserver:\n")
		fmt.Printf("   $ python3 -m http.server 8080 --directory scripts/\n")
		fmt.Println("   Then navigate to http://localhost:8080/demo.html to view and interact!")
		fmt.Println("====================================================")
	} else {
		// Local ttyd is present - offer to spawn directly!
		fmt.Println("\n🎉 Local 'ttyd' detected! Ready to serve direct interactive session.")
		fmt.Println("Starting ttyd background service...")
		
		ttydCmd := exec.Command("ttyd", "-p", "7681", "--once", "--writable", binPath, "--tui", "--safe")
		ttydCmd.Stdout = os.Stdout
		ttydCmd.Stderr = os.Stderr
		
		if err := ttydCmd.Start(); err != nil {
			fmt.Printf("❌ Failed to start ttyd: %v\n", err)
			os.Exit(1)
		}
		
		fmt.Println("🚀 Interactive TUI server running on port 7681!")
		fmt.Printf("👉 Open %s directly in your browser to play with the picker!\n", htmlPath)
		fmt.Println("Press Ctrl+C to terminate.")
		
		// Wait for command to finish
		_ = ttydCmd.Wait()
	}
}
