const std = @import("std");
const Io = std.Io;
const emojig = @import("emojig");

const Match = struct {
    index: usize,
    score: i32,
};

var global_orig_termios: ?std.posix.termios = null;

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(std.posix.STDIN_FILENO, .NOW, &orig);
    }
    // Disable mouse tracking, exit alternate screen, show cursor
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25h", 28);
    std.process.exit(1);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        const err = std.posix.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) return error.Unexpected;
            index += rc;
        } else if (err == .INTR) {
            continue;
        } else {
            return error.SystemResources;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    // Switch to alternate screen, enable mouse tracking, hide cursor
    const stdout_fd = std.posix.STDOUT_FILENO;
    try writeAll(stdout_fd, "\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l");
    
    // Save and configure raw termios
    const stdin_fd = std.posix.STDIN_FILENO;
    const orig_termios = try std.posix.tcgetattr(stdin_fd);
    global_orig_termios = orig_termios;
    
    // Register signal handlers to restore terminal on SIGINT/SIGTERM
    var act = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    
    var raw = orig_termios;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    
    raw.oflag.OPOST = false;
    
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    
    const system = std.posix.system;
    raw.cc[@intFromEnum(system.V.MIN)] = 1;
    raw.cc[@intFromEnum(system.V.TIME)] = 0;
    
    try std.posix.tcsetattr(stdin_fd, .NOW, raw);
    
    defer {
        // Restore termios, disable mouse tracking, exit alternate screen, show cursor
        std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
        writeAll(stdout_fd, "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25h") catch {};
    }
    
    var query_buf: [64]u8 = undefined;
    var query_len: usize = 0;
    
    var selected_idx: usize = 0;
    var top_matches: [10]Match = undefined;
    var top_count: usize = 0;
    
    var should_copy_and_exit = false;
    
    // Initial search
    search(query_buf[0..query_len], &top_matches, &top_count);
    
    var read_buf: [32]u8 = undefined;
    
    while (true) {
        // 1. Draw screen
        try writeAll(stdout_fd, "\x1b[H"); // Cursor to 1,1
        
        var line_buf: [512]u8 = undefined;
        
        // Draw Header
        const search_line = try std.fmt.bufPrint(&line_buf, "🔍 Search: {s}\x1b[K\n", .{query_buf[0..query_len]});
        try writeAll(stdout_fd, search_line);
        
        // Draw list of matches
        var row: usize = 0;
        while (row < 10) : (row += 1) {
            if (row < top_count) {
                const m = top_matches[row];
                const entry = emojig.EmojiDb.getEntry(m.index);
                
                const line = if (row == selected_idx)
                    try std.fmt.bufPrint(&line_buf, " \x1b[1;36m>\x1b[0m \x1b[1m{s}\x1b[0m  {s}\x1b[K\n", .{ entry.emoji, entry.name })
                else
                    try std.fmt.bufPrint(&line_buf, "   {s}  {s}\x1b[K\n", .{ entry.emoji, entry.name });
                
                try writeAll(stdout_fd, line);
            } else {
                try writeAll(stdout_fd, "\x1b[K\n");
            }
        }
        
        if (should_copy_and_exit) {
            if (top_count > 0 and selected_idx < top_count) {
                const selected = emojig.EmojiDb.getEntry(top_matches[selected_idx].index);
                copyToClipboard(init, selected.emoji) catch {};
            }
            break;
        }
        
        // 2. Read input
        const n = try std.posix.read(stdin_fd, &read_buf);
        if (n == 0) break; // EOF
        
        const bytes = read_buf[0..n];
        
        if (bytes[0] == 27) {
            // Escape sequences
            if (n == 1) {
                // ESC key
                break;
            } else if (n > 2 and bytes[1] == '[') {
                if (bytes[2] == 'A') {
                    // Up arrow
                    if (selected_idx > 0) {
                        selected_idx -= 1;
                    } else if (top_count > 0) {
                        selected_idx = top_count - 1;
                    }
                } else if (bytes[2] == 'B') {
                    // Down arrow
                    if (top_count > 0) {
                        if (selected_idx < top_count - 1) {
                            selected_idx += 1;
                        } else {
                            selected_idx = 0;
                        }
                    }
                } else if (bytes[2] == '<') {
                    // SGR Mouse Event
                    // Format: \x1b[<button;col;rowM or \x1b[<button;col;rowm
                    var it = std.mem.splitScalar(u8, bytes[3..], ';');
                    const button_str = it.next() orelse continue;
                    const col_str = it.next() orelse continue;
                    const rest = it.next() orelse continue;
                    
                    const button = std.fmt.parseInt(i32, button_str, 10) catch continue;
                    _ = col_str;
                    
                    if (rest.len > 0) {
                        const action_char = rest[rest.len - 1];
                        const row_str = rest[0 .. rest.len - 1];
                        const click_row = std.fmt.parseInt(i32, row_str, 10) catch continue;
                        
                        // Left click press
                        if (button == 0 and action_char == 'M') {
                            // Row 1 is Search box, Row 2 is index 0
                            if (click_row >= 2 and click_row <= 11) {
                                const clicked_idx = @as(usize, @intCast(click_row - 2));
                                if (clicked_idx < top_count) {
                                    selected_idx = clicked_idx;
                                    should_copy_and_exit = true;
                                }
                            }
                        }
                    }
                }
            }
        } else if (bytes[0] == 127 or bytes[0] == 8) {
            // Backspace
            if (query_len > 0) {
                query_len -= 1;
                selected_idx = 0;
                search(query_buf[0..query_len], &top_matches, &top_count);
            }
        } else if (bytes[0] == 10 or bytes[0] == 13) {
            // Enter key
            should_copy_and_exit = true;
        } else if (bytes[0] == 3 or bytes[0] == 4) {
            // Ctrl-C or Ctrl-D
            break;
        } else {
            // Add printable characters
            for (bytes) |b| {
                if (b >= 32 and b <= 126 and query_len < 63) {
                    query_buf[query_len] = b;
                    query_len += 1;
                    selected_idx = 0;
                    search(query_buf[0..query_len], &top_matches, &top_count);
                }
            }
        }
    }
}

fn search(query: []const u8, top_matches: *[10]Match, top_count: *usize) void {
    top_count.* = 0;
    
    var i: usize = 0;
    while (i < emojig.EmojiDb.count) : (i += 1) {
        const entry = emojig.EmojiDb.getEntry(i);
        if (emojig.fuzzyMatch(query, entry.search)) |score| {
            const m = Match{ .index = i, .score = score };
            
            // Insert into sorted top_matches (descending order)
            var insert_pos: usize = 0;
            while (insert_pos < top_count.*) : (insert_pos += 1) {
                if (m.score > top_matches[insert_pos].score) break;
            }
            
            if (insert_pos < 10) {
                var shift: usize = @min(top_count.*, 9);
                while (shift > insert_pos) : (shift -= 1) {
                    top_matches[shift] = top_matches[shift - 1];
                }
                top_matches[insert_pos] = m;
                if (top_count.* < 10) top_count.* += 1;
            }
        }
    }
}

fn copyToClipboard(init: std.process.Init, text: []const u8) !void {
    const io = init.io;
    
    // Attempt wl-copy (Wayland native)
    if (std.process.spawn(io, .{
        .argv = &.{ "wl-copy" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |spawned| {
        var child = spawned;
        try writeAll(child.stdin.?.handle, text);
        child.stdin.?.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        return;
    } else |_| {
        // Fallback to xclip (XWayland/X11)
        var child = try std.process.spawn(io, .{
            .argv = &.{ "xclip", "-selection", "clipboard" },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        try writeAll(child.stdin.?.handle, text);
        child.stdin.?.close(io);
        child.stdin = null;
        _ = try child.wait(io);
    }
}
