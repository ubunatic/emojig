// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const root = @import("root.zig");
const EmojiDb = root.EmojiDb;
const SynonymDb = root.SynonymDb;
const Match = root.Match;

/// Match a single search term against a target search string.
/// Returns a score if the term is a subsequence of the target, or null otherwise.
pub fn matchTermDirect(term: []const u8, target: []const u8) ?i32 {
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
pub fn matchTermSelf(term: []const u8, target: []const u8) ?i32 {
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

/// True for box-drawing and block-element glyphs (U+2500–U+259F), the
/// entries from spec/boxart.json. Used by the b: filter and ranking.
pub fn isBoxArt(emoji: []const u8) bool {
    const view = std.unicode.Utf8View.init(emoji) catch return false;
    var iterator = view.iterator();
    const cp = iterator.nextCodepoint() orelse return false;
    return cp >= 0x2500 and cp <= 0x259F;
}

/// True for Braille pattern glyphs (U+2800–U+28FF), the entries from
/// spec/braille.json. Used by the br: filter and ranking.
pub fn isBraille(emoji: []const u8) bool {
    const view = std.unicode.Utf8View.init(emoji) catch return false;
    var iterator = view.iterator();
    const cp = iterator.nextCodepoint() orelse return false;
    return cp >= 0x2800 and cp <= 0x28FF;
}

/// Number of raised dots (0-8) encoded by a Braille pattern codepoint: each
/// of the 8 low bits of (cp - 0x2800) marks one dot position.
pub fn brailleDotCount(emoji: []const u8) u32 {
    const view = std.unicode.Utf8View.init(emoji) catch return 0;
    var iterator = view.iterator();
    const cp = iterator.nextCodepoint() orelse return 0;
    if (cp < 0x2800 or cp > 0x28FF) return 0;
    return @popCount(@as(u8, @intCast(cp - 0x2800)));
}

/// Whether `emoji` survives the br: filter: a Braille glyph, and (if set)
/// matching the exact dot count requested by "br:<n>".
pub fn braillePasses(emoji: []const u8, active: bool, dot_filter: ?u32) bool {
    if (!active) return true;
    if (!isBraille(emoji)) return false;
    if (dot_filter) |dc| {
        if (brailleDotCount(emoji) != dc) return false;
    }
    return true;
}

/// Stable ascending sort of `matches[0..count]` by Braille dot count, used
/// so br: results list simpler (fewer-dot) patterns first.
pub fn sortBrailleByDots(matches: []Match, count: usize) void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const key = matches[i];
        const key_dots = brailleDotCount(EmojiDb.getEntry(key.index).emoji);
        var j = i;
        while (j > 0) {
            const prev_dots = brailleDotCount(EmojiDb.getEntry(matches[j - 1].index).emoji);
            if (prev_dots <= key_dots) break;
            matches[j] = matches[j - 1];
            j -= 1;
        }
        matches[j] = key;
    }
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
