// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Emojig core library. Contains the embedded emoji database, fuzzy search engine,
//! and top-level search function.
const std = @import("std");

pub const mru = @import("mru.zig");

/// A single search result.
pub const Match = struct {
    index: usize,
    score: i32,
};

pub const CategorySpec = struct {
    name: []const u8,
    short: []const u8,
    synonyms: []const []const u8,
};

pub const CategoriesSpec = struct {
    categories: []const CategorySpec,
};

fn isWordInSearch(search_str: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, search_str, pos, word) orelse return false;
        const start_ok = (idx == 0 or search_str[idx - 1] == ' ');
        const end_ok = (idx + word.len == search_str.len or search_str[idx + word.len] == ' ');
        if (start_ok and end_ok) return true;
        pos = idx + 1;
    }
}

fn emojiMatchesCategory(entry_search: []const u8, cat: CategorySpec) bool {
    if (isWordInSearch(entry_search, cat.name)) return true;
    if (isWordInSearch(entry_search, cat.short)) return true;
    for (cat.synonyms) |syn| {
        if (isWordInSearch(entry_search, syn)) return true;
    }
    return false;
}

fn findCategorySpec(cats_spec: ?*const CategoriesSpec, term: []const u8) ?CategorySpec {
    const cats = cats_spec orelse return null;
    if (term.len == 0) return null;
    for (cats.categories) |cat| {
        if (std.mem.eql(u8, cat.name, term) or std.mem.eql(u8, cat.short, term)) {
            return cat;
        }
    }
    for (cats.categories) |cat| {
        if (std.mem.startsWith(u8, cat.name, term) or std.mem.startsWith(u8, cat.short, term)) {
            return cat;
        }
    }
    for (cats.categories) |cat| {
        for (cat.synonyms) |syn| {
            if (std.mem.startsWith(u8, syn, term)) {
                return cat;
            }
        }
    }
    return null;
}

pub fn search(query: []const u8, top_matches: []Match, top_count: *usize, limit: usize) usize {
    return searchOptions(query, top_matches, top_count, limit, null, &[_][]const u8{});
}

pub fn searchOptions(
    query: []const u8,
    top_matches: []Match,
    top_count: *usize,
    limit: usize,
    categories_spec: ?*const CategoriesSpec,
    disabled_categories: []const []const u8,
) usize {
    top_count.* = 0;

    const disable_zwj = blk: {
        if (std.c.getenv("EMOJIG_DISABLE_ZWJ")) |env_val| {
            const val = std.mem.sliceTo(env_val, 0);
            if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
                break :blk true;
            } else if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false")) {
                break :blk false;
            }
        }
        if (std.c.getenv("TILIX_ID") != null or std.c.getenv("VTE_VERSION") != null) {
            break :blk true;
        }
        break :blk false;
    };

    var actual_query = query;
    var filter_width: ?usize = null;
    var filter_box = false;
    if (query.len >= 2) {
        if ((query[0] == 'e' or query[0] == 'E') and query[1] == ':') {
            actual_query = query[2..];
            filter_width = 2;
        } else if ((query[0] == 't' or query[0] == 'T') and query[1] == ':') {
            actual_query = query[2..];
            filter_width = 1;
        } else if ((query[0] == 'b' or query[0] == 'B') and query[1] == ':') {
            actual_query = query[2..];
            filter_box = true;
        }
    }

    var filter_category: ?[]const u8 = null;
    if (std.mem.startsWith(u8, actual_query, "c:") or std.mem.startsWith(u8, actual_query, "C:")) {
        const after_c = actual_query[2..];
        if (std.mem.indexOfScalar(u8, after_c, ' ')) |space_idx| {
            filter_category = after_c[0..space_idx];
            actual_query = after_c[space_idx + 1 ..];
        } else {
            filter_category = after_c;
            actual_query = "";
        }
    }

    if (actual_query.len == 0) {
        var mru_indices: [mru.MAX_MRU]usize = undefined;
        var mru_resolved: usize = 0;

        var m: usize = 0;
        while (m < mru.getCount() and top_count.* < limit) : (m += 1) {
            const mru_emoji = mru.getEntry(m);
            if (disable_zwj and std.mem.indexOf(u8, mru_emoji, "\xe2\x80\x8d") != null) continue;
            if (filter_width) |fw| {
                if (getEmojiWidth(mru_emoji) != fw) continue;
            }
            if (filter_box and !isBoxArt(mru_emoji)) continue;

            var db_idx: usize = 0;
            while (db_idx < EmojiDb.count) : (db_idx += 1) {
                const entry = EmojiDb.getEntry(db_idx);
                if (std.mem.eql(u8, entry.emoji, mru_emoji)) {
                    const matches_cat = blk: {
                        if (filter_category) |fc| {
                            if (findCategorySpec(categories_spec, fc)) |cat| {
                                break :blk emojiMatchesCategory(entry.search, cat);
                            } else {
                                break :blk false;
                            }
                        }
                        if (disabled_categories.len > 0 and categories_spec != null) {
                            for (disabled_categories) |dc_name| {
                                for (categories_spec.?.categories) |cat| {
                                    if (std.mem.eql(u8, cat.name, dc_name)) {
                                        if (emojiMatchesCategory(entry.search, cat)) {
                                            break :blk false;
                                        }
                                    }
                                }
                            }
                        }
                        break :blk true;
                    };
                    if (!matches_cat) break;

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
            const entry = EmojiDb.getEntry(db_idx);
            if (disable_zwj and std.mem.indexOf(u8, entry.emoji, "\xe2\x80\x8d") != null) continue;
            if (filter_width) |fw| {
                if (getEmojiWidth(entry.emoji) != fw) continue;
            }
            if (filter_box and !isBoxArt(entry.emoji)) continue;

            const matches_cat = blk: {
                if (filter_category) |fc| {
                    if (findCategorySpec(categories_spec, fc)) |cat| {
                        break :blk emojiMatchesCategory(entry.search, cat);
                    } else {
                        break :blk false;
                    }
                }
                if (disabled_categories.len > 0 and categories_spec != null) {
                    for (disabled_categories) |dc_name| {
                        for (categories_spec.?.categories) |cat| {
                            if (std.mem.eql(u8, cat.name, dc_name)) {
                                if (emojiMatchesCategory(entry.search, cat)) {
                                    break :blk false;
                                }
                            }
                        }
                    }
                }
                break :blk true;
            };
            if (!matches_cat) continue;

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

        var total: usize = 0;
        var count_idx: usize = 0;
        while (count_idx < EmojiDb.count) : (count_idx += 1) {
            const entry = EmojiDb.getEntry(count_idx);
            if (disable_zwj and std.mem.indexOf(u8, entry.emoji, "\xe2\x80\x8d") != null) continue;
            if (filter_width) |fw| {
                if (getEmojiWidth(entry.emoji) != fw) continue;
            }
            if (filter_box and !isBoxArt(entry.emoji)) continue;

            const matches_cat = blk: {
                if (filter_category) |fc| {
                    if (findCategorySpec(categories_spec, fc)) |cat| {
                        break :blk emojiMatchesCategory(entry.search, cat);
                    } else {
                        break :blk false;
                    }
                }
                if (disabled_categories.len > 0 and categories_spec != null) {
                    for (disabled_categories) |dc_name| {
                        for (categories_spec.?.categories) |cat| {
                            if (std.mem.eql(u8, cat.name, dc_name)) {
                                if (emojiMatchesCategory(entry.search, cat)) {
                                    break :blk false;
                                }
                            }
                        }
                    }
                }
                break :blk true;
            };
            if (!matches_cat) continue;

            total += 1;
        }
        return total;
    }

    var total: usize = 0;
    var i: usize = 0;
    while (i < EmojiDb.count) : (i += 1) {
        const entry = EmojiDb.getEntry(i);
        if (disable_zwj and std.mem.indexOf(u8, entry.emoji, "\xe2\x80\x8d") != null) continue;
        if (filter_width) |fw| {
            if (getEmojiWidth(entry.emoji) != fw) continue;
        }
        if (filter_box and !isBoxArt(entry.emoji)) continue;

        const matches_cat = blk: {
            if (filter_category) |fc| {
                if (findCategorySpec(categories_spec, fc)) |cat| {
                    break :blk emojiMatchesCategory(entry.search, cat);
                } else {
                    break :blk false;
                }
            }
            if (disabled_categories.len > 0 and categories_spec != null) {
                for (disabled_categories) |dc_name| {
                    for (categories_spec.?.categories) |cat| {
                        if (std.mem.eql(u8, cat.name, dc_name)) {
                            if (emojiMatchesCategory(entry.search, cat)) {
                                break :blk false;
                            }
                        }
                    }
                }
            }
            break :blk true;
        };
        if (!matches_cat) continue;

        if (fuzzyMatch(actual_query, entry.search)) |raw_score| {
            // Box art ranks below genuine emoji matches in general searches;
            // under b: the uniform penalty does not affect ordering.
            const score = if (isBoxArt(entry.emoji)) raw_score - box_art_penalty else raw_score;
            total += 1;
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
    return total;
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
        const entry_offset = 24 + index * 12;
        const emoji_off = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        const name_off = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);
        const search_off = std.mem.readInt(u32, data[entry_offset + 8 ..][0..4], .little);

        const str_table = data[string_table_offset..][0..string_table_len];

        return .{
            .emoji = std.mem.sliceTo(str_table[emoji_off..], 0),
            .name = std.mem.sliceTo(str_table[name_off..], 0),
            .search = std.mem.sliceTo(str_table[search_off..], 0),
        };
    }
};

pub const SynonymDb = struct {
    const data = @embedFile("emojis.bin");

    pub const synonym_table_offset = std.mem.readInt(u32, data[16..20], .little);
    pub const synonym_count = std.mem.readInt(u32, data[20..24], .little);

    pub const Synonym = struct {
        from: []const u8,
        to: []const u8,
    };

    pub fn getSynonym(index: usize) Synonym {
        if (index >= synonym_count) @panic("synonym index out of bounds");
        const entry_offset = synonym_table_offset + index * 8;
        const from_off = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        const to_off = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

        const str_table = data[EmojiDb.string_table_offset..][0..EmojiDb.string_table_len];

        return .{
            .from = std.mem.sliceTo(str_table[from_off..], 0),
            .to = std.mem.sliceTo(str_table[to_off..], 0),
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

    // Exact word match bonus (consecutive match bounded by word boundaries)
    if (consecutive == term.len) {
        const start_pos = target_idx - term.len;
        const is_start_boundary = (start_pos == 0 or target[start_pos - 1] == ' ');
        const is_end_boundary = (target_idx == target.len or target[target_idx] == ' ');
        if (is_start_boundary and is_end_boundary) {
            score += 100;
        }
    }

    // Tie-breaker penalty for longer targets (prefer shorter, more precise descriptions)
    score -= @intCast(target.len);

    return score;
}

/// Match a single search term against a target search string.
/// Returns a score if the term is a subsequence of the target, or null otherwise.
fn matchTermSelf(term: []const u8, target: []const u8) ?i32 {
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

/// Match a single search term against a target search string.
/// Returns a score if the term is a subsequence of the target, or null otherwise.
pub fn matchTerm(term: []const u8, target: []const u8) ?i32 {
    if (term.len == 0) return 0;
    var best_score: ?i32 = null;

    if (matchTermSelf(term, target)) |score| {
        best_score = score;
    }

    var syn_idx: usize = 0;
    while (syn_idx < SynonymDb.synonym_count) : (syn_idx += 1) {
        const syn = SynonymDb.getSynonym(syn_idx);
        if (std.mem.eql(u8, syn.from, term)) {
            if (matchTermDirect(syn.to, target)) |score| {
                if (best_score) |best| {
                    if (score > best) {
                        best_score = score;
                    }
                } else {
                    best_score = score;
                }
            }
        }
    }

    return best_score;
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

pub fn stripVariationSelectors(emoji: []const u8, out_buf: []u8) []const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < emoji.len) {
        if (i + 3 <= emoji.len and (std.mem.eql(u8, emoji[i .. i + 3], "\xef\xb8\x8f") or std.mem.eql(u8, emoji[i .. i + 3], "\xef\xb8\x8e"))) {
            i += 3;
        } else {
            out_buf[out_idx] = emoji[i];
            out_idx += 1;
            i += 1;
        }
    }
    return out_buf[0..out_idx];
}

/// Box-art scores drop by this much in general searches so borders and
/// blocks rank below genuine emoji matches; b: shows them on their own.
const box_art_penalty: i32 = 150;

/// True for box-drawing and block-element glyphs (U+2500–U+259F), the
/// entries from spec/boxart.json. Used by the b: filter and ranking.
pub fn isBoxArt(emoji: []const u8) bool {
    const view = std.unicode.Utf8View.init(emoji) catch return false;
    var iterator = view.iterator();
    const cp = iterator.nextCodepoint() orelse return false;
    return cp >= 0x2500 and cp <= 0x259F;
}

pub fn getEmojiWidth(emoji: []const u8) usize {
    if (emoji.len == 0) return 0;

    // Variation Selector 15 (\xef\xb8\x8e) explicitly requests the
    // monochrome text glyph: single-width.
    if (std.mem.indexOf(u8, emoji, "\xef\xb8\x8e") != null) {
        return 1;
    }

    // If it contains the Variation Selector 16 (\xef\xb8\x8f), it is always rendered as double-width
    if (std.mem.indexOf(u8, emoji, "\xef\xb8\x8f") != null) {
        return 2;
    }

    // Decode the first UTF-8 codepoint
    const view = std.unicode.Utf8View.init(emoji) catch return 2;
    var iterator = view.iterator();
    const cp = iterator.nextCodepoint() orelse return 2;

    // Check if it's in a range of double-width characters:
    // 1. Emojis starting from U+1F000
    if (cp >= 0x1F000) {
        return 2;
    }

    // 2. Certain specific standard double-width emoji code points in the BMP:
    if (cp == 0x231A or cp == 0x231B or cp == 0x23F3 or
        (cp >= 0x23E9 and cp <= 0x23EC) or
        cp == 0x23F0 or
        cp == 0x2B50 or cp == 0x2B55 or cp == 0x2B1B or cp == 0x2B1C or
        (cp >= 0x3000 and cp <= 0x32FF))
    {
        return 2;
    }

    // Specific BMP emoji code points that don't have VS16 in the JSON
    if (cp == 0x25FD or cp == 0x25FE or // ◽, ◾
        cp == 0x2614 or cp == 0x2615 or // ☔, ☕
        (cp >= 0x2648 and cp <= 0x2653) or // ♈..♓
        cp == 0x267F or // ♿
        cp == 0x2693 or // ⚓
        cp == 0x26A1 or // ⚡
        cp == 0x26BD or cp == 0x26BE or // ⚽, ⚾
        cp == 0x26C4 or cp == 0x26C5 or // ⛄, ⛅
        cp == 0x26D4 or // ⛔
        cp == 0x26EA or // ⛪
        cp == 0x26F2 or cp == 0x26F3 or // ⛲, ⛳
        cp == 0x26F5 or // ⛵
        cp == 0x26FA or // ⛺
        cp == 0x26FD or // ⛽
        cp == 0x2705 or // ✅
        cp == 0x270A or cp == 0x270B or // ✊, ✋
        cp == 0x2728 or // ✨
        cp == 0x274C or // ❌
        cp == 0x274E or // ❎
        (cp >= 0x2753 and cp <= 0x2755) or cp == 0x2757 or // ❓, ❔, ❕, ❗
        (cp >= 0x2795 and cp <= 0x2797) or // ➕, ➖, ➗
        cp == 0x27B0 or cp == 0x27BF or // ➰, ➿
        cp == 0x26AA or cp == 0x26AB or // ⚪, ⚫
        cp == 0x26CE) // ⛎
    {
        return 2;
    }

    return 1;
}

test "getEmojiWidth tests" {
    // Double-width standard emojis:
    try std.testing.expectEqual(@as(usize, 2), getEmojiWidth("😀"));
    try std.testing.expectEqual(@as(usize, 2), getEmojiWidth("☕"));
    try std.testing.expectEqual(@as(usize, 2), getEmojiWidth("⚡"));
    try std.testing.expectEqual(@as(usize, 2), getEmojiWidth("❤️"));

    // Single-width quasi-emojis:
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("←"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("↑"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("↓"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("→"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("✓"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("✔"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("♔"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("$"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("€"));
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth("α"));
}

test "verify all entries" {
    var i: usize = 0;
    var has_vs16 = false;
    while (i < EmojiDb.count) : (i += 1) {
        const entry = EmojiDb.getEntry(i);
        try std.testing.expect(entry.emoji.len > 0);
        try std.testing.expect(entry.name.len > 0);
        if (std.mem.indexOf(u8, entry.emoji, "\xef\xb8\x8f") != null) {
            has_vs16 = true;
            var buf: [64]u8 = undefined;
            const stripped = stripVariationSelectors(entry.emoji, &buf);
            try std.testing.expect(std.mem.indexOf(u8, stripped, "\xef\xb8\x8f") == null);
        }
    }
    try std.testing.expect(has_vs16);
}

test "embedded database check" {
    try std.testing.expectEqualSlices(u8, "EMJG", EmojiDb.magic);
    try std.testing.expectEqual(@as(u16, 2), EmojiDb.version);
    try std.testing.expect(EmojiDb.count > 0);

    const first = EmojiDb.getEntry(0);
    // std.debug.print("\nFirst Emoji: {s} | {s} | {s}\n", .{ first.emoji, first.name, first.search });
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

test "quasi-emoji search tests" {
    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;

    // Search for "leftwards"
    _ = search("leftwards", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    var found_left = false;
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        if (std.mem.eql(u8, entry.emoji, "←")) {
            found_left = true;
            break;
        }
    }
    try std.testing.expect(found_left);

    // Search for "rightwards"
    top_count = 0;
    _ = search("rightwards", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    var found_right = false;
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        if (std.mem.eql(u8, entry.emoji, "→")) {
            found_right = true;
            break;
        }
    }
    try std.testing.expect(found_right);

    // Search for "checkmark"
    top_count = 0;
    _ = search("checkmark", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    var matched_checkmark = false;
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        if (std.mem.eql(u8, entry.emoji, "✓")) {
            matched_checkmark = true;
            break;
        }
    }
    try std.testing.expect(matched_checkmark);
}

test "exact word and shorter description prioritization" {
    // Both contain "heart" at the start, but "heart" is shorter and exact
    const target1 = "heart";
    const target2 = "heart with ribbon";

    const score1 = fuzzyMatch("heart", target1);
    const score2 = fuzzyMatch("heart", target2);

    try std.testing.expect(score1.? > score2.?);

    // Exact word match vs substring match in word
    const target3 = "dog face";
    const target4 = "hotdog";

    const score3 = fuzzyMatch("dog", target3);
    const score4 = fuzzyMatch("dog", target4);

    try std.testing.expect(score3.? > score4.?);
}

test "prefix filtering by emoji width (e: and t:)" {
    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;

    // Search with "e:arrow"
    top_count = 0;
    _ = search("e:arrow", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        try std.testing.expectEqual(@as(usize, 2), getEmojiWidth(entry.emoji));
    }

    // Search with "t:arrow"
    top_count = 0;
    _ = search("t:arrow", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        try std.testing.expectEqual(@as(usize, 1), getEmojiWidth(entry.emoji));
    }

    // Search with empty prefix query: "e:"
    top_count = 0;
    _ = search("e:", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        try std.testing.expectEqual(@as(usize, 2), getEmojiWidth(entry.emoji));
    }

    // Search with empty prefix query: "t:"
    top_count = 0;
    _ = search("t:", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        try std.testing.expectEqual(@as(usize, 1), getEmojiWidth(entry.emoji));
    }
}

test "plain (VS15) twins are discoverable via t: and plain search" {
    const gear_plain = "\xe2\x9a\x99\xef\xb8\x8e"; // ⚙ + VS15
    const gear_emoji = "\xe2\x9a\x99\xef\xb8\x8f"; // ⚙ + VS16

    // VS15 forces text presentation: single-width, so t: lists it.
    try std.testing.expectEqual(@as(usize, 1), getEmojiWidth(gear_plain));
    try std.testing.expectEqual(@as(usize, 2), getEmojiWidth(gear_emoji));

    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;

    // "t:gear" must surface the plain twin.
    _ = search("t:gear", &top_matches, &top_count, 24);
    var found_plain = false;
    for (top_matches[0..top_count]) |m| {
        if (std.mem.eql(u8, EmojiDb.getEntry(m.index).emoji, gear_plain)) {
            found_plain = true;
        }
    }
    try std.testing.expect(found_plain);

    // The "plain" keyword narrows a general search to the twin.
    top_count = 0;
    _ = search("gear plain", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    try std.testing.expect(std.mem.eql(u8, EmojiDb.getEntry(top_matches[0].index).emoji, gear_plain));

    // The color twin is still there for the general query.
    top_count = 0;
    _ = search("gear", &top_matches, &top_count, 24);
    var found_color = false;
    for (top_matches[0..top_count]) |m| {
        if (std.mem.eql(u8, EmojiDb.getEntry(m.index).emoji, gear_emoji)) {
            found_color = true;
        }
    }
    try std.testing.expect(found_color);
}

test "box art entries: b: filter, names, and low rank" {
    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;

    // b: with empty query lists only box art.
    _ = search("b:", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        try std.testing.expect(isBoxArt(EmojiDb.getEntry(m.index).emoji));
    }

    // Systematic names hit the exact glyph.
    top_count = 0;
    _ = search("b:top left double border", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    try std.testing.expect(std.mem.eql(u8, EmojiDb.getEntry(top_matches[0].index).emoji, "╔"));

    top_count = 0;
    _ = search("bottom right border round", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    try std.testing.expect(std.mem.eql(u8, EmojiDb.getEntry(top_matches[0].index).emoji, "╯"));

    // General searches rank box art below genuine emoji matches.
    top_count = 0;
    _ = search("left", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    try std.testing.expect(!isBoxArt(EmojiDb.getEntry(top_matches[0].index).emoji));
}

test "synonym search ranking" {
    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;

    _ = search("car", &top_matches, &top_count, 24);
    try std.testing.expect(top_count >= 2);

    var car_pos: ?usize = null;
    var tram_pos: ?usize = null;

    var pos: usize = 0;
    while (pos < top_count) : (pos += 1) {
        const entry = EmojiDb.getEntry(top_matches[pos].index);
        if (std.mem.eql(u8, entry.emoji, "🚗")) {
            car_pos = pos;
        } else if (std.mem.eql(u8, entry.emoji, "🚋")) {
            tram_pos = pos;
        }
    }

    try std.testing.expect(car_pos != null);
    try std.testing.expect(tram_pos != null);
    try std.testing.expect(car_pos.? < tram_pos.?);

    // Test new synonyms
    top_count = 0;
    _ = search("auto", &top_matches, &top_count, 24);
    try std.testing.expect(top_count > 0);
    var found_car = false;
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        if (std.mem.eql(u8, entry.emoji, "🚗")) {
            found_car = true;
            break;
        }
    }
    try std.testing.expect(found_car);
}

test "localization strings JSON files match spec.Strings struct" {
    const allocator = std.testing.allocator;

    const Strings = struct {
        search_prompt: []const u8,
        search_placeholder: []const u8,
        status_help_hint: []const u8,
        status_matches: []const u8,
        status_help_hint_wide: []const u8,
        status_matches_wide: []const u8,
        help_lines: []const []const u8,
        help_lines_more: []const []const u8,
        focus_lost_startup_lines: []const []const u8,
        focus_lost_runtime_lines: []const []const u8,
    };

    const embedded_specs = [_][]const u8{
        @embedFile("spec_strings_es"),
        @embedFile("spec_strings_pt"),
        @embedFile("spec_strings_fr"),
        @embedFile("spec_strings_it"),
        @embedFile("spec_strings_de"),
        @embedFile("spec_strings_pl"),
        @embedFile("spec_strings_ru"),
        @embedFile("spec_strings_uk"),
        @embedFile("spec_strings_nl"),
        @embedFile("spec_strings_tr"),
    };

    for (embedded_specs) |spec_json| {
        // Parse and validate using JSON parser directly into Strings struct.
        // This guarantees every required key is present and holds the correct type.
        var parsed = try std.json.parseFromSlice(Strings, allocator, spec_json, .{ .ignore_unknown_fields = true });
        parsed.deinit();
    }
}

// ---------------------------------------------------------------------------
// Search benchmarks
// ---------------------------------------------------------------------------
//
// Run with default 10ms per query (part of the normal test suite):
//   zig build test
//
// Run in extended bench mode (e.g. 5 s per query):
//   EMOJIG_BENCH=5000 zig build test

fn benchNowNs() u64 {
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Run `search(query)` in a tight loop for `duration_ms` milliseconds.
/// Prints one result line to stderr and returns the measured ns/search.
/// The deadline is checked after every search so the reported duration is
/// accurate even in Debug builds where a single search can take many ms.
fn runBench(query: []const u8, duration_ms: u64) u64 {
    var top_matches: [48]Match = undefined;
    var top_count: usize = 0;
    const t0 = benchNowNs();
    const deadline_ns = t0 + duration_ms * 1_000_000;
    var iters: u64 = 0;
    while (benchNowNs() < deadline_ns) {
        _ = search(query, &top_matches, &top_count, 48);
        iters += 1;
    }
    const elapsed_ns = benchNowNs() - t0;
    const ns_per_iter = if (iters > 0) elapsed_ns / iters else 0;
    const ops_per_sec = if (elapsed_ns > 0) iters * 1_000_000_000 / elapsed_ns else 0;
    std.debug.print(
        "  bench [{s:<18}] {d:>9} iters  {d:>7} ns/search  {d:>9} searches/s\n",
        .{ query, iters, ns_per_iter, ops_per_sec },
    );
    return ns_per_iter;
}

test "benchmark: search throughput" {
    // Duration per query: 10ms in normal test runs, more in bench mode.
    // Override: EMOJIG_BENCH=5000 zig build test  (5 s per query)
    const duration_ms: u64 = blk: {
        const env = std.c.getenv("EMOJIG_BENCH") orelse break :blk 10;
        const val = std.mem.sliceTo(env, 0);
        break :blk std.fmt.parseInt(u64, val, 10) catch 10;
    };
    std.debug.print("\nsearch benchmarks ({d} ms per query, {d} emojis):\n", .{ duration_ms, EmojiDb.count });

    const is_bench = duration_ms > 10;

    // --- representative query set ---
    // empty: returns top-48 results in score order — exercises ranking only
    _ = runBench("", duration_ms);
    // single char: large result set, full scan with scoring
    const ns_a = runBench("a", duration_ms);
    // common short word: typical interactive query
    const ns_fire = runBench("fire", duration_ms);
    // multi-word AND: two-term intersection scoring
    const ns_multi = runBench("red heart", duration_ms);
    // plural: exercises the fallback stem/plural matching paths
    const ns_plural = runBench("hearts", duration_ms);
    // no match: exercises the early-exit / zero-score path
    _ = runBench("xyzxyz", duration_ms);

    // In bench mode (release build) enforce a hard latency ceiling:
    // >500 searches/s means every keystroke is processed in <2 ms.
    // Debug builds are unoptimised and intentionally excluded.
    if (is_bench) {
        const max_ns: u64 = 2_000_000; // 2 ms per search
        try std.testing.expect(ns_a < max_ns);
        try std.testing.expect(ns_fire < max_ns);
        try std.testing.expect(ns_multi < max_ns);
        try std.testing.expect(ns_plural < max_ns);
    }
}
