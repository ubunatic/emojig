// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Emojig core library. Contains the embedded emoji database, fuzzy search engine,
//! and top-level search function.
const std = @import("std");

pub const mru = @import("mru.zig");
const search_mod = @import("search.zig");

// Forward public API from search module
pub const fuzzyMatch = search_mod.fuzzyMatch;
pub const matchTerm = search_mod.matchTerm;
pub const getEmojiWidth = search_mod.getEmojiWidth;
pub const isBoxArt = search_mod.isBoxArt;
pub const isBraille = search_mod.isBraille;
pub const brailleDotCount = search_mod.brailleDotCount;
pub const stripVariationSelectors = search_mod.stripVariationSelectors;

/// A single search result.
pub const Match = struct {
    index: usize,
    score: i32,
};

pub const CategorySpec = struct {
    name: []const u8,
    short: []const u8,
    synonyms: []const []const u8,
    icon: []const u8 = "",
    switcher: bool = false,
};

pub const CategoriesSpec = struct {
    /// Written once at the very start of the switcher row, in status_bg.
    row_pad_left: []const u8 = "",
    /// Written once at the very end of the switcher row (after fill), in status_bg.
    row_pad_right: []const u8 = "",
    /// Icon for the "All" slot (no category filter). Must be exactly 2 display cols.
    /// Use a 1-wide char + space (e.g. "✱ ", "* ") or a 2-wide emoji.
    all_icon: []const u8 = "\u{2731} ",
    /// Prefix for every normal (unselected, unhovered) slot. Must be 1 display col.
    pad_left: []const u8 = " ",
    /// Prefix for the selected (active) slot — replaces pad_left. Same width.
    select_left: []const u8 = "",
    /// Prefix for the slot immediately AFTER the selected one — replaces that
    /// slot's pad_left, "stealing" one col so the total row width stays constant.
    select_right: []const u8 = "",
    /// How much of the selected slot the bg color covers.
    /// "all"  → left + icon + right all get sel_bg (right bracket also highlighted).
    /// "icon" → only the 2-col icon gets sel_bg; left/right stay in status_bg.
    select_scope: []const u8 = "all",
    /// Prefix for the hovered (mouse-over) slot — replaces pad_left.
    hl_left: []const u8 = "",
    /// Prefix for the slot immediately after the hovered one — replaces pad_left.
    hl_right: []const u8 = "",
    /// Same scope control for hover. "all" or "icon".
    hl_scope: []const u8 = "all",
    /// $fmtvars attrs string applied as bg color for the hovered slot.
    /// Empty → palette.selection_bg.
    hl_pattern: []const u8 = "",
    /// $fmtvars attrs string applied as bg color for the selected slot.
    /// Empty → palette.selection_bg. "none" → status_bg (no highlight).
    select_pattern: []const u8 = "",
    categories: []const CategorySpec,
};

fn isWordInSearch(search_str: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, search_str, pos, word) orelse return false;
        const start_ok = (idx == 0 or search_str[idx - 1] == ' ' or search_str[idx - 1] == '\t');
        const end_ok = (idx + word.len == search_str.len or search_str[idx + word.len] == ' ' or search_str[idx + word.len] == '\t');
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

pub const CategoryMatch = struct {
    spec: CategorySpec,
    is_synonym: bool,
};

fn findCategorySpecMatch(cats_spec: ?*const CategoriesSpec, term: []const u8) ?CategoryMatch {
    const cats = cats_spec orelse return null;
    if (term.len == 0) return null;
    for (cats.categories) |cat| {
        if (std.mem.eql(u8, cat.name, term) or std.mem.eql(u8, cat.short, term)) {
            return CategoryMatch{ .spec = cat, .is_synonym = false };
        }
    }
    for (cats.categories) |cat| {
        if (std.mem.startsWith(u8, cat.name, term) or std.mem.startsWith(u8, cat.short, term)) {
            return CategoryMatch{ .spec = cat, .is_synonym = false };
        }
    }
    for (cats.categories) |cat| {
        for (cat.synonyms) |syn| {
            if (std.mem.startsWith(u8, syn, term)) {
                return CategoryMatch{ .spec = cat, .is_synonym = true };
            }
        }
    }
    return null;
}

fn findCategorySpec(cats_spec: ?*const CategoriesSpec, term: []const u8) ?CategorySpec {
    if (findCategorySpecMatch(cats_spec, term)) |m| {
        return m.spec;
    }
    return null;
}

var parsed_categories_spec: ?CategoriesSpec = null;
var categories_arena_bytes: [64 * 1024]u8 = undefined;

pub fn getGlobalCategoriesSpec() *const CategoriesSpec {
    if (parsed_categories_spec) |*spec| {
        return spec;
    }
    const categories_json = @embedFile("spec_categories");
    var fba = std.heap.FixedBufferAllocator.init(&categories_arena_bytes);
    const parsed = std.json.parseFromSlice(CategoriesSpec, fba.allocator(), categories_json, .{ .ignore_unknown_fields = true }) catch unreachable;
    parsed_categories_spec = parsed.value;
    return &parsed_categories_spec.?;
}

pub fn search(query: []const u8, top_matches: []Match, top_count: *usize, limit: usize) usize {
    const cats = getGlobalCategoriesSpec();
    return searchOptions(query, top_matches, top_count, limit, cats, &[_][]const u8{}, null);
}

/// Box-art scores drop by this much in general searches so borders and
/// blocks rank below genuine emoji matches; b: shows them on their own.
const box_art_penalty: i32 = 150;

/// Braille scores drop by this much in general searches so patterns rank
/// below genuine emoji matches; br: shows them on their own.
const braille_penalty: i32 = 150;

pub fn searchOptions(
    query: []const u8,
    top_matches: []Match,
    top_count: *usize,
    limit: usize,
    categories_spec: ?*const CategoriesSpec,
    disabled_categories: []const []const u8,
    forced_category: ?[]const u8,
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
    var filter_braille = false;
    var braille_dot_filter: ?u32 = null;
    if (query.len >= 3 and
        (query[0] == 'b' or query[0] == 'B') and
        (query[1] == 'r' or query[1] == 'R') and query[2] == ':')
    {
        filter_braille = true;
        const rest = query[3..];
        actual_query = "";

        // Dot-count shorthand: "br:<n>" or "br:<n>:" lists every glyph with
        // exactly n raised dots. Anything else after "br:" is a name search.
        var digits = rest;
        if (digits.len > 0 and digits[digits.len - 1] == ':') {
            digits = digits[0 .. digits.len - 1];
        }
        var all_digits = digits.len > 0;
        for (digits) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            braille_dot_filter = std.fmt.parseInt(u32, digits, 10) catch null;
        } else {
            actual_query = rest;
        }
    } else if (query.len >= 2) {
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

    var filter_category: ?[]const u8 = forced_category;
    if (filter_category == null) {
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
        // Auto-detect: if the first query word matches a known category name or
        // synonym, treat it as an implicit category filter (no prefix needed).
        // Only fires when categories_spec is loaded (null → no-op, safe in tests).
        // If it is a synonym (not the actual category name/short), we do not strip
        // the word from the search query so that ranking matches the user's term.
        if (filter_category == null) {
            const sp = std.mem.indexOfScalar(u8, actual_query, ' ');
            const first_word = if (sp) |s| actual_query[0..s] else actual_query;
            if (findCategorySpecMatch(categories_spec, first_word)) |m| {
                filter_category = first_word;
                if (!m.is_synonym) {
                    actual_query = if (sp) |s| actual_query[s + 1 ..] else "";
                }
            }
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
            if (filter_box and !search_mod.isBoxArt(mru_emoji)) continue;
            if (!search_mod.braillePasses(mru_emoji, filter_braille, braille_dot_filter)) continue;

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
            if (filter_box and !search_mod.isBoxArt(entry.emoji)) continue;
            if (!search_mod.braillePasses(entry.emoji, filter_braille, braille_dot_filter)) continue;

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
            if (filter_box and !search_mod.isBoxArt(entry.emoji)) continue;
            if (!search_mod.braillePasses(entry.emoji, filter_braille, braille_dot_filter)) continue;

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
        if (filter_braille) search_mod.sortBrailleByDots(top_matches, top_count.*);
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
        if (filter_box and !search_mod.isBoxArt(entry.emoji)) continue;
        if (!search_mod.braillePasses(entry.emoji, filter_braille, braille_dot_filter)) continue;

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
            var score = if (search_mod.isBoxArt(entry.emoji)) raw_score - box_art_penalty else raw_score;
            if (search_mod.isBraille(entry.emoji)) score -= braille_penalty;
            // br: text searches still gate on relevance above, but order
            // purely by ascending dot count (fewer raised dots first).
            if (filter_braille) score = -@as(i32, @intCast(search_mod.brailleDotCount(entry.emoji)));
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
        const entry_offset = 32 + index * 12;
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
    pub const stem_excl_table_offset = std.mem.readInt(u32, data[24..28], .little);
    pub const stem_excl_count = std.mem.readInt(u32, data[28..32], .little);

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

    /// Returns true if the trailing-'e' stem fallback is suppressed for this term.
    pub fn isStemExcluded(term: []const u8) bool {
        const str_table = data[EmojiDb.string_table_offset..][0..EmojiDb.string_table_len];
        var i: usize = 0;
        while (i < stem_excl_count) : (i += 1) {
            const off = std.mem.readInt(u32, data[stem_excl_table_offset + i * 4 ..][0..4], .little);
            const entry = std.mem.sliceTo(str_table[off..], 0);
            if (std.mem.eql(u8, entry, term)) return true;
        }
        return false;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("root_test.zig");
    _ = @import("ranking_test.zig");
}
