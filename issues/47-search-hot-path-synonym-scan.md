<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: open
---

# Search hot path: unconditional synonym scan costs ~4-5ms per keystroke

**Priority: P1** (directly affects perceived typing latency, and it's easy
to fix without touching the zero-allocation invariant)

## Summary

The type-query → `runSearch` → render path is documented as zero-allocation
and mostly *is* clean (see confirmation below), but `matchTerm` in
`src/search.zig` does an **unconditional full linear scan of the entire
synonym table for every query term against every DB entry**, even when a
direct match already succeeded. This is the dominant cost in the hot path
and is directly visible in the project's own benchmark test output.

## Evidence

`zig build test -Doptimize=ReleaseSafe -Dllvm=false` already runs a search
benchmark (`search benchmarks (release, 10 ms/query, 2533 emojis)`) whose
output is otherwise not asserted against any threshold:

```
bench [                  ]       306 iters    32716 ns/search      30565 searches/s
bench [a                 ]         3 iters  4161103 ns/search        240 searches/s
bench [fire              ]         3 iters  4593568 ns/search        217 searches/s
bench [red heart         ]         2 iters  5469130 ns/search        182 searches/s
bench [hearts            ]         3 iters  4195083 ns/search        238 searches/s
bench [xyzxyz            ]         3 iters  4016365 ns/search        248 searches/s
```

The **empty query** (hits the MRU/dedup fast path, no per-entry matching)
is ~33µs. Every **non-empty** query — even a single letter, even a query
with zero matches (`xyzxyz`) — costs **4–5.5ms**. That's a ~130-170x jump,
and it happens on every keystroke while a user is typing, not just once.
At 4-5ms per keystroke this is within human-perceptible range for fast
typists and eats directly into the frame budget the render path also needs.

## Root cause

`src/search.zig:209-234`, `matchTerm`:

```zig
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
                ...
            }
        }
    }
    return best_score;
}
```

This loop runs **every time `matchTerm` is called**, regardless of whether
`matchTermSelf` already found a match — there's no early exit, and the
comparison is `std.mem.eql` against every one of `SynonymDb.synonym_count`
entries (~300-400 pairs, per `main.zig`'s own debug-pane counter), not an
index or hashmap keyed by term. `matchTerm` is called per query term, per
DB entry, inside `runSearch`'s `root.zig:385` loop over all 2249 embedded
emojis. Worst case for a 2-term query: ~2249 × 2 × ~350 ≈ 1.57M
`std.mem.eql` string comparisons per keystroke.

Confirmed no accidental heap allocation exists anywhere in this path
(`src/root.zig`, `src/search.zig`, `src/tui_draw.zig`, `src/render.zig`
all use stack buffers / `FixedBufferAllocator` only, and both
`getSearchSpec()` and `getGlobalCategoriesSpec()` are lazily cached on
first call, not reparsed per keystroke) — the cost here is pure CPU work,
not allocation.

## Secondary finding: empty-query path does ~4 redundant full-DB passes

`src/root.zig:247-381` (fires on startup and every backspace-to-empty):
resolving each of up to `mru.MAX_MRU = 64` MRU entries to a DB index does
a full `O(EmojiDb.count)` linear scan per entry (~261-294) — up to
64 × 2249 ≈ 144K comparisons — on top of two more separate full-DB passes
(fill remainder ~297-341, count total ~343-378). This is lower priority
than the synonym scan (the benchmark shows the empty-query path is still
by far the fastest at ~33µs — dedup in `main.zig`'s `searchDedup` means it
usually doesn't even run), but the remainder-fill and total-count passes
at minimum could merge into one traversal.

## Recommended fix (not applied in this pass — see below)

- **Primary**: short-circuit the synonym loop once a same-or-better direct
  match is found where further synonym expansion can't beat it, *or*
  (better long-term) replace the linear `SynonymDb` scan with a sorted
  table + binary search, or a precomputed hashmap keyed by `from` term
  built once at spec-load time (mirrors how `getSearchSpec()` is already
  cached once). Given the zero-allocation constraint, a sorted array +
  binary search is the safer fit (`spec/synonyms.yaml` could be
  pre-sorted by the packer/generator at `make gen-spec` time, so the
  runtime just does `std.sort.binarySearch`, no allocation, no build-time
  behavior change visible to humans editing the YAML).
- **Secondary**: merge the two full-DB passes in the empty-query path
  (`root.zig` ~297-378) into one loop.
- **Guard against regression**: promote the existing benchmark output
  (`zig build test`'s `search benchmarks` block) from print-only to an
  actual assertion — e.g. `try std.testing.expect(ns_per_search <
  threshold)` for the representative single-letter/broad-query case. Right
  now this instrumentation exists (`main.zig:98-121` `SearchStats` +
  `getMonotonicUs()` are also wired into a live debug-pane counter) but
  nothing in CI fails if search latency regresses further.

## Why this wasn't fixed directly in this pass

Changing `SynonymDb`'s scan strategy touches the packer/generator
(`spec/synonyms.yaml` → `spec/.gen/`), the runtime lookup in
`src/search.zig`, and needs before/after benchmark verification plus
`zig build test` + `go run ./scripts/test_tui` regression checks across
both the Zig and Go search engines (they must stay in parity). That's a
medium-effort, multi-file change, not a "very small fix" — left for a
dedicated follow-up per the review's own ground rules. The benchmark
numbers above are already reproducible today via `zig build test
-Doptimize=ReleaseSafe -Dllvm=false` and give a concrete before/after bar
for that follow-up to hit (target: get non-empty single/short queries back
down toward the same order of magnitude as the empty-query fast path,
i.e. well under 1ms).
