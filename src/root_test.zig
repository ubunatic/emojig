// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const root = @import("root.zig");
const EmojiDb = root.EmojiDb;
const SynonymDb = root.SynonymDb;
const Match = root.Match;
const fuzzyMatch = root.fuzzyMatch;
const search = root.search;
const getEmojiWidth = root.getEmojiWidth;
const isBoxArt = root.isBoxArt;
const isBraille = root.isBraille;
const brailleDotCount = root.brailleDotCount;
const stripVariationSelectors = root.stripVariationSelectors;

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
    try std.testing.expectEqual(@as(u16, 3), EmojiDb.version);
    try std.testing.expect(EmojiDb.count > 0);

    const first = EmojiDb.getEntry(0);
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

test "braille entries: br: filter, dot-count shorthand, and ascending dot order" {
    var top_matches: [300]Match = undefined;
    var top_count: usize = 0;

    // br: with empty query lists only Braille patterns, sorted by ascending dots.
    var total = search("br:", &top_matches, &top_count, 300);
    try std.testing.expectEqual(@as(usize, 256), total);
    try std.testing.expectEqual(@as(usize, 256), top_count);
    for (top_matches[0..top_count]) |m| {
        try std.testing.expect(isBraille(EmojiDb.getEntry(m.index).emoji));
    }
    var prev_dots: u32 = 0;
    for (top_matches[0..top_count]) |m| {
        const dots = brailleDotCount(EmojiDb.getEntry(m.index).emoji);
        try std.testing.expect(dots >= prev_dots);
        prev_dots = dots;
    }
    // The blank cell (0 dots) comes first, the full 8-dot cell last.
    try std.testing.expect(std.mem.eql(u8, EmojiDb.getEntry(top_matches[0].index).emoji, "⠀"));
    try std.testing.expect(std.mem.eql(u8, EmojiDb.getEntry(top_matches[top_count - 1].index).emoji, "⣿"));

    // "br:<n>" and "br:<n>:" both filter to exactly n raised dots.
    top_count = 0;
    total = search("br:1", &top_matches, &top_count, 300);
    try std.testing.expectEqual(@as(usize, 8), total);
    for (top_matches[0..top_count]) |m| {
        try std.testing.expectEqual(@as(u32, 1), brailleDotCount(EmojiDb.getEntry(m.index).emoji));
    }

    top_count = 0;
    _ = search("br:1:", &top_matches, &top_count, 300);
    try std.testing.expectEqual(@as(usize, 8), top_count);

    // br: name search still filters to Braille glyphs only.
    top_count = 0;
    _ = search("br:dots 1 2", &top_matches, &top_count, 300);
    try std.testing.expect(top_count > 0);
    for (top_matches[0..top_count]) |m| {
        try std.testing.expect(isBraille(EmojiDb.getEntry(m.index).emoji));
    }

    // General searches rank Braille patterns below genuine emoji matches.
    top_count = 0;
    _ = search("dots", &top_matches, &top_count, 300);
    try std.testing.expect(top_count > 0);
    try std.testing.expect(!isBraille(EmojiDb.getEntry(top_matches[0].index).emoji));
}
