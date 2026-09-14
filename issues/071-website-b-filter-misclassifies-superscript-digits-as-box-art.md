<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 071 — Website b: filter misclassifies superscript digits as box art

**Status**: Open
**Priority**: P2 (Medium)
**Severity**: Moderate
**Category**: Bug
**Related**: 264bcfe, docs/SearchEngine.md §11

---

## 1. Problem & Motivation

Commit 264bcfe added ten superscript digits to `spec/boxart.yaml`. The Zig app intentionally exempts them from box-art classification: `b:superscript` returns no results, and ordinary searches do not apply the box-art ranking penalty. The website disagrees. Its generated `box_art.ranges` includes U+00B2–U+00B9 and U+2070–U+2079, so `website/simulator.js` classifies the digits as box art. Thus `b:superscript` returns digits on the website, and regular searches penalize them there.

## 2. Technical Specification / Findings

- `scripts/gen_web_spec/main.go` derives `box_art.ranges` from every entry in `spec/boxart.yaml`, including entries outside the Zig `isBoxArt` bands. The 256-codepoint gap merger can also include codepoints that are not entries.
- `website/webspec.js` currently contains superscript ranges `[178,185]` and `[8304,8313]`.
- `website/simulator.js` uses these ranges for both `b:` filtering and the box-art score penalty.
- `src/search.zig` classifies only U+2500–U+259F and U+1FB00–U+1FB3B as box art. `src/root_test.zig` explicitly asserts that superscripts are excluded.

## 3. Implementation & Verification Plan

Make the generated website classification mirror the Zig predicate, while preserving the disjoint range handling needed for sextants. Do not derive the classification bands from every entry in the mixed-purpose spec file. Add a website regression check that verifies `b:superscript` yields no digits and ordinary superscript results receive no box-art penalty; also check that actual box drawing and sextant glyphs remain classified. Regenerate `website/webspec.js` and run the relevant website and Zig tests.
