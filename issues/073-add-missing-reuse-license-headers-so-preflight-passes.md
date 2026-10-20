# 073 — Add missing REUSE license headers so preflight passes

**Status**: Closed — Added REUSE annotations for all seven unlicensed files; make preflight passes with REUSE reporting 477/477 files covered.
**Priority**: P3 (Low)
**Severity**: Minor
**Category**: Chore
**Related**: commit `ff3051b` (ubunatic.com issue 081 follow-up)

---

## 1. Goal

/goal `make preflight` passes its REUSE step: every file has copyright and license info (SPDX header or `REUSE.toml` entry); or stop and report when a file's license needs a user decision.

Found 2026-10-20 while fixing a leak-scan finding in the emoji assets: emojig's preflight fails on existing REUSE metadata omissions (not caused by that fix).

## 2. Plan

1. Run `reuse lint` and list the files without info.
2. Add headers, or `REUSE.toml` annotations for generated/data files, matching the licenses the project already uses.
3. `make preflight` passes.
