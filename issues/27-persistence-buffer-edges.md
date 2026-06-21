<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 27 — Config and MRU persistence still have silent 4 KB edge behavior

**Status:** Open  
**Priority:** P2

## Problem

Closed issue 01 fixed the original 1 KB config truncation problem, but the same
class of edge case still exists at the current 4 KB buffer boundary.

Two separate behaviors are still worth fixing:

1. **Config loader hard-stop:** `src/config.zig` bails out to defaults when the
   read fills the 4 KB buffer exactly.
2. **MRU loader silent truncation:** `src/mru.zig` uses the same 4 KB single-read
   pattern, but has no full-buffer guard at all.

That means settings/state persistence is still vulnerable to "silent wrong
behavior at the fixed-size boundary", just with a larger threshold than before.

## Evidence

- `src/config.zig:62` — `if (len == file_buf.len) return cfg;`
- `src/mru.zig:31-32` — 4 KB buffer + single read, but no full-buffer check
- `issues/closed/01-config-file-silent-truncation.md:4` — old issue explicitly documents the earlier version of this same class of problem

## Reproduction

```sh
go run ./scripts/review_audit persistence-buffer-edges
```

Current result: **fails**, because the config loader still treats a full-page
read as "load nothing", while MRU still has no equivalent guard.

## Why this matters

This is less urgent than the install/update trust gap, but it is still a real
resilience issue:

- a power-user config can silently stop loading at the buffer boundary
- MRU state can silently truncate if the file grows beyond what the parser
  expects
- future config/state growth will make this class of bug more likely, not less

## Suggested fix

1. Make oversize config behavior explicit instead of silently returning defaults.
2. Apply the same defensive full-buffer handling to MRU.
3. If the fixed-size design stays, fail in a way that preserves user trust:
   clear diagnostic, no silent reset, no silent truncation.

## Related older issue

This is a follow-on to [closed issue 01](closed/01-config-file-silent-truncation.md):
the original bug was fixed, but the boundary-sensitive pattern still survives in
the current loaders.
