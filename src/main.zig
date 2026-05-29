const std = @import("std");
const Io = std.Io;
const emojig = @import("emojig");

const Match = struct {
    index: usize,
    score: i32,
};

const Theme = enum {
    dark,
    light,
};

const Palette = struct {
    selection_bg: []const u8,
    search_prompt: []const u8,
    empty_cell: []const u8,
    search_row_bg: []const u8,   // background for the search input bar
    search_row_fg: []const u8,   // foreground text colour for the search row
};

const dark_palette = Palette{
    .selection_bg = "\x1b[48;5;30m",
    .search_prompt = "🔍",
    .empty_cell = "   ",
    .search_row_bg = "\x1b[48;5;236m",   // dark blue-grey input field
    .search_row_fg = "\x1b[38;5;255m",   // near-white text
};

const light_palette = Palette{
    .selection_bg = "\x1b[48;5;153m\x1b[38;5;235m",
    .search_prompt = "\x1b[38;5;235m🔍\x1b[0m",
    .empty_cell = "   ",
    .search_row_bg = "\x1b[48;5;189m",   // pale blue-grey input field
    .search_row_fg = "\x1b[38;5;235m",   // dark text
};

// ---------------------------------------------------------------------------
// MRU (Most Recently Used) emoji tracking
// ---------------------------------------------------------------------------
const MAX_MRU = 24;
var mru_buf: [MAX_MRU][32]u8 = undefined; // raw UTF-8 bytes per emoji
var mru_lens: [MAX_MRU]u8 = undefined;    // byte lengths
var mru_count: usize = 0;

/// Load MRU list from ~/.config/emojig/mru.json at startup.
/// Silently returns if the file is missing or malformed.
/// No heap allocations — uses only stack buffers.
fn loadMru() void {
    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/emojig/mru.json", .{home}) catch return;
    // null-terminate for openat
    if (path.len + 1 > path_buf.len) return;
    path_buf[path.len] = 0;

    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], flags, 0) catch return;
    defer _ = std.posix.system.close(fd);

    var file_buf: [4096]u8 = undefined;
    const len = std.posix.read(fd, &file_buf) catch return;
    if (len == 0) return;
    const content = file_buf[0..len];

    // Simple JSON parser: find '[', then scan "..." strings
    var pos: usize = 0;
    // Find opening '['
    while (pos < content.len and content[pos] != '[') pos += 1;
    if (pos >= content.len) return;
    pos += 1; // skip '['

    mru_count = 0;
    while (pos < content.len and mru_count < MAX_MRU) {
        // Skip whitespace and commas
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or
            content[pos] == '\r' or content[pos] == '\n' or content[pos] == ',')) {
            pos += 1;
        }
        if (pos >= content.len or content[pos] == ']') break;
        if (content[pos] != '"') { pos += 1; continue; }
        pos += 1; // skip opening '"'

        // Read until closing '"'
        var emoji_len: usize = 0;
        while (pos < content.len and content[pos] != '"' and emoji_len < 31) {
            mru_buf[mru_count][emoji_len] = content[pos];
            emoji_len += 1;
            pos += 1;
        }
        if (pos < content.len and content[pos] == '"') pos += 1; // skip closing '"'
        if (emoji_len == 0) continue;
        mru_lens[mru_count] = @intCast(emoji_len);
        mru_count += 1;
    }
}

/// Save the current MRU list to ~/.config/emojig/mru.json.
/// Prepends `emoji` to the front, deduplicates, and caps at MAX_MRU.
/// No heap allocations — uses only stack buffers.
fn saveMru(emoji: []const u8) void {
    if (emoji.len == 0 or emoji.len > 31) return;

    // Build new MRU: prepend emoji, remove duplicate, cap at MAX_MRU
    var new_buf: [MAX_MRU][32]u8 = undefined;
    var new_lens: [MAX_MRU]u8 = undefined;
    var new_count: usize = 0;

    // Copy new emoji into slot 0
    @memcpy(new_buf[0][0..emoji.len], emoji);
    new_lens[0] = @intCast(emoji.len);
    new_count = 1;

    // Append existing entries, skipping the duplicate
    var i: usize = 0;
    while (i < mru_count and new_count < MAX_MRU) : (i += 1) {
        const existing = mru_buf[i][0..mru_lens[i]];
        if (std.mem.eql(u8, existing, emoji)) continue; // skip duplicate
        @memcpy(new_buf[new_count][0..mru_lens[i]], existing);
        new_lens[new_count] = mru_lens[i];
        new_count += 1;
    }

    // Update global state
    @memcpy(mru_buf[0..new_count], new_buf[0..new_count]);
    @memcpy(mru_lens[0..new_count], new_lens[0..new_count]);
    mru_count = new_count;

    // Write to file
    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    var path_buf: [512]u8 = undefined;
    const config_dir = std.fmt.bufPrint(&path_buf, "{s}/.config/emojig", .{home}) catch return;
    if (config_dir.len + 1 > path_buf.len) return;
    path_buf[config_dir.len] = 0;

    // Create config directory if missing (ignore errors — both dirs may already exist)
    var dot_config_buf: [512]u8 = undefined;
    const dot_config = std.fmt.bufPrint(&dot_config_buf, "{s}/.config", .{home}) catch return;
    if (dot_config.len + 1 > dot_config_buf.len) return;
    dot_config_buf[dot_config.len] = 0;
    _ = std.c.mkdir(dot_config_buf[0..dot_config.len :0], 0o755);
    _ = std.c.mkdir(path_buf[0..config_dir.len :0], 0o755);

    var file_path_buf: [520]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/mru.json", .{config_dir}) catch return;
    if (file_path.len + 1 > file_path_buf.len) return;
    file_path_buf[file_path.len] = 0;

    const wr_flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, file_path_buf[0..file_path.len :0], wr_flags, 0o644) catch return;
    defer _ = std.posix.system.close(fd);

    // Serialise to JSON: ["e1","e2",...]
    var json_buf: [2048]u8 = undefined;
    var jpos: usize = 0;
    json_buf[jpos] = '['; jpos += 1;
    var j: usize = 0;
    while (j < mru_count) : (j += 1) {
        if (j > 0) { json_buf[jpos] = ','; jpos += 1; }
        json_buf[jpos] = '"'; jpos += 1;
        const esl = mru_lens[j];
        @memcpy(json_buf[jpos..][0..esl], mru_buf[j][0..esl]);
        jpos += esl;
        json_buf[jpos] = '"'; jpos += 1;
    }
    json_buf[jpos] = ']'; jpos += 1;

    _ = std.posix.system.write(fd, json_buf[0..jpos].ptr, jpos);
}

// ---------------------------------------------------------------------------

var global_orig_termios: ?std.posix.termios = null;

fn logMemoryUsage() void {
    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", flags, 0) catch return;
    defer _ = std.posix.system.close(fd);
    
    var buf: [128]u8 = undefined;
    const len = std.posix.read(fd, &buf) catch return;
    if (len == 0) return;
    
    var it = std.mem.splitScalar(u8, buf[0..len], ' ');
    const virt_pages_str = it.next() orelse return;
    const rss_pages_str = it.next() orelse return;
    
    const virt_pages = std.fmt.parseInt(usize, std.mem.trim(u8, virt_pages_str, " \t\r\n"), 10) catch return;
    const rss_pages = std.fmt.parseInt(usize, std.mem.trim(u8, rss_pages_str, " \t\r\n"), 10) catch return;
    
    const page_size: usize = 4096; // Standard Linux page size
    const virt_bytes = virt_pages * page_size;
    const rss_bytes = rss_pages * page_size;
    
    // Open log file (/tmp/emojig.log)
    const wr_flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_fd = std.posix.openat(std.posix.AT.FDCWD, "/tmp/emojig.log", wr_flags, 0o644) catch return;
    defer _ = std.posix.system.close(log_fd);
    
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    
    var log_buf: [256]u8 = undefined;
    const log_line = std.fmt.bufPrint(&log_buf, "[{d}] Emojig closed. Memory Usage: VIRT = {d:.2} MB, RSS = {d:.2} MB\n", .{
        ts.sec,
        @as(f64, @floatFromInt(virt_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(rss_bytes)) / (1024.0 * 1024.0),
    }) catch return;
    
    _ = std.posix.system.write(log_fd, log_line.ptr, log_line.len);
}

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(std.posix.STDIN_FILENO, .NOW, &orig);
    }
    // Disable mouse tracking, exit alternate screen, reset cursor style, show cursor
    const seq = "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[0q\x1b[?25h";
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, seq, seq.len);
    logMemoryUsage();
    std.process.exit(1);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(std.posix.STDIN_FILENO, .NOW, &orig);
    }
    // Disable mouse tracking, exit alternate screen, reset cursor style, show cursor
    const seq = "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[0q\x1b[?25h";
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, seq, seq.len);
    logMemoryUsage();
    std.debug.defaultPanic(msg, ret_addr);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        const err = std.posix.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) return error.Unexpected;
            index += @intCast(rc);
        } else if (err == .INTR) {
            continue;
        } else {
            return error.SystemResources;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var theme: Theme = .dark;

    // Check environment variable fallback
    if (init.environ_map.get("EMOJIG_THEME")) |env_val| {
        if (std.mem.eql(u8, env_val, "light")) {
            theme = .light;
        } else if (std.mem.eql(u8, env_val, "dark")) {
            theme = .dark;
        }
    }

    // Check command-line arguments (override env var)
    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // Skip executable name
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--theme")) {
            if (args_it.next()) |theme_val| {
                if (std.mem.eql(u8, theme_val, "light")) {
                    theme = .light;
                } else if (std.mem.eql(u8, theme_val, "dark")) {
                    theme = .dark;
                } else {
                    const stderr_fd = std.posix.STDERR_FILENO;
                    try writeAll(stderr_fd, "Error: invalid theme. Supported values are 'dark' or 'light'.\n");
                    std.process.exit(1);
                }
            } else {
                const stderr_fd = std.posix.STDERR_FILENO;
                try writeAll(stderr_fd, "Error: --theme requires an argument ('dark' or 'light').\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stdout_fd = std.posix.STDOUT_FILENO;
            try writeAll(stdout_fd, "Emojig - Premium Zero-Allocation Emoji Picker\n\n");
            try writeAll(stdout_fd, "Usage: emojig [options]\n\n");
            try writeAll(stdout_fd, "Options:\n");
            try writeAll(stdout_fd, "  --theme [dark|light]  Set the UI theme (overrides EMOJIG_THEME env var)\n");
            try writeAll(stdout_fd, "  -h, --help            Show this help message\n");
            std.process.exit(0);
        }
    }

    const term_width: usize = blk: {
        const s = init.environ_map.get("EMOJIG_WIDTH") orelse break :blk 25;
        break :blk std.fmt.parseInt(usize, s, 10) catch 40;
    };

    const palette = switch (theme) {
        .dark => dark_palette,
        .light => light_palette,
    };

    // Load MRU list from disk (startup-only allocation-free read)
    loadMru();

    // Switch to alternate screen, enable mouse tracking, enable blinking cursor, hide cursor
    const stdout_fd = std.posix.STDOUT_FILENO;
    try writeAll(stdout_fd, "\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?12h\x1b[?25l");
    
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
        // Restore termios, disable mouse tracking, exit alternate screen, reset cursor style, show cursor
        std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
        writeAll(stdout_fd, "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[0q\x1b[?25h") catch {};
        logMemoryUsage();
    }
    
    var query_buf: [64]u8 = undefined;
    var query_len: usize = 0;
    
    // We display a 6x4 grid of emojis (total 24 matches)
    const cols = 6;
    const rows = 4;
    const total_cells = cols * rows;
    
    var selected_idx: ?usize = null;
    var top_matches: [total_cells]Match = undefined;
    var top_count: usize = 0;
    
    var should_copy_and_exit = false;

    // Initial search (query is empty — will show MRU first)
    search(query_buf[0..query_len], &top_matches, &top_count, total_cells);
    
    var read_buf: [32]u8 = undefined;
    
    while (true) {
        // 1. Draw screen
        try writeAll(stdout_fd, "\x1b[?25l\x1b[H"); // Hide cursor, cursor to 1,1
        try writeAll(stdout_fd, "\x1b[K\r\n"); // blank top padding line

        var line_buf: [1024]u8 = undefined;

        // Draw Header — highlighted input bar, with one plain space at end to avoid BG bleed.
        const search_line = try std.fmt.bufPrint(
            &line_buf,
            "🔍 {s}{s}\x1b[K\x1b[999C\x1b[0m \r\n",
            .{ palette.search_row_bg, query_buf[0..query_len] },
        );
        try writeAll(stdout_fd, search_line);
        try writeAll(stdout_fd, "\x1b[K\r\n"); // blank line after search bar
        
        // Draw 4 rows of grid cells
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            var cell_buffers: [6][64]u8 = undefined;
            var cell_strings: [6][]const u8 = undefined;
            
            var c: usize = 0;
            while (c < cols) : (c += 1) {
                const idx = r * cols + c;
                if (idx < top_count) {
                    const m = top_matches[idx];
                    const entry = emojig.EmojiDb.getEntry(m.index);
                    
                    if (selected_idx) |sel| {
                        if (idx == sel) {
                            cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s}{s}\x1b[0m ", .{ palette.selection_bg, entry.emoji });
                        } else {
                            cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{ entry.emoji });
                        }
                    } else {
                        cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{ entry.emoji });
                    }
                } else {
                    cell_strings[c] = palette.empty_cell;
                }
            }
            
            const line = try std.fmt.bufPrint(&line_buf, "{s}{s}{s}{s}{s}{s}\x1b[K\r\n", .{
                cell_strings[0], cell_strings[1], cell_strings[2],
                cell_strings[3], cell_strings[4], cell_strings[5]
            });
            try writeAll(stdout_fd, line);
        }
        
        // Draw selected emoji description at the bottom, truncated with ellipsis if needed
        if (selected_idx) |sel| {
            if (top_count > 0 and sel < top_count) {
                const selected = emojig.EmojiDb.getEntry(top_matches[sel].index);
                const max_len = if (term_width > 1) term_width - 1 else 0; // 1 col for leading space
                const name = selected.name;
                const name_line = if (name.len > max_len and max_len >= 3)
                    try std.fmt.bufPrint(&line_buf, " {s}...\x1b[K\r\n", .{name[0 .. max_len - 3]})
                else
                    try std.fmt.bufPrint(&line_buf, " {s}\x1b[K\r\n", .{name});
                try writeAll(stdout_fd, name_line);
            } else {
                try writeAll(stdout_fd, "\x1b[K\r\n");
            }
        } else {
            try writeAll(stdout_fd, "\x1b[K\r\n");
        }
        
        // Move cursor back to search input position (Row 2, Column 4 + query_len), ensure blinking, and show it
        var cursor_buf: [48]u8 = undefined;
        const cursor_seq = try std.fmt.bufPrint(&cursor_buf, "\x1b[2;{d}H\x1b[?12h\x1b[?25h", .{4 + query_len});
        try writeAll(stdout_fd, cursor_seq);
        
        if (should_copy_and_exit) {
            if (selected_idx) |sel| {
                if (top_count > 0 and sel < top_count) {
                    const selected = emojig.EmojiDb.getEntry(top_matches[sel].index);
                    saveMru(selected.emoji);
                    copyToClipboard(init, selected.emoji) catch {};
                }
            } else if (top_count > 0) {
                const selected = emojig.EmojiDb.getEntry(top_matches[0].index);
                saveMru(selected.emoji);
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
                if (bytes[2] == 'A' or bytes[2] == 'B' or bytes[2] == 'C' or bytes[2] == 'D') {
                    if (selected_idx == null) {
                        if (top_count > 0) {
                            selected_idx = 0;
                        }
                        continue;
                    }
                    var sel = selected_idx.?;
                    if (bytes[2] == 'A') {
                        // Up arrow (moves 1 row up)
                        if (top_count > 0) {
                            if (sel >= cols) {
                                sel -= cols;
                            } else {
                                // Wrap to bottom row of same column if possible
                                const target = sel + (rows - 1) * cols;
                                if (target < top_count) {
                                    sel = target;
                                } else {
                                    sel = top_count - 1;
                                }
                            }
                        }
                    } else if (bytes[2] == 'B') {
                        // Down arrow (moves 1 row down)
                        if (top_count > 0) {
                            const target = sel + cols;
                            if (target < top_count) {
                                sel = target;
                            } else {
                                // Wrap to top row of same column
                                sel = sel % cols;
                            }
                        }
                    } else if (bytes[2] == 'C') {
                        // Right arrow (moves 1 cell right)
                        if (top_count > 0) {
                            if (sel < top_count - 1) {
                                sel += 1;
                            } else {
                                sel = 0;
                            }
                        }
                    } else if (bytes[2] == 'D') {
                        // Left arrow (moves 1 cell left)
                        if (top_count > 0) {
                            if (sel > 0) {
                                sel -= 1;
                            } else {
                                sel = top_count - 1;
                            }
                        }
                    }
                    selected_idx = sel;
                } else if (bytes[2] == '<') {
                    // SGR Mouse Event
                    var it = std.mem.splitScalar(u8, bytes[3..], ';');
                    const button_str = it.next() orelse continue;
                    const col_str = it.next() orelse continue;
                    const rest = it.next() orelse continue;
                    
                    const button = std.fmt.parseInt(i32, button_str, 10) catch continue;
                    const click_col = std.fmt.parseInt(i32, col_str, 10) catch continue;
                    
                    if (rest.len > 0) {
                        const action_char = rest[rest.len - 1];
                        const row_str = rest[0 .. rest.len - 1];
                        const click_row = std.fmt.parseInt(i32, row_str, 10) catch continue;
                        
                        // Left click press
                        if (button == 0 and action_char == 'M') {
                            // Row 1 is blank padding. Row 2 is Search box. Rows 3-6 are the 4 grid rows
                            if (click_row >= 2 and click_row <= 5) {
                                const grid_row = @as(usize, @intCast(click_row - 2));
                                // Each cell is exactly 3 chars wide (" emo ")
                                const grid_col = @as(usize, @intCast(@max(0, click_col - 1))) / 3;
                                if (grid_col < cols) {
                                    const clicked_idx = grid_row * cols + grid_col;
                                    if (clicked_idx < top_count) {
                                        selected_idx = clicked_idx;
                                        should_copy_and_exit = true;
                                    }
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
                selected_idx = if (query_len == 0) null else 0;
                search(query_buf[0..query_len], &top_matches, &top_count, total_cells);
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
                    search(query_buf[0..query_len], &top_matches, &top_count, total_cells);
                }
            }
        }
    }
}

/// Search for emojis matching `query` and populate `top_matches[0..top_count]`.
///
/// When query is empty, MRU emojis are placed first (by looking up their DB
/// index), then remaining cells are filled with the full emoji list in DB
/// order, skipping any emoji that was already shown as MRU.
///
/// When query is non-empty, standard fuzzy search runs as before.
fn search(query: []const u8, top_matches: []Match, top_count: *usize, limit: usize) void {
    top_count.* = 0;

    if (query.len == 0) {
        // --- Empty query: show MRU first, then fill with full list ---

        // Slot 0..mru_count-1: resolve each MRU emoji to its DB index.
        // We do a linear scan of the DB for each MRU entry (no alloc).
        var mru_indices: [MAX_MRU]usize = undefined;
        var mru_resolved: usize = 0;

        var m: usize = 0;
        while (m < mru_count and top_count.* < limit) : (m += 1) {
            const mru_emoji = mru_buf[m][0..mru_lens[m]];
            // Linear scan to find the DB index for this emoji string
            var db_idx: usize = 0;
            while (db_idx < emojig.EmojiDb.count) : (db_idx += 1) {
                const entry = emojig.EmojiDb.getEntry(db_idx);
                if (std.mem.eql(u8, entry.emoji, mru_emoji)) {
                    top_matches[top_count.*] = Match{ .index = db_idx, .score = 0 };
                    mru_indices[mru_resolved] = db_idx;
                    mru_resolved += 1;
                    top_count.* += 1;
                    break;
                }
            } // silently skip MRU entries not in DB
        }

        // Fill remaining cells from full DB list, skipping MRU duplicates
        var db_idx: usize = 0;
        while (db_idx < emojig.EmojiDb.count and top_count.* < limit) : (db_idx += 1) {
            // Check if this DB index is already shown as MRU
            var already_shown = false;
            var k: usize = 0;
            while (k < mru_resolved) : (k += 1) {
                if (mru_indices[k] == db_idx) {
                    already_shown = true;
                    break;
                }
            }
            if (already_shown) continue;
            top_matches[top_count.*] = Match{ .index = db_idx, .score = 0 };
            top_count.* += 1;
        }
        return;
    }

    // --- Non-empty query: standard fuzzy search (unchanged) ---
    var i: usize = 0;
    while (i < emojig.EmojiDb.count) : (i += 1) {
        const entry = emojig.EmojiDb.getEntry(i);
        if (emojig.fuzzyMatch(query, entry.search)) |score| {
            const match = Match{ .index = i, .score = score };
            
            // Insert into sorted top_matches (descending order)
            var insert_pos: usize = 0;
            while (insert_pos < top_count.*) : (insert_pos += 1) {
                if (match.score > top_matches[insert_pos].score) break;
            }
            
            if (insert_pos < limit) {
                var shift: usize = @min(top_count.*, limit - 1);
                while (shift > insert_pos) : (shift -= 1) {
                    top_matches[shift] = top_matches[shift - 1];
                }
                top_matches[insert_pos] = match;
                if (top_count.* < limit) top_count.* += 1;
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
