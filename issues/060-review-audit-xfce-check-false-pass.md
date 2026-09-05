<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 060 — `review_audit`'s `xfce-host-detect` check reports a false PASS after the host spec migration

**Status**: Open
**Priority**: P2 (Medium) (a repro tool that silently stops reproducing is worse than
no tool — it actively argues an open bug is fixed)
**Severity**: Moderate
**Category**: Bug
**Related**: 025, 046

---

## Summary

`go run ./scripts/review_audit xfce-host-detect` prints **PASS**, which reads
as "the xfce4-terminal auto-detection gap is fixed". It is not fixed. The
check is a stale string-grep against `src/host.zig` that no longer matches
anything, so its detection conjunction collapses to `false` and the harness
interprets that as "bug not reproduced".

Found during the 2026-08-11 issue-tracker audit while cross-checking issue
[25](25-xfce4-terminal-autodetect-gap.md).

## Root cause

`scripts/review_audit/main.go`, `reproduceXfceHostDetect`:

```go
hasKind := strings.Contains(hostText, `if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;`)
hasArgvCase := strings.Contains(hostText, `.xfce4_terminal => {`)
autoDetectMissing := !strings.Contains(hostText, `"xfce4-terminal",`)
backlogClaimsSupport := strings.Contains(issue02Text, "xfce4-terminal")

return finding{
    name: "xfce-host-detect",
    hit:  hasKind && hasArgvCase && autoDetectMissing && backlogClaimsSupport,
    ...
}
```

All four terms are evaluated against `src/host.zig` (plus issue 02's text).
But host handling was migrated to spec-driven argv templates (issue
[46](46-spec-yaml-reorg-and-test-as-spec.md), `AGENTS.md §9`): there is no
longer a `hostKindFromName` string-compare chain and no
`.xfce4_terminal => {` argv switch branch in `src/host.zig` at all. Both
`hasKind` and `hasArgvCase` are therefore `false`, `hit` is `false`, and the
runner prints `PASS`.

The irony is that `autoDetectMissing` — the term describing the actual bug —
is still `true`, and would still be `true` if evaluated against the right
file. The check fails open on the two *supporting* facts, not on the defect.

## Evidence the underlying gap is still real

Confirmed by reading the spec directly (per `AGENTS.md`'s "read
`.uman.toml`/spec rather than probe" guidance):

- `spec/host.yaml` `terminals:` **has** a complete `xfce4-terminal` entry
  (`name: xfce4-terminal`, `tail_separator: "-x"`).
- `spec/host.yaml` `detection:` lists only `foot, ptyxis, kitty, alacritty,
  wezterm, ghostty, konsole, gnome-terminal, xterm` — no `xfce4-terminal`.
- `src/host.zig:107` (`for (getGlobalHostSpec().detection) |name|`) is the
  sole auto-detection loop, so a template absent from `detection` is
  unreachable by auto-mode.

## Why this is worth its own issue

Issue 25 can simply have its evidence corrected (done). This is a separate,
more general defect: `scripts/review_audit` exists specifically so backlog
claims stay falsifiable, and one of its three checks has silently inverted.
A future reader running `review_audit all` sees `PASS xfce-host-detect` and
has every reason to close issue 25 on that basis.

Note the other two checks were verified as still accurate on 2026-08-11:
`install-update-integrity` and `persistence-buffer-edges` both correctly
report **FAIL** and cite line references that still resolve (issues
[26](26-install-and-update-integrity-gap.md) and
[27](27-persistence-buffer-edges.md)). So this is an isolated staleness, not
a rotten harness.

## Suggested fix

1. Port `reproduceXfceHostDetect` to parse `spec/host.yaml` instead of
   grepping `src/host.zig`: assert that a `terminals:` entry named
   `xfce4-terminal` exists **and** that `detection:` omits it. That is the
   real invariant, and it is stated in data rather than in Zig syntax, so it
   will not rot the next time the host code is refactored.
2. Make staleness loud rather than silent. Every `strings.Contains` probe in
   this tool is a latent false-PASS: if a needle is absent for *any* reason,
   the check quietly succeeds. Either
   - distinguish "bug not present" from "check could not evaluate" in the
     `finding` type (e.g. an `inconclusive` state that exits non-zero with a
     distinct message), or
   - have each check assert its own anchors resolve first, and hard-fail the
     run if a file it depends on no longer contains them.
   Option 2 generalizes better and would have caught this on the first run
   after the migration.
3. Consider whether this belongs in `zig build test` instead. A Zig spec
   test can assert the detection/template relationship directly against the
   parsed `HostSpec` — `src/host.zig:903` already asserts the converse
   direction ("every detection entry has a template"), so adding the
   forward direction, with an explicit allowlist of
   intentionally-not-auto-detected terminals (`generic`, and today `tilix`
   — see issue [57](57-tilix-monochrome-mixed-row-length.md)), would make
   the invariant self-guarding and let the Go check retire entirely.

## Next steps

- [ ] Repoint or retire the `xfce-host-detect` check per option 1 or 3.
- [ ] Add inconclusive/anchor-verification handling per option 2, so the
      remaining checks cannot rot the same way.
- [ ] Re-run `go run ./scripts/review_audit all` and confirm
      `xfce-host-detect` reports **FAIL** again while issue 25 is open, then
      confirm it flips to PASS only once `detection:` actually gains the
      entry.

## Related

- Issue [25](25-xfce4-terminal-autodetect-gap.md) — the bug this check was
  built to keep honest; its evidence section was corrected in the same audit
  and now carries a warning about this false PASS.
- Issue [46](46-spec-yaml-reorg-and-test-as-spec.md) — the spec-migration
  work that moved the strings this check greps for; its "test-as-spec" theme
  is directly relevant to fix option 3.
- Issue [24](24-ux-and-resilience-review-2026-06.md) — the review that
  introduced `scripts/review_audit` alongside issues 25/26/27.
