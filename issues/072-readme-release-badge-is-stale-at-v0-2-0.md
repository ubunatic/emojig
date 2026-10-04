# 072 — README release badge is stale at v0.2.0

**Status**: Open
**Priority**: P2 (Medium)
**Severity**: Minor
**Category**: Bug
**Related**:

---

## 1. Problem & Motivation
The release badge in the project README still advertises v0.2.0. The repository
has a release bump commit for v0.2.2 dated 2026-09-14 (`68bac76`), and
`build.zig.zon` also declares version 0.2.2. Readers following the badge may
believe the published project is two patch releases behind.

## 2. Technical Specification / Findings
The stale value is in the README release badge label. Its target is the
Codeberg releases page, so the link remains useful; only the displayed version
is out of date. This review did not query the remote release endpoint.

## 3. Implementation & Verification Plan
Update the badge label to the current released version after confirming the
Codeberg release page. Consider including a small consistency check in release
preflight so the README label and package version do not drift again.
