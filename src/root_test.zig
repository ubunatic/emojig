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

fn searchContains(query: []const u8, wanted_emoji: []const u8) bool {
    var top_matches: [24]Match = undefined;
    var top_count: usize = 0;
    _ = search(query, &top_matches, &top_count, 24);
    for (top_matches[0..top_count]) |m| {
        const entry = EmojiDb.getEntry(m.index);
        if (std.mem.eql(u8, entry.emoji, wanted_emoji)) return true;
    }
    return false;
}

/// Returns the 0-based rank of wanted_emoji in the top `limit` results, or
/// null if not found. Supports limits up to 512.
fn searchRank(query: []const u8, wanted_emoji: []const u8, limit: usize) ?usize {
    var top_matches: [512]Match = undefined;
    var top_count: usize = 0;
    const actual_limit = @min(limit, top_matches.len);
    _ = search(query, &top_matches, &top_count, actual_limit);
    for (top_matches[0..top_count], 0..) |m, i| {
        if (std.mem.eql(u8, EmojiDb.getEntry(m.index).emoji, wanted_emoji)) return i;
    }
    return null;
}

fn inTop(query: []const u8, wanted_emoji: []const u8, n: usize) bool {
    const rank = searchRank(query, wanted_emoji, n) orelse return false;
    return rank < n;
}

test "ranking: vehicles — car, truck, bike, plane, ship, rocket" {
    // car: main word → top 3; oncoming variant → top 10
    try std.testing.expect(inTop("car", "🚗", 3));
    try std.testing.expect(inTop("car", "🚘", 10));
    // auto: synonym for automobile → both variants top 10
    try std.testing.expect(inTop("auto", "🚗", 10));
    try std.testing.expect(inTop("auto", "🚘", 10));
    // truck: delivery truck top 3; articulated lorry and pickup top 10
    try std.testing.expect(inTop("truck", "🚚", 3));
    try std.testing.expect(inTop("truck", "🚛", 10));
    try std.testing.expect(inTop("truck", "🛻", 10));
    // bicycle / bike
    try std.testing.expect(inTop("bike", "🚲", 5));
    try std.testing.expect(inTop("bicycle", "🚲", 3));
    // plane
    try std.testing.expect(inTop("plane", "✈️", 3));
    // ship / rocket
    try std.testing.expect(inTop("ship", "🚢", 5));
    try std.testing.expect(inTop("rocket", "🚀", 3));
    // motorbike / scooter
    try std.testing.expect(inTop("motorcycle", "🏍️", 3));
}

test "ranking: animals — common mammals" {
    // big cats
    try std.testing.expect(inTop("tiger", "🐅", 3));
    try std.testing.expect(inTop("tiger", "🐯", 10));
    try std.testing.expect(inTop("lion", "🦁", 3));
    // dogs and cats
    try std.testing.expect(inTop("dog", "🐕", 3));
    try std.testing.expect(inTop("dog", "🐶", 10));
    try std.testing.expect(inTop("cat", "🐱", 5));
    try std.testing.expect(inTop("cat", "🐈", 10));
    // farm animals
    try std.testing.expect(inTop("horse", "🐎", 10));
    try std.testing.expect(inTop("horse", "🐴", 10));
    try std.testing.expect(inTop("cow", "🐮", 3));
    try std.testing.expect(inTop("cow", "🐄", 10));
    try std.testing.expect(inTop("pig", "🐷", 3));
    try std.testing.expect(inTop("pig", "🐖", 10));
    try std.testing.expect(inTop("rabbit", "🐰", 3));
    try std.testing.expect(inTop("rabbit", "🐇", 10));
    // large mammals
    try std.testing.expect(inTop("elephant", "🐘", 3));
    try std.testing.expect(inTop("bear", "🐻", 3));
    try std.testing.expect(inTop("monkey", "🐒", 3));
    try std.testing.expect(inTop("monkey", "🐵", 10));
    // misc
    try std.testing.expect(inTop("snake", "🐍", 3));
    try std.testing.expect(inTop("frog", "🐸", 3));
    try std.testing.expect(inTop("dragon", "🐉", 3));
    try std.testing.expect(inTop("dragon", "🐲", 10));
    try std.testing.expect(inTop("bat", "🦇", 3));
    try std.testing.expect(inTop("wolf", "🐺", 3));
    try std.testing.expect(inTop("fox", "🦊", 3));
    try std.testing.expect(inTop("panda", "🐼", 3));
    try std.testing.expect(inTop("koala", "🐨", 3));
}

test "ranking: animals — birds, fish, insects" {
    // birds: primary bird emoji + specific species
    try std.testing.expect(inTop("bird", "🐦", 3));
    try std.testing.expect(inTop("bird", "🦅", 10));
    try std.testing.expect(inTop("bird", "🦜", 10));
    try std.testing.expect(inTop("bird", "🦉", 10));
    try std.testing.expect(inTop("bird", "🦆", 10));
    try std.testing.expect(inTop("bird", "🐧", 10));
    try std.testing.expect(inTop("eagle", "🦅", 3));
    try std.testing.expect(inTop("owl", "🦉", 3));
    try std.testing.expect(inTop("penguin", "🐧", 3));
    try std.testing.expect(inTop("chicken", "🐔", 3));
    try std.testing.expect(inTop("duck", "🦆", 3));
    // fish and sea creatures
    try std.testing.expect(inTop("fish", "🐟", 3));
    try std.testing.expect(inTop("fish", "🐠", 10));
    try std.testing.expect(inTop("fish", "🐡", 10));
    try std.testing.expect(inTop("shark", "🦈", 3));
    try std.testing.expect(inTop("whale", "🐳", 3));
    try std.testing.expect(inTop("dolphin", "🐬", 3));
    // insects
    try std.testing.expect(inTop("bee", "🐝", 3));
    try std.testing.expect(inTop("butterfly", "🦋", 3));
    try std.testing.expect(inTop("bug", "🐛", 3));
    try std.testing.expect(inTop("ant", "🐜", 3));
}

test "ranking: nature — plants, trees, flowers, weather, landscapes" {
    // plants
    try std.testing.expect(inTop("tree", "🌲", 5));
    try std.testing.expect(inTop("tree", "🌳", 5));
    try std.testing.expect(inTop("mushroom", "🍄", 3));
    try std.testing.expect(inTop("cactus", "🌵", 3));
    try std.testing.expect(inTop("sunflower", "🌻", 3));
    try std.testing.expect(inTop("rose", "🌹", 3));
    // flowers: common term returns rose/tulip/hibiscus
    try std.testing.expect(inTop("flower", "🌹", 10));
    try std.testing.expect(inTop("flower", "🌸", 10));
    try std.testing.expect(inTop("flower", "🌺", 10));
    try std.testing.expect(inTop("flower", "🌻", 10));
    // weather
    try std.testing.expect(inTop("rain", "🌧️", 3));
    try std.testing.expect(inTop("cloud", "☁️", 3));
    try std.testing.expect(inTop("snow", "❄️", 10));
    try std.testing.expect(inTop("snow", "⛄", 10));
    try std.testing.expect(inTop("lightning", "⚡", 3));
    try std.testing.expect(inTop("rainbow", "🌈", 3));
    try std.testing.expect(inTop("sun", "🌞", 5));
    try std.testing.expect(inTop("sun", "☀️", 10));
    try std.testing.expect(inTop("moon", "🌙", 10));
    try std.testing.expect(inTop("moon", "🌝", 10));
    // landscapes
    try std.testing.expect(inTop("mountain", "⛰️", 3));
    try std.testing.expect(inTop("mountain", "🏔️", 10));
    try std.testing.expect(inTop("wave", "🌊", 5));
    try std.testing.expect(inTop("volcano", "🌋", 3));
}

test "ranking: food and drink" {
    try std.testing.expect(inTop("pizza", "🍕", 3));
    try std.testing.expect(inTop("coffee", "☕", 3));
    try std.testing.expect(inTop("beer", "🍺", 3));
    try std.testing.expect(inTop("burger", "🍔", 3));
    try std.testing.expect(inTop("sushi", "🍣", 3));
    try std.testing.expect(inTop("cake", "🎂", 5));
    try std.testing.expect(inTop("apple", "🍎", 3));
    try std.testing.expect(inTop("banana", "🍌", 3));
    try std.testing.expect(inTop("strawberry", "🍓", 3));
    try std.testing.expect(inTop("grape", "🍇", 3));
    try std.testing.expect(inTop("bread", "🍞", 3));
    try std.testing.expect(inTop("egg", "🥚", 3));
    try std.testing.expect(inTop("cheese", "🧀", 3));
    try std.testing.expect(inTop("rice", "🍚", 3));
    try std.testing.expect(inTop("noodle", "🍜", 3));
}

test "ranking: common objects and symbols" {
    // keys and locks
    try std.testing.expect(inTop("key", "🔑", 5));
    try std.testing.expect(inTop("key", "🗝️", 5));
    try std.testing.expect(inTop("lock", "🔒", 3));
    // tools
    try std.testing.expect(inTop("hammer", "🔨", 3));
    try std.testing.expect(inTop("wrench", "🔧", 3));
    try std.testing.expect(inTop("scissors", "✂️", 3));
    try std.testing.expect(inTop("pencil", "✏️", 3));
    // communication
    try std.testing.expect(inTop("phone", "📱", 10));
    try std.testing.expect(inTop("phone", "☎️", 5));
    try std.testing.expect(inTop("book", "📖", 5));
    try std.testing.expect(inTop("book", "📚", 10));
    try std.testing.expect(inTop("mail", "📧", 24));
    // symbols
    try std.testing.expect(inTop("heart", "❤️", 3));
    try std.testing.expect(inTop("star", "⭐", 3));
    try std.testing.expect(inTop("fire", "🔥", 3));
    try std.testing.expect(inTop("ghost", "👻", 3));
    try std.testing.expect(inTop("robot", "🤖", 3));
    try std.testing.expect(inTop("crown", "👑", 5));
    try std.testing.expect(inTop("skull", "💀", 3));
    try std.testing.expect(inTop("diamond", "💎", 3));
    try std.testing.expect(inTop("money", "💰", 10));
    try std.testing.expect(inTop("house", "🏠", 3));
    try std.testing.expect(inTop("music", "🎵", 10));
    try std.testing.expect(inTop("music", "🎶", 10));
}

test "ranking: category keyword injection makes categories searchable" {
    // The packer injects a canonical keyword for each category into every
    // emoji's search string.  A combined keyword + term search surfaces the
    // right emoji from within its category.  Note: querying the keyword alone
    // may fuzzy-match hundreds of emojis, so we use combined queries here.

    // Animals & Nature → keyword "animal"
    try std.testing.expect(inTop("animal lion", "🦁", 24));
    try std.testing.expect(inTop("animal elephant", "🐘", 24));
    try std.testing.expect(inTop("animal snake", "🐍", 24));
    try std.testing.expect(inTop("animal fish", "🐟", 24));

    // Food & Drink → keyword "food"
    try std.testing.expect(inTop("food pizza", "🍕", 24));
    try std.testing.expect(inTop("food coffee", "☕", 24));
    try std.testing.expect(inTop("food beer", "🍺", 24));

    // Travel & Places → keyword "travel"
    try std.testing.expect(inTop("travel car", "🚗", 24));
    try std.testing.expect(inTop("travel plane", "✈️", 24));
    try std.testing.expect(inTop("travel ship", "🚢", 24));

    // Activities → keyword "activity"
    try std.testing.expect(inTop("activity soccer", "⚽", 24));
    try std.testing.expect(inTop("activity basketball", "🏀", 24));
}

test "discoverability: sparkle, server, terminal, emojig, and speed adjectives" {
    try std.testing.expect(searchContains("sparkl", "🍾"));
    try std.testing.expect(searchContains("server", "🖥️"));
    try std.testing.expect(searchContains("terminal", "🖥️"));
    try std.testing.expect(searchContains("terminal", "💻"));
    try std.testing.expect(searchContains("emojig", "😀"));

    try std.testing.expect(searchContains("fast", "🚤"));
    try std.testing.expect(searchContains("fast", "🏎️"));
    try std.testing.expect(searchContains("fast", "🐎"));
    try std.testing.expect(searchContains("fast", "🚀"));

    try std.testing.expect(searchContains("speed", "🚤"));
    try std.testing.expect(searchContains("rapid", "🚤"));
    try std.testing.expect(searchContains("speedy", "🚤"));
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
        var parsed = try std.json.parseFromSlice(Strings, allocator, spec_json, .{ .ignore_unknown_fields = true });
        parsed.deinit();
    }
}

test "ranking: cars — vehicle search" {
    // "cars" fuzzy-matches vehicle emojis via plural stem + word-position heuristic.
    // All four main car variants must land in top 10; trucks also in top 20.
    try std.testing.expect(inTop("cars", "🚗", 10)); // automobile (baseline)
    try std.testing.expect(inTop("cars", "🚘", 10)); // oncoming automobile
    try std.testing.expect(inTop("cars", "🚙", 10)); // sport utility vehicle
    try std.testing.expect(inTop("cars", "🛻", 10)); // pickup truck
    try std.testing.expect(inTop("cars", "🚚", 20)); // delivery truck
    try std.testing.expect(inTop("cars", "🚛", 20)); // articulated lorry
}

test "ranking: sparkling — champagne and clinking glasses" {
    // "sparkling" should surface 🍾 and 🥂 in the top 10.
    try std.testing.expect(inTop("sparkling", "🍾", 10));
    try std.testing.expect(inTop("sparkling", "🥂", 10));
}

test "ranking: glass / glasses — drinkware" {
    // "glass": five core drinkware emojis in top 10; champagne/cup/crystal in top 20.
    try std.testing.expect(inTop("glass", "🍷", 10)); // wine glass
    try std.testing.expect(inTop("glass", "🍸", 10)); // cocktail glass
    try std.testing.expect(inTop("glass", "🥂", 10)); // clinking glasses
    try std.testing.expect(inTop("glass", "🥛", 10)); // glass of milk
    try std.testing.expect(inTop("glass", "🥃", 10)); // tumbler glass
    try std.testing.expect(inTop("glass", "🍾", 20)); // champagne bottle
    try std.testing.expect(inTop("glass", "🥤", 20)); // cup with straw
    try std.testing.expect(inTop("glass", "🔮", 20)); // crystal ball

    // "glasses": same drinkware visible within top 15 (eyewear occupies top 5 slots).
    try std.testing.expect(inTop("glasses", "🍷", 10));
    try std.testing.expect(inTop("glasses", "🍸", 10));
    try std.testing.expect(inTop("glasses", "🥂", 10));
    try std.testing.expect(inTop("glasses", "🥛", 10));
    try std.testing.expect(inTop("glasses", "🥃", 15));
    try std.testing.expect(inTop("glasses", "🍾", 20));
    try std.testing.expect(inTop("glasses", "🥤", 20));
    try std.testing.expect(inTop("glasses", "🔮", 20));
}

test "ranking: lens — magnifying glass and crystal ball" {
    // "lens" should surface 🔍 and 🔎 in the top 10; crystal ball in top 20.
    try std.testing.expect(inTop("lens", "🔍", 10));
    try std.testing.expect(inTop("lens", "🔎", 10));
    try std.testing.expect(inTop("lens", "🔮", 20));
}

fn benchNowNs() u64 {
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

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
    const duration_ms: u64 = blk: {
        const env = std.c.getenv("EMOJIG_BENCH") orelse break :blk 10;
        const val = std.mem.sliceTo(env, 0);
        break :blk std.fmt.parseInt(u64, val, 10) catch 10;
    };
    const is_release = @import("builtin").mode != .Debug;
    const build_label = if (is_release) "release" else "debug";
    std.debug.print("\nsearch benchmarks ({s}, {d} ms/query, {d} emojis):\n", .{ build_label, duration_ms, EmojiDb.count });

    _ = runBench("", duration_ms);
    const ns_a = runBench("a", duration_ms);
    const ns_fire = runBench("fire", duration_ms);
    const ns_multi = runBench("red heart", duration_ms);
    const ns_plural = runBench("hearts", duration_ms);
    _ = runBench("xyzxyz", duration_ms);

    if (duration_ms > 10 and is_release) {
        const max_ns: u64 = 5_000_000;
        try std.testing.expect(ns_a < max_ns);
        try std.testing.expect(ns_fire < max_ns);
        try std.testing.expect(ns_multi < max_ns);
        try std.testing.expect(ns_plural < max_ns);
    }
}
