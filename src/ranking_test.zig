// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const root = @import("root.zig");
const EmojiDb = root.EmojiDb;
const Match = root.Match;
const search = root.search;
const isBoxArt = root.isBoxArt;
const isBraille = root.isBraille;
const brailleDotCount = root.brailleDotCount;

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

test "ranking: category synonym search does not get confused" {
    const categories_json = @embedFile("spec_categories");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const categories = try std.json.parseFromSlice(root.CategoriesSpec, arena.allocator(), categories_json, .{ .ignore_unknown_fields = true });
    defer categories.deinit();

    var top_matches: [512]Match = undefined;
    var top_count: usize = 0;

    // Search "car" with categories_spec loaded:
    _ = root.searchOptions("car", &top_matches, &top_count, 24, &categories.value, &[_][]const u8{}, null);

    // We expect a car emoji like "🚗" to be ranked very high (e.g. within top 3),
    // and definitely not preceded by a page of non-car travel items.
    var car_rank: ?usize = null;
    for (top_matches[0..top_count], 0..) |m, i| {
        if (std.mem.eql(u8, EmojiDb.getEntry(m.index).emoji, "🚗")) {
            car_rank = i;
            break;
        }
    }

    try std.testing.expect(car_rank != null);
    try std.testing.expect(car_rank.? < 3);
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

// findRank returns the 1-based rank of `emoji` in the result slice, or 0.
fn findRank(emoji: []const u8, matches: []const Match, count: usize) usize {
    for (matches[0..count], 1..) |m, rank| {
        if (std.mem.eql(u8, EmojiDb.getEntry(m.index).emoji, emoji)) return rank;
    }
    return 0;
}

test "key symbol discoverability" {
    // Verifies keyboard-key symbols surface in the visible grid for typical queries.
    // Failures mean a char needs better keywords in spec/boxart.json or data/emoji.json.

    var top_matches: [1280]Match = undefined;
    var top_count: usize = 0;

    // ── Tab ────────────────────────────────────────────────────────────────
    // ⭾ U+2BBE primary; ⇥ U+21E5 secondary.  Both share name "tab".
    _ = search("tab", &top_matches, &top_count, 1280);
    const tab1 = findRank("⭾", top_matches[0..], top_count);
    const tab2 = findRank("⇥", top_matches[0..], top_count);
    std.debug.print("\n  tab        → ⭾ rank #{d}  ⇥ rank #{d}\n", .{ tab1, tab2 });
    try std.testing.expectEqual(@as(usize, 1), tab1);
    try std.testing.expect(tab2 > 0 and tab2 <= 6);

    _ = search("tab key", &top_matches, &top_count, 1280);
    const tab_key1 = findRank("⭾", top_matches[0..], top_count);
    std.debug.print("  tab key    → ⭾ rank #{d}\n", .{tab_key1});
    try std.testing.expectEqual(@as(usize, 1), tab_key1);

    // ── Space ──────────────────────────────────────────────────────────────
    // ⎵ U+2395  search: "space blank keyboard key …"
    _ = search("space key", &top_matches, &top_count, 1280);
    const sp1 = findRank("⎵", top_matches[0..], top_count);
    std.debug.print("  space key  → ⎵ rank #{d}\n", .{sp1});
    try std.testing.expectEqual(@as(usize, 1), sp1);

    _ = search("blank key", &top_matches, &top_count, 1280);
    const sp2 = findRank("⎵", top_matches[0..], top_count);
    std.debug.print("  blank key  → ⎵ rank #{d}\n", .{sp2});
    try std.testing.expect(sp2 > 0 and sp2 <= 6);

    // ── Enter / Return ─────────────────────────────────────────────────────
    // ↵ U+21B5  search: "enter return newline carriage keyboard key …"
    _ = search("enter key", &top_matches, &top_count, 1280);
    const en1 = findRank("↵", top_matches[0..], top_count);
    std.debug.print("  enter key  → ↵ rank #{d}\n", .{en1});
    try std.testing.expectEqual(@as(usize, 1), en1);

    _ = search("return key", &top_matches, &top_count, 1280);
    const en2 = findRank("↵", top_matches[0..], top_count);
    std.debug.print("  return key → ↵ rank #{d}\n", .{en2});
    try std.testing.expect(en2 > 0 and en2 <= 6);

    _ = search("enter", &top_matches, &top_count, 1280);
    const en3 = findRank("↵", top_matches[0..], top_count);
    std.debug.print("  enter      → ↵ rank #{d}\n", .{en3});
    try std.testing.expect(en3 > 0 and en3 <= 6);

    // ── Backspace ──────────────────────────────────────────────────────────
    // ⌫ U+232B  search: "backspace erase delete keyboard key …"
    _ = search("backspace", &top_matches, &top_count, 1280);
    const bs1 = findRank("⌫", top_matches[0..], top_count);
    std.debug.print("  backspace  → ⌫ rank #{d}\n", .{bs1});
    try std.testing.expectEqual(@as(usize, 1), bs1);

    _ = search("backspace key", &top_matches, &top_count, 1280);
    const bs2 = findRank("⌫", top_matches[0..], top_count);
    std.debug.print("  backspace key → ⌫ rank #{d}\n", .{bs2});
    try std.testing.expectEqual(@as(usize, 1), bs2);

    // ── Shift ──────────────────────────────────────────────────────────────
    // ⇧ U+21E7  search: "shift keyboard key …"
    _ = search("shift", &top_matches, &top_count, 1280);
    const sh1 = findRank("⇧", top_matches[0..], top_count);
    std.debug.print("  shift      → ⇧ rank #{d}\n", .{sh1});
    try std.testing.expectEqual(@as(usize, 1), sh1);

    _ = search("shift key", &top_matches, &top_count, 1280);
    const sh2 = findRank("⇧", top_matches[0..], top_count);
    std.debug.print("  shift key  → ⇧ rank #{d}\n", .{sh2});
    try std.testing.expectEqual(@as(usize, 1), sh2);

    // ── Escape ─────────────────────────────────────────────────────────────
    // ⎋ U+238B  search: "escape esc keyboard key …"
    _ = search("escape", &top_matches, &top_count, 1280);
    const es1 = findRank("⎋", top_matches[0..], top_count);
    std.debug.print("  escape     → ⎋ rank #{d}\n", .{es1});
    try std.testing.expect(es1 > 0 and es1 <= 6);

    _ = search("esc key", &top_matches, &top_count, 1280);
    const es2 = findRank("⎋", top_matches[0..], top_count);
    std.debug.print("  esc key    → ⎋ rank #{d}\n", .{es2});
    try std.testing.expectEqual(@as(usize, 1), es2);

    // ── Delete / Backspace ─────────────────────────────────────────────────
    // ⌦ U+2326  search: "delete forward erase keyboard key …"
    _ = search("delete forward", &top_matches, &top_count, 1280);
    const dl1 = findRank("⌦", top_matches[0..], top_count);
    std.debug.print("  delete forward → ⌦ rank #{d}\n", .{dl1});
    try std.testing.expectEqual(@as(usize, 1), dl1);

    _ = search("del key", &top_matches, &top_count, 1280);
    const dl2 = findRank("⌦", top_matches[0..], top_count);
    std.debug.print("  del key    → ⌦ rank #{d}\n", .{dl2});
    try std.testing.expect(dl2 > 0 and dl2 <= 24);

    // ── Ctrl / Control ─────────────────────────────────────────────────────
    // ⌃ U+2303  search: "ctrl control keyboard key …"
    _ = search("ctrl", &top_matches, &top_count, 1280);
    const ct1 = findRank("⌃", top_matches[0..], top_count);
    std.debug.print("  ctrl       → ⌃ rank #{d}\n", .{ct1});
    try std.testing.expectEqual(@as(usize, 1), ct1);

    _ = search("control key", &top_matches, &top_count, 1280);
    const ct2 = findRank("⌃", top_matches[0..], top_count);
    std.debug.print("  control key → ⌃ rank #{d}\n", .{ct2});
    try std.testing.expectEqual(@as(usize, 1), ct2);

    // ── Alt / Option ───────────────────────────────────────────────────────
    // ⌥ U+2325  search: "alt option keyboard key …"
    _ = search("alt key", &top_matches, &top_count, 1280);
    const al1 = findRank("⌥", top_matches[0..], top_count);
    std.debug.print("  alt key    → ⌥ rank #{d}\n", .{al1});
    try std.testing.expectEqual(@as(usize, 1), al1);

    _ = search("option key", &top_matches, &top_count, 1280);
    const al2 = findRank("⌥", top_matches[0..], top_count);
    std.debug.print("  option key → ⌥ rank #{d}\n", .{al2});
    try std.testing.expectEqual(@as(usize, 1), al2);

    // ── Command ────────────────────────────────────────────────────────────
    // ⌘ U+2318  name "cmd command" so greedy match hits "cmd" at position 0.
    _ = search("cmd", &top_matches, &top_count, 1280);
    const cm1 = findRank("⌘", top_matches[0..], top_count);
    std.debug.print("  cmd        → ⌘ rank #{d}\n", .{cm1});
    try std.testing.expectEqual(@as(usize, 1), cm1);

    _ = search("command key", &top_matches, &top_count, 1280);
    const cm2 = findRank("⌘", top_matches[0..], top_count);
    std.debug.print("  command key → ⌘ rank #{d}\n", .{cm2});
    try std.testing.expectEqual(@as(usize, 1), cm2);

    // ── Arrow keys ─────────────────────────────────────────────────────────
    // ↕/↔ now have "key" tag — "arrow keys" (plural → singular fallback) should find them.
    _ = search("up down arrow", &top_matches, &top_count, 1280);
    const ud1 = findRank("↕", top_matches[0..], top_count);
    std.debug.print("  up down arrow → ↕ rank #{d}\n", .{ud1});
    try std.testing.expect(ud1 > 0 and ud1 <= 6);

    _ = search("left right arrow", &top_matches, &top_count, 1280);
    const lr1 = findRank("↔", top_matches[0..], top_count);
    std.debug.print("  left right arrow → ↔ rank #{d}\n", .{lr1});
    try std.testing.expect(lr1 > 0 and lr1 <= 6);

    _ = search("arrow keys", &top_matches, &top_count, 1280);
    const ak1 = findRank("↕", top_matches[0..], top_count);
    const ak2 = findRank("↔", top_matches[0..], top_count);
    std.debug.print("  arrow keys → ↕ rank #{d}  ↔ rank #{d}\n", .{ ak1, ak2 });
    try std.testing.expect(ak1 > 0 and ak1 <= 24);
    try std.testing.expect(ak2 > 0 and ak2 <= 24);

    // ── Insert / Page Up / Page Down / Home / End ──────────────────────────
    _ = search("insert key", &top_matches, &top_count, 1280);
    const ins1 = findRank("⎀", top_matches[0..], top_count);
    std.debug.print("  insert key → ⎀ rank #{d}\n", .{ins1});
    try std.testing.expectEqual(@as(usize, 1), ins1);

    _ = search("page up", &top_matches, &top_count, 1280);
    const pu1 = findRank("⇞", top_matches[0..], top_count);
    std.debug.print("  page up    → ⇞ rank #{d}\n", .{pu1});
    try std.testing.expect(pu1 > 0 and pu1 <= 6);

    _ = search("page down", &top_matches, &top_count, 1280);
    const pd1 = findRank("⇟", top_matches[0..], top_count);
    std.debug.print("  page down  → ⇟ rank #{d}\n", .{pd1});
    try std.testing.expectEqual(@as(usize, 1), pd1);

    _ = search("home key", &top_matches, &top_count, 1280);
    const hm1 = findRank("⇱", top_matches[0..], top_count);
    std.debug.print("  home key   → ⇱ rank #{d}\n", .{hm1});
    try std.testing.expectEqual(@as(usize, 1), hm1);

    _ = search("end key", &top_matches, &top_count, 1280);
    const ed1 = findRank("⇲", top_matches[0..], top_count);
    std.debug.print("  end key    → ⇲ rank #{d}\n", .{ed1});
    try std.testing.expectEqual(@as(usize, 1), ed1);

    // ── Generic keyboard queries ───────────────────────────────────────────
    _ = search("keyboard", &top_matches, &top_count, 1280);
    const kb1 = findRank("⭾", top_matches[0..], top_count);
    const kb2 = findRank("↵", top_matches[0..], top_count);
    std.debug.print("  keyboard   → ⭾ rank #{d}  ↵ rank #{d}\n", .{ kb1, kb2 });
    try std.testing.expect(kb1 > 0 and kb1 <= 24);
    try std.testing.expect(kb2 > 0 and kb2 <= 24);
}

test "block element discoverability: sparkline and progress bar chars" {
    // Lower blocks ▁▂▃▄▅▆▇█ (U+2581-2588) — for sparklines / bar charts.
    // Left  blocks ▏▎▍▌▋▊▉█ (U+258F-2589) — for progress bars / gauges.
    // All must surface with 'b:' prefix (box-art filter) and their semantic tags.

    var top_matches: [1280]Match = undefined;
    var top_count: usize = 0;

    // ── sparkline queries ──────────────────────────────────────────────────
    _ = search("b: sparkline", &top_matches, &top_count, 1280);
    const sl_tiny = findRank("▁", top_matches[0..], top_count);
    const sl_qtr = findRank("▂", top_matches[0..], top_count);
    const sl_half = findRank("▄", top_matches[0..], top_count);
    const sl_full = findRank("█", top_matches[0..], top_count);
    std.debug.print("\n  b: sparkline → ▁#{d}  ▂#{d}  ▄#{d}  █#{d}\n", .{ sl_tiny, sl_qtr, sl_half, sl_full });
    try std.testing.expect(sl_tiny > 0 and sl_tiny <= 10);
    try std.testing.expect(sl_qtr > 0 and sl_qtr <= 10);
    try std.testing.expect(sl_half > 0 and sl_half <= 10);
    try std.testing.expect(sl_full > 0 and sl_full <= 10);

    _ = search("b: spark", &top_matches, &top_count, 1280);
    const sp1 = findRank("▃", top_matches[0..], top_count);
    const sp2 = findRank("▇", top_matches[0..], top_count);
    std.debug.print("  b: spark     → ▃#{d}  ▇#{d}\n", .{ sp1, sp2 });
    try std.testing.expect(sp1 > 0 and sp1 <= 10);
    try std.testing.expect(sp2 > 0 and sp2 <= 10);

    _ = search("b: lower block", &top_matches, &top_count, 1280);
    const lb1 = findRank("▁", top_matches[0..], top_count);
    const lb2 = findRank("▅", top_matches[0..], top_count);
    const lb3 = findRank("▆", top_matches[0..], top_count);
    std.debug.print("  b: lower block → ▁#{d}  ▅#{d}  ▆#{d}\n", .{ lb1, lb2, lb3 });
    try std.testing.expect(lb1 > 0 and lb1 <= 10);
    try std.testing.expect(lb2 > 0 and lb2 <= 10);
    try std.testing.expect(lb3 > 0 and lb3 <= 10);

    // ── progress bar queries ───────────────────────────────────────────────
    _ = search("b: progress", &top_matches, &top_count, 1280);
    const pg_eighth = findRank("▏", top_matches[0..], top_count);
    const pg_half = findRank("▌", top_matches[0..], top_count);
    const pg_full = findRank("█", top_matches[0..], top_count);
    std.debug.print("  b: progress  → ▏#{d}  ▌#{d}  █#{d}\n", .{ pg_eighth, pg_half, pg_full });
    try std.testing.expect(pg_eighth > 0 and pg_eighth <= 10);
    try std.testing.expect(pg_half > 0 and pg_half <= 10);
    try std.testing.expect(pg_full > 0 and pg_full <= 10);

    _ = search("b: left block", &top_matches, &top_count, 1280);
    const lf1 = findRank("▏", top_matches[0..], top_count);
    const lf2 = findRank("▎", top_matches[0..], top_count);
    const lf3 = findRank("▍", top_matches[0..], top_count);
    const lf4 = findRank("▋", top_matches[0..], top_count);
    const lf5 = findRank("▊", top_matches[0..], top_count);
    const lf6 = findRank("▉", top_matches[0..], top_count);
    std.debug.print("  b: left block → ▏#{d} ▎#{d} ▍#{d} ▋#{d} ▊#{d} ▉#{d}\n", .{ lf1, lf2, lf3, lf4, lf5, lf6 });
    try std.testing.expect(lf1 > 0 and lf1 <= 10);
    try std.testing.expect(lf2 > 0 and lf2 <= 10);
    try std.testing.expect(lf3 > 0 and lf3 <= 10);
    try std.testing.expect(lf4 > 0 and lf4 <= 10);
    try std.testing.expect(lf5 > 0 and lf5 <= 10);
    try std.testing.expect(lf6 > 0 and lf6 <= 10);

    _ = search("b: gauge", &top_matches, &top_count, 1280);
    const ga1 = findRank("▏", top_matches[0..], top_count);
    const ga2 = findRank("▌", top_matches[0..], top_count);
    std.debug.print("  b: gauge     → ▏#{d}  ▌#{d}\n", .{ ga1, ga2 });
    try std.testing.expect(ga1 > 0 and ga1 <= 10);
    try std.testing.expect(ga2 > 0 and ga2 <= 10);
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
