// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const shell_sh = @embedFile("shell/emojig.sh");
const shell_zsh = @embedFile("shell/emojig.zsh");
const shell_bash = @embedFile("shell/emojig.bash");
const shell_fish = @embedFile("shell/emojig.fish");
const icon_svg = @embedFile("assets/emojig-icon.web.svg");
const icon_png = @embedFile("assets/emojig-icon.png");

inline fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    _ = std.posix.system.write(fd, bytes.ptr, bytes.len);
}

pub fn ensureDirExists(home: []const u8, sub_path: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, sub_path }) catch return;
    if (path.len + 1 > path_buf.len) return;
    path_buf[path.len] = 0;
    _ = std.c.mkdir(path_buf[0..path.len :0], 0o755);
}

pub fn ensureDesktopIntegration(io: std.Io, home: []const u8, exe_path: []const u8) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/applications");
    ensureDirExists(home, ".local/share/icons");
    ensureDirExists(home, ".local/share/icons/hicolor");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable/apps");
    ensureDirExists(home, ".local/share/icons/hicolor/128x128");
    ensureDirExists(home, ".local/share/icons/hicolor/128x128/apps");

    var exec_path_buf: [1024]u8 = undefined;
    var exec_path: []const u8 = exe_path;
    if (std.mem.indexOf(u8, exe_path, ".zig-cache") != null or std.mem.indexOf(u8, exe_path, "zig-out") != null) {
        const local_bin = std.fmt.bufPrint(&exec_path_buf, "{s}/.local/bin/emojig", .{home}) catch "";
        if (local_bin.len > 0) {
            if (std.posix.openat(std.posix.AT.FDCWD, local_bin, std.posix.O{ .ACCMODE = .RDONLY }, 0)) |fd| {
                _ = std.posix.system.close(fd);
                exec_path = local_bin;
            } else |_| {}
        }
    }

    // Write .desktop entry
    var desktop_path_buf: [512]u8 = undefined;
    const desktop_path = std.fmt.bufPrint(&desktop_path_buf, "{s}/.local/share/applications/emojig-picker.desktop", .{home}) catch return;
    var desktop_content: [2048]u8 = undefined;
    const desktop_text = std.fmt.bufPrint(&desktop_content,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Emojig Picker
        \\Comment=Interactive emoji picker
        \\Exec={s} --gui
        \\Icon={s}/.local/share/icons/emojig-picker.png
        \\Terminal=false
        \\Categories=Utility;
        \\StartupWMClass=emojig-picker
        \\
    , .{ exec_path, home }) catch return;

    if (desktop_path.len + 1 <= desktop_path_buf.len) {
        desktop_path_buf[desktop_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, desktop_path_buf[0..desktop_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, desktop_text.ptr, desktop_text.len);
        } else |_| {}
    }

    // Write SVG icon
    var svg_path_buf: [512]u8 = undefined;
    const svg_path = std.fmt.bufPrint(&svg_path_buf, "{s}/.local/share/icons/hicolor/scalable/apps/emojig-picker.svg", .{home}) catch return;
    const svg_text = icon_svg;
    if (svg_path.len + 1 <= svg_path_buf.len) {
        svg_path_buf[svg_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, svg_path_buf[0..svg_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, svg_text.ptr, svg_text.len);
        } else |_| {}
    }

    // Write PNG icon to hicolor 128x128/apps
    var png_path_buf: [512]u8 = undefined;
    const png_path = std.fmt.bufPrint(&png_path_buf, "{s}/.local/share/icons/hicolor/128x128/apps/emojig-picker.png", .{home}) catch return;
    const png_data = icon_png;
    if (png_path.len + 1 <= png_path_buf.len) {
        png_path_buf[png_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, png_path_buf[0..png_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, png_data.ptr, png_data.len);
        } else |_| {}
    }

    // Write PNG icon directly to share/icons fallback
    var png_fallback_buf: [512]u8 = undefined;
    const png_fallback_path = std.fmt.bufPrint(&png_fallback_buf, "{s}/.local/share/icons/emojig-picker.png", .{home}) catch return;
    if (png_fallback_path.len + 1 <= png_fallback_buf.len) {
        png_fallback_buf[png_fallback_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, png_fallback_buf[0..png_fallback_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, png_data.ptr, png_data.len);
        } else |_| {}
    }

    // Run update-desktop-database
    var app_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&app_dir_buf, "{s}/.local/share/applications", .{home})) |app_dir| {
        var child = std.process.spawn(io, .{
            .argv = &.{ "update-desktop-database", app_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
        if (child) |*c| {
            _ = c.wait(io) catch {};
        }
    } else |_| {}

    // Run gtk-update-icon-cache
    var icon_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&icon_dir_buf, "{s}/.local/share/icons/hicolor", .{home})) |icon_dir| {
        var child = std.process.spawn(io, .{
            .argv = &.{ "gtk-update-icon-cache", "-f", "-t", icon_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
        if (child) |*c| {
            _ = c.wait(io) catch {};
        }
    } else |_| {}
}

pub fn printCompletion(shell: []const u8, key: ?[]const u8) void {
    if (key) |k| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "EMOJIG_KEY='{s}'\n", .{k}) catch return;
        writeAll(std.posix.STDOUT_FILENO, line) catch {};
    }
    const script = if (std.mem.eql(u8, shell, "bash"))
        shell_bash
    else if (std.mem.eql(u8, shell, "fish"))
        shell_fish
    else if (std.mem.eql(u8, shell, "sh"))
        shell_sh
    else
        shell_zsh;
    writeAll(std.posix.STDOUT_FILENO, script) catch {};
}

pub fn detectShell(environ: anytype) []const u8 {
    const shell_env = environ.get("SHELL") orelse return "zsh";
    var it = std.mem.splitScalar(u8, shell_env, '/');
    var last: []const u8 = shell_env;
    while (it.next()) |part| {
        if (part.len > 0) last = part;
    }
    if (std.mem.eql(u8, last, "bash")) return "bash";
    if (std.mem.eql(u8, last, "fish")) return "fish";
    return "zsh";
}

pub fn writeFile(path_buf: []u8, path: []const u8, content: []const u8) bool {
    if (path.len + 1 > path_buf.len) return false;
    path_buf[path.len] = 0;
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], wf, 0o644) catch return false;
    defer _ = std.posix.system.close(fd);
    _ = std.posix.system.write(fd, content.ptr, content.len);
    return true;
}

pub fn copyBinary(io: std.Io, home: []const u8) bool {
    var src_buf: [1024]u8 = undefined;
    const src_len = std.process.executablePath(io, &src_buf) catch return false;
    const src_path = src_buf[0..src_len];

    var dst_buf: [1024]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/.local/bin/emojig", .{home}) catch return false;

    // Skip copy if already running from the destination.
    if (std.mem.eql(u8, src_path, dst_path)) return true;

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    if (src_path.len + 1 > src_buf.len) return false;
    src_buf[src_len] = 0;
    const src_fd = std.posix.openat(std.posix.AT.FDCWD, src_buf[0..src_len :0], rf, 0) catch return false;
    defer _ = std.posix.system.close(src_fd);

    if (dst_path.len + 1 > dst_buf.len) return false;
    dst_buf[dst_path.len] = 0;
    _ = std.posix.system.unlink(dst_buf[0..dst_path.len :0]);
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const dst_fd = std.posix.openat(std.posix.AT.FDCWD, dst_buf[0..dst_path.len :0], wf, 0o755) catch return false;
    defer _ = std.posix.system.close(dst_fd);

    var copy_buf: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(src_fd, &copy_buf) catch break;
        if (n == 0) break;
        _ = std.posix.system.write(dst_fd, copy_buf[0..n].ptr, n);
    }
    return true;
}

pub fn fileExists(home: []const u8, rel: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, rel }) catch return false;
    if (path.len + 1 > path_buf.len) return false;
    path_buf[path.len] = 0;
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], rf, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

pub fn fileExistsAbs(comptime path: [:0]const u8) bool {
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, rf, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

pub fn captureShellCmd(io: std.Io, home: []const u8, cmd: []const u8, out: []u8) []const u8 {
    const log = "/tmp/emojig-update.log";
    var sh_buf: [2048]u8 = undefined;
    // Prepend well-known tool directories so the command finds zig/brew/etc.
    // even when launched from a desktop GUI with a stripped PATH.
    const sh_cmd = std.fmt.bufPrint(
        &sh_buf,
        "export PATH=\"/home/linuxbrew/.linuxbrew/bin:{s}/.linuxbrew/bin:{s}/.local/bin:/usr/local/bin:$PATH\"; {s} >{s} 2>&1",
        .{ home, home, cmd, log },
    ) catch {
        const msg = "Command string too long.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", sh_cmd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        const msg = "Failed to start update process.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    _ = child.wait(io) catch {};

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, log, rf, 0) catch {
        const msg = "Update complete (no log).";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    defer _ = std.posix.system.close(fd);
    const n = std.posix.system.read(fd, out.ptr, out.len);
    const read_len = if (n > 0) @as(usize, @intCast(n)) else 0;
    if (read_len == 0) {
        const msg = "Update complete.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    }
    return out[0..read_len];
}

pub fn runUpdate(io: std.Io, home: []const u8, cfg_cmd: ?[]const u8, spec_cmd: ?[]const u8, out: []u8) []const u8 {
    var cmd_buf: [512]u8 = undefined;
    // Priority: config file > spec/commands.json cmd > auto-detect.
    var cmd: ?[]const u8 = if (cfg_cmd != null) cfg_cmd else spec_cmd;

    if (cmd != null) {
        // Explicit command configured — skip auto-detection.
    } else if (fileExists(home, "projects/emojig")) {
        cmd = std.fmt.bufPrint(&cmd_buf, "make -C '{s}/projects/emojig' update", .{home}) catch null;
    } else if (fileExistsAbs("/var/lib/dpkg/info/emojig.list")) {
        cmd = "sudo apt-get install -y emojig";
    } else if (fileExists(home, ".local/bin/emojig")) {
        cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";
    }

    if (cmd) |c| return captureShellCmd(io, home, c, out);

    const msg = "Unknown install mode.\nSee ~/.local/share/emojig/ for details.";
    const len = @min(msg.len, out.len);
    @memcpy(out[0..len], msg[0..len]);
    return out[0..len];
}

pub fn sourceRcFileAbs(path: []const u8, line: []const u8, marker: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    if (path.len + 1 > path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z = path_buf[0..path.len :0];

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    if (std.posix.openat(std.posix.AT.FDCWD, path_z, rf, 0)) |rfd| {
        defer _ = std.posix.system.close(rfd);
        var content: [16384]u8 = undefined;
        const n = std.posix.read(rfd, &content) catch 0;
        if (std.mem.indexOf(u8, content[0..n], marker) != null) return false;
    } else |_| {}

    const af = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const afd = std.posix.openat(std.posix.AT.FDCWD, path_z, af, 0o644) catch return false;
    defer _ = std.posix.system.close(afd);
    _ = std.posix.system.write(afd, line.ptr, line.len);
    return true;
}

pub fn sourceRcFile(home: []const u8, rc_rel: []const u8, line: []const u8, marker: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, rc_rel }) catch return false;
    return sourceRcFileAbs(path, line, marker);
}

pub fn installShellIntegration(io: std.Io, home: []const u8, shell: []const u8, rc_override: ?[]const u8, writer: anytype) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/bin");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/emojig");
    ensureDirExists(home, ".local/share/emojig/shell");

    const bin_ok = copyBinary(io, home);

    var buf: [512]u8 = undefined;

    const sh_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.sh", .{home}) catch return;
    _ = writeFile(&buf, sh_path, shell_sh);

    const zsh_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.zsh", .{home}) catch return;
    _ = writeFile(&buf, zsh_path, shell_zsh);

    const bash_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.bash", .{home}) catch return;
    _ = writeFile(&buf, bash_path, shell_bash);

    const fish_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.fish", .{home}) catch return;
    _ = writeFile(&buf, fish_path, shell_fish);

    var dst_buf: [1024]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/.local/bin/emojig", .{home}) catch "";
    if (dst_path.len > 0) {
        ensureDesktopIntegration(io, home, dst_path);
    }

    if (bin_ok) {
        writer.writeAll("Installed binary to ~/.local/bin/emojig\n") catch {};
    } else {
        writer.writeAll("Warning: could not copy binary to ~/.local/bin/emojig\n") catch {};
    }

    writer.writeAll("Installed shell integration to ~/.local/share/emojig/shell/\n") catch {};

    // Fish cannot source POSIX sh — use emojig.fish directly in config.fish.
    // All other shells (zsh, bash, unknown) use the generic emojig.sh dispatcher.
    const is_fish = std.mem.eql(u8, shell, "fish");
    const sh_source_line = "\nif test -f ~/.local/share/emojig/shell/emojig.sh\nthen source ~/.local/share/emojig/shell/emojig.sh\nfi\n";
    const sh_marker = "emojig/shell/emojig.sh";
    const fish_source_line = "\nif test -f ~/.local/share/emojig/shell/emojig.fish\n  source ~/.local/share/emojig/shell/emojig.fish\nend\n";
    const fish_marker = "emojig/shell/emojig.fish";

    if (rc_override) |rc| {
        // --rc always uses the sh dispatcher (fish users don't set --rc to a sh file).
        var abs_buf: [512]u8 = undefined;
        const abs_path = if (rc[0] == '/')
            rc
        else
            (std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ home, rc }) catch return);
        const added = sourceRcFileAbs(abs_path, sh_source_line, sh_marker);
        var msg_buf: [512]u8 = undefined;
        const display = if (rc[0] == '/') rc else (std.fmt.bufPrint(&msg_buf, "~/{s}", .{rc}) catch rc);
        var out_buf: [600]u8 = undefined;
        if (added) {
            const out = std.fmt.bufPrint(&out_buf, "Added to {s} — reload your shell and press Ctrl+E.\n", .{display}) catch return;
            writer.writeAll(out) catch {};
        } else {
            const out = std.fmt.bufPrint(&out_buf, "Already in {s} — press Ctrl+E at any prompt.\n", .{display}) catch return;
            writer.writeAll(out) catch {};
        }
    } else if (is_fish) {
        ensureDirExists(home, ".config");
        ensureDirExists(home, ".config/fish");
        const added = sourceRcFile(home, ".config/fish/config.fish", fish_source_line, fish_marker);
        if (added) {
            writer.writeAll("Added to ~/.config/fish/config.fish — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.config/fish/config.fish — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (fileExists(home, ".userrc")) {
        const added = sourceRcFile(home, ".userrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.userrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.userrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (std.mem.eql(u8, shell, "zsh")) {
        const added = sourceRcFile(home, ".zshrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.zshrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.zshrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (std.mem.eql(u8, shell, "bash")) {
        const added = sourceRcFile(home, ".bashrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.bashrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.bashrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else {
        writer.writeAll("\nAdd one line to your shell rc file:\n\n" ++
            "  zsh/bash  (~/.zshrc or ~/.bashrc):\n" ++
            "    source ~/.local/share/emojig/shell/emojig.sh\n\n" ++
            "  fish (~/.config/fish/config.fish):\n" ++
            "    source ~/.local/share/emojig/shell/emojig.fish\n\n" ++
            "Then reload your shell and press Ctrl+E at any prompt.\n") catch {};
    }
}
