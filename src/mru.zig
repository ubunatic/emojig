const std = @import("std");

pub const MAX_MRU = 24;

var mru_buf: [MAX_MRU][32]u8 = undefined;
var mru_lens: [MAX_MRU]u8 = undefined;
var mru_count: usize = 0;

pub fn getCount() usize {
    return mru_count;
}

pub fn getEntry(i: usize) []const u8 {
    return mru_buf[i][0..mru_lens[i]];
}

pub fn load() void {
    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/emojig/mru.json", .{home}) catch return;
    if (path.len + 1 > path_buf.len) return;
    path_buf[path.len] = 0;

    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], flags, 0) catch return;
    defer _ = std.posix.system.close(fd);

    var file_buf: [4096]u8 = undefined;
    const len = std.posix.read(fd, &file_buf) catch return;
    if (len == 0) return;
    const content = file_buf[0..len];

    var pos: usize = 0;
    while (pos < content.len and content[pos] != '[') pos += 1;
    if (pos >= content.len) return;
    pos += 1;

    mru_count = 0;
    while (pos < content.len and mru_count < MAX_MRU) {
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or
            content[pos] == '\r' or content[pos] == '\n' or content[pos] == ',')) {
            pos += 1;
        }
        if (pos >= content.len or content[pos] == ']') break;
        if (content[pos] != '"') { pos += 1; continue; }
        pos += 1;

        var emoji_len: usize = 0;
        while (pos < content.len and content[pos] != '"' and emoji_len < 31) {
            mru_buf[mru_count][emoji_len] = content[pos];
            emoji_len += 1;
            pos += 1;
        }
        if (pos < content.len and content[pos] == '"') pos += 1;
        if (emoji_len == 0) continue;
        mru_lens[mru_count] = @intCast(emoji_len);
        mru_count += 1;
    }
}

pub fn save(emoji: []const u8) void {
    if (emoji.len == 0 or emoji.len > 31) return;

    var new_buf: [MAX_MRU][32]u8 = undefined;
    var new_lens: [MAX_MRU]u8 = undefined;
    var new_count: usize = 0;

    @memcpy(new_buf[0][0..emoji.len], emoji);
    new_lens[0] = @intCast(emoji.len);
    new_count = 1;

    var i: usize = 0;
    while (i < mru_count and new_count < MAX_MRU) : (i += 1) {
        const existing = mru_buf[i][0..mru_lens[i]];
        if (std.mem.eql(u8, existing, emoji)) continue;
        @memcpy(new_buf[new_count][0..mru_lens[i]], existing);
        new_lens[new_count] = mru_lens[i];
        new_count += 1;
    }

    @memcpy(mru_buf[0..new_count], new_buf[0..new_count]);
    @memcpy(mru_lens[0..new_count], new_lens[0..new_count]);
    mru_count = new_count;

    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    var path_buf: [512]u8 = undefined;
    const config_dir = std.fmt.bufPrint(&path_buf, "{s}/.config/emojig", .{home}) catch return;
    if (config_dir.len + 1 > path_buf.len) return;
    path_buf[config_dir.len] = 0;

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
