//! Emojig core library. Contains the embedded emoji database and fuzzy search engine.
const std = @import("std");

/// Compile-time embedded emoji database.
pub const EmojiDb = struct {
    // Embed the packed binary at compile time.
    const data = @embedFile("emojis.bin");

    pub const Entry = struct {
        emoji: []const u8,
        name: []const u8,
        search: []const u8,
    };

    // Header values (little-endian)
    pub const magic = data[0..4];
    pub const version = std.mem.readInt(u16, data[4..6], .little);
    pub const count = std.mem.readInt(u16, data[6..8], .little);
    pub const string_table_offset = std.mem.readInt(u32, data[8..12], .little);
    pub const string_table_len = std.mem.readInt(u32, data[12..16], .little);

    /// Get an emoji database entry by index.
    pub fn getEntry(index: usize) Entry {
        if (index >= count) @panic("index out of bounds");
        const entry_offset = 16 + index * 12;
        const emoji_off = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        const name_off = std.mem.readInt(u32, data[entry_offset+4..][0..4], .little);
        const search_off = std.mem.readInt(u32, data[entry_offset+8..][0..4], .little);

        const str_table = data[string_table_offset..][0..string_table_len];

        return .{
            .emoji = std.mem.sliceTo(str_table[emoji_off..], 0),
            .name = std.mem.sliceTo(str_table[name_off..], 0),
            .search = std.mem.sliceTo(str_table[search_off..], 0),
        };
    }
};

/// Match a single search term against a target search string.
/// Returns a score if the term is a subsequence of the target, or null otherwise.
pub fn matchTerm(term: []const u8, target: []const u8) ?i32 {
    if (term.len == 0) return 0;
    
    var score: i32 = 0;
    var target_idx: usize = 0;
    var term_idx: usize = 0;
    var consecutive: i32 = 0;
    
    while (term_idx < term.len) {
        if (target_idx >= target.len) return null; // Not a subsequence
        
        const term_char = std.ascii.toLower(term[term_idx]);
        const target_char = std.ascii.toLower(target[target_idx]);
        
        if (term_char == target_char) {
            var char_score: i32 = 10;
            
            // Bonus for matching at the start of a word
            if (target_idx == 0 or target[target_idx - 1] == ' ') {
                char_score += 40;
            }
            
            // Compounding bonus for consecutive matches
            if (consecutive > 0) {
                char_score += 20 * consecutive;
            }
            
            score += char_score;
            consecutive += 1;
            term_idx += 1;
        } else {
            // Small gap penalty
            score -= 1;
            consecutive = 0;
        }
        target_idx += 1;
    }
    
    // Penalty for starting late in the target string
    const start_idx = target_idx - term.len;
    score -= @intCast(start_idx);
    
    return score;
}

/// Matches multiple space-separated terms in the query.
/// Returns the combined score if all terms are subsequences, or null otherwise.
pub fn fuzzyMatch(query: []const u8, target: []const u8) ?i32 {
    var total_score: i32 = 0;
    var term_it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var has_terms = false;
    while (term_it.next()) |term| {
        has_terms = true;
        const score = matchTerm(term, target) orelse return null;
        total_score += score;
    }
    if (!has_terms) return 0;
    return total_score;
}

test "verify all entries" {
    var i: usize = 0;
    while (i < EmojiDb.count) : (i += 1) {
        const entry = EmojiDb.getEntry(i);
        try std.testing.expect(entry.emoji.len > 0);
        try std.testing.expect(entry.name.len > 0);
    }
}

test "embedded database check" {
    try std.testing.expectEqualSlices(u8, "EMJG", EmojiDb.magic);
    try std.testing.expectEqual(@as(u16, 1), EmojiDb.version);
    try std.testing.expect(EmojiDb.count > 0);

    const first = EmojiDb.getEntry(0);
    std.debug.print("\nFirst Emoji: {s} | {s} | {s}\n", .{ first.emoji, first.name, first.search });
    try std.testing.expect(first.emoji.len > 0);
    try std.testing.expect(first.name.len > 0);
}

test "fuzzy subsequence matching" {
    // Exact match vs partial subsequence matches
    const target = "grinning face smile happy";
    
    const score1 = fuzzyMatch("smile", target);
    try std.testing.expect(score1 != null);
    
    const score2 = fuzzyMatch("grn", target);
    try std.testing.expect(score2 != null);
    
    const score3 = fuzzyMatch("xyz", target);
    try std.testing.expect(score3 == null);
    
    // Multiple terms: both must match
    const score4 = fuzzyMatch("face smile", target);
    try std.testing.expect(score4 != null);
    
    const score5 = fuzzyMatch("face xyz", target);
    try std.testing.expect(score5 == null);
}
