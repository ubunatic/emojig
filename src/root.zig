//! Emojig core library. Contains the embedded emoji database, fuzzy search engine,
//! and top-level search function.
const std = @import("std");

pub const mru = @import("mru.zig");

/// A single search result.
pub const Match = struct {
    index: usize,
    score: i32,
};

/// Search for emojis matching `query` and populate `top_matches[0..top_count.*]`.
///
/// When query is empty, MRU emojis are placed first, then the full DB list
/// fills remaining cells (skipping duplicates). When non-empty, standard
/// fuzzy scoring applies.
pub fn search(query: []const u8, top_matches: []Match, top_count: *usize, limit: usize) void {
    top_count.* = 0;

    if (query.len == 0) {
        var mru_indices: [mru.MAX_MRU]usize = undefined;
        var mru_resolved: usize = 0;

        var m: usize = 0;
        while (m < mru.getCount() and top_count.* < limit) : (m += 1) {
            const mru_emoji = mru.getEntry(m);
            var db_idx: usize = 0;
            while (db_idx < EmojiDb.count) : (db_idx += 1) {
                const entry = EmojiDb.getEntry(db_idx);
                if (std.mem.eql(u8, entry.emoji, mru_emoji)) {
                    top_matches[top_count.*] = Match{ .index = db_idx, .score = 0 };
                    mru_indices[mru_resolved] = db_idx;
                    mru_resolved += 1;
                    top_count.* += 1;
                    break;
                }
            }
        }

        var db_idx: usize = 0;
        while (db_idx < EmojiDb.count and top_count.* < limit) : (db_idx += 1) {
            var already_shown = false;
            var k: usize = 0;
            while (k < mru_resolved) : (k += 1) {
                if (mru_indices[k] == db_idx) { already_shown = true; break; }
            }
            if (already_shown) continue;
            top_matches[top_count.*] = Match{ .index = db_idx, .score = 0 };
            top_count.* += 1;
        }
        return;
    }

    var i: usize = 0;
    while (i < EmojiDb.count) : (i += 1) {
        const entry = EmojiDb.getEntry(i);
        if (fuzzyMatch(query, entry.search)) |score| {
            const match = Match{ .index = i, .score = score };
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
fn matchTermDirect(term: []const u8, target: []const u8) ?i32 {
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

/// Match a single search term against a target search string.
/// Returns a score if the term is a subsequence of the target, or null otherwise.
pub fn matchTerm(term: []const u8, target: []const u8) ?i32 {
    if (term.len == 0) return 0;
    if (matchTermDirect(term, target)) |score| {
        return score;
    }

    // Fallback: Plurals (if term ends in 's' and length > 3, e.g. "cars" -> "car")
    if (term.len > 3 and std.ascii.toLower(term[term.len - 1]) == 's') {
        const last2 = std.ascii.toLower(term[term.len - 2]);
        if (last2 != 's') { // avoid "glass", "grass"
            // If it ends in "ies" and length > 5 (e.g. "cherries" -> "cherry")
            if (term.len > 5 and term.len < 60 and last2 == 'e' and std.ascii.toLower(term[term.len - 3]) == 'i') {
                var buf: [64]u8 = undefined;
                for (term[0 .. term.len - 3], 0..) |c, i| {
                    buf[i] = c;
                }
                buf[term.len - 3] = 'y';
                const alternate = buf[0 .. term.len - 2];
                if (matchTermDirect(alternate, target)) |score| {
                    return score - 5;
                }
            }
            // If it ends in "es" and length > 4 (e.g. "boxes" -> "box")
            if (term.len > 4 and last2 == 'e') {
                const alternate1 = term[0 .. term.len - 2]; // strip "es"
                if (matchTermDirect(alternate1, target)) |score| {
                    return score - 5;
                }
                const alternate2 = term[0 .. term.len - 1]; // strip "s" (e.g. "shoes" -> "shoe")
                if (matchTermDirect(alternate2, target)) |score| {
                    return score - 5;
                }
            }
            // Default plural strip 's'
            const alternate = term[0 .. term.len - 1];
            if (matchTermDirect(alternate, target)) |score| {
                return score - 5;
            }
        }
    }

    // Fallback: Word stems (if term ends in 'ing' and length > 4, e.g. "racing" -> "rac" or "race")
    if (term.len > 4 and std.mem.eql(u8, term[term.len - 3 ..], "ing")) {
        const stem = term[0 .. term.len - 3];
        // try stem directly (e.g. "racing" -> "rac")
        if (matchTermDirect(stem, target)) |score| {
            return score - 5;
        }
        // try stem + "e" (e.g. "racing" -> "race")
        var buf: [64]u8 = undefined;
        if (stem.len < 60) {
            for (stem, 0..) |c, i| {
                buf[i] = c;
            }
            buf[stem.len] = 'e';
            const alternate = buf[0 .. stem.len + 1];
            if (matchTermDirect(alternate, target)) |score| {
                return score - 5;
            }
        }
        // If double consonant stem (e.g. "running" -> "run")
        if (stem.len > 2 and stem[stem.len - 1] == stem[stem.len - 2]) {
            const alternate = stem[0 .. stem.len - 1];
            if (matchTermDirect(alternate, target)) |score| {
                return score - 5;
            }
        }
    }

    // Fallback: Query stem (if term ends in 'e' and length > 3, e.g. "race" -> "rac")
    if (term.len > 3 and std.ascii.toLower(term[term.len - 1]) == 'e') {
        const alternate = term[0 .. term.len - 1];
        if (matchTermDirect(alternate, target)) |score| {
            return score - 5;
        }
    }

    return null;
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

test "fuzzy matching with plurals and word stems" {
    const target = "racing car";

    // 1. Plural and singular matches
    const score_car = fuzzyMatch("car", target);
    try std.testing.expect(score_car != null);

    const score_cars = fuzzyMatch("cars", target);
    try std.testing.expect(score_cars != null);

    // 2. Word stem matches
    const score_racing = fuzzyMatch("racing", target);
    try std.testing.expect(score_racing != null);

    const score_race = fuzzyMatch("race", target);
    try std.testing.expect(score_race != null);

    // Make sure they score highly
    try std.testing.expect(score_car.? > 0);
    try std.testing.expect(score_cars.? > 0);
    try std.testing.expect(score_racing.? > 0);
    try std.testing.expect(score_race.? > 0);
}
