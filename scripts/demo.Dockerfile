# SPDX-FileCopyrightText: 2026 Uwe Jugel
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
