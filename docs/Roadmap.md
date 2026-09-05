---
title: Roadmap
weight: 20
---

<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Roadmap

Product-level sequencing of the open backlog (`issues/`), generated 2026-09-05
from 31 open tickets. This is a **planning view**, not a tracker: the tickets
remain the source of truth for scope and status, and `issues/README.md` remains
the canonical index. Nothing here changes a ticket's status.

---

## 1. What emojig actually optimizes for

Derived from `README.md` and `AGENTS.md`, not from a generic template. In
priority order, because the order is what resolves ties later:

1. **It never breaks your terminal.** The README badges "crash-safe terminal
   restore"; `AGENTS.md` spends a whole section (§2) plus three Quickstart
   imperatives on raw-mode, mouse-tracking and scrollback safety. A picker that
   leaves you typing blind into a dead shell has no second chance. This axis
   outranks every feature.
2. **Instant, accurate picking.** Zero-allocation fuzzy search over 2,249
   embedded emojis, multi-term AND, plural/stem fallbacks, spec-tuned ranking
   weights. The product is "type three letters, press Enter, done."
3. **It works where the user already is.** One binary that auto-detects TTY vs.
   desktop (§9), spawns any of nine host terminals from `spec/host.yaml`, and
   renders correctly on terminals that disagree with each other about how wide
   an emoji is. Reach here is compatibility breadth, not feature count.
4. **Trustworthy zero-friction install and update.** `curl | sh` into
   `~/.local/bin`, plus in-app `:update`. Both the install and the upgrade have
   to work *and* be verifiable, or the distribution story is a liability.
5. **Small and daemon-free.** ~900 KB static, <5 MB RSS, no socket, no service
   (§8). This is a constraint on every other axis, not a feature to grow.
6. **Spec-driven and agent-navigable.** `spec/*.yaml` *is* the code; behaviour
   values belong in YAML, not Zig. Because this codebase is developed largely by
   agents, "can the next agent find the right file" is a genuine product axis,
   not housekeeping.

Two axes are notably **not** on the list, and the backlog should stop drifting
toward them: pixel-level GUI ownership (§8 and the whole host-terminal design
argue against it) and feature surface for its own sake.

---

## 2. Themes in the open backlog

| Theme | Tickets | Axis |
|---|---|---|
| Distribution trust: install, update, verify | 026, 064, 002, 018, 019 | 4 |
| Terminal-safety invariants and their proof | 067, 012, 027, 016 | 1 |
| Cross-terminal rendering correctness | 050, 041, 054, 055, 057, 056 | 3 |
| Host reach and window placement | 025, 060, 065, 040 | 3 |
| Search quality and language reach | 011, 039 | 2 |
| Codebase and spec maintainability | 044, 046, 068 | 6 |
| Dev tooling, canaries, upstream | 051, 052, 058, 009 | supporting |
| New capabilities | 042, 049 | mixed |

---

## 3. Now

Rationale: everything in this bucket either **fails for a real user today** or
**must land before other queued work to avoid doing that work blind**. All five
are small-to-medium and touch two file clusters (`scripts/install.sh` +
`src/integration.zig`; `scripts/test_tui` + `src/term.zig`), so they sequence
cleanly without collision.

- **026 — install.sh and self-update skip artifact verification** (P1). The
  strongest live gap in the repo: the release plan promises `SHA256SUMS` +
  minisign, the installer does neither, and `:update` re-runs that same
  installer. Axis 4 is currently *documented but not enforced*, which is worse
  than an honest gap.
- **064 — `emojig update` fails when the binary is still open** (P2 / Major).
  User-reported on Arch/Omarchy: `cp` truncates a running executable in place.
  The fix (write-temp-then-`rename`) is in the same twenty lines of
  `install.sh` that 026 touches — do them as one change, not two.
- **067 — no automated regression proof for terminal restore** (P1, **new**,
  filed by this pass). Axis 1 is defended today by source audits and manual
  terminal checks only: `src/term.zig` has two byte-constant tests,
  `src/main.zig`/`tui.zig`/`pid_lock.zig` have none, and the PTY harness never
  sends a signal. This must land **before 044**, which explicitly proposes
  moving the terminal-restore trio into `src/term.zig`.
- **060 — `review_audit`'s xfce check reports a false PASS** (P2). A repro tool
  that stopped reproducing is worse than no tool: it actively argues that 025 is
  fixed. Tiny fix, and it is the verifier for the next item.
- **025 — GUI auto-mode misses `xfce4-terminal`** (P2). One missing entry in
  `spec/host.yaml`'s `detection:` list, plus a bidirectional spec-lint assertion
  so a template can never again exist without a detection entry. Pure axis-3
  reach for near-zero cost; do it immediately after 060 so the audit proves it.

## 4. Next

Rationale: high-value work that becomes **cheaper or verifiable** once Now
lands, plus the two in-progress refactors.

- **012 — TUI line cleanup and terminal restoration** (P1). Blocked on nothing,
  but most of its acceptance criteria are hand-checked today; after 067 the
  mechanical ones become assertions and 012 shrinks to the genuinely visual
  residue (scrollback history, prompt undisturbed). Note its 2026-08-11 audit:
  the DECSTBM/scroll-region theory is falsified — do not chase it.
- **027 — config and MRU 4 KB buffer edges** (P2). Silent wrong behaviour at a
  fixed boundary, in the state layer §8 mandates. Its `review_audit` check is
  one of the trustworthy ones, so it has a working repro already.
- **044 — `main.zig` decomposition** (P2, In Progress). 4,098 lines in one
  function is a direct axis-6 tax on every future ticket here. Land it *on top
  of* 067's gate.
- **046 — spec reorg and test-as-spec** (P2, In Progress). Partially shipped
  already (`spec/web/` exists, AGENTS.md documents the non-app tiers). Finish
  the merge/split candidates and the spec-lint expansion — 025's bidirectional
  assertion is the template for what "test-as-spec" should mean.
- **050 — background colour leaking in the GUI** (P2). Reopened specifically
  because it was closed without automated proof over a real rendered GUI. Pair
  it with **041** (prove GUI character-grid geometry) — 041 builds the measured
  proof harness that 050 needs to close honestly, so they are one effort.
- **016 — TUI flicker, part B** (P2). Part A (`skip_render`) shipped; removing
  the redundant pre-clear is a contained render-path change that 044's
  `renderPane` extraction makes safer.
- **020 — `wl-copy` shows as a desktop app** (P2). Visible, embarrassing, and
  well-diagnosed (debounce + lifecycle + strip the activation token). Squarely
  axis 1/3 polish on the multi-select path.
- **065 → 040 — window placement** (P3 → P2, in that order). 065 (centre on
  Hyprland via `hyprctl`, opt-in, silent fallback) is a narrow concrete slice of
  040's focus-adjacent placement goal. Ship 065 first as the cheap win and let
  it establish the compositor-adapter shape 040 then generalizes to sway.
- **011 — localized search ("pferd" → 🐎)** (P2). The single largest expansion
  of axis 2's reach: today search is English-only. Prefer Option 1 (spec-driven
  localized synonym maps, packed at build time) over CLDR ingestion — it keeps
  the zero-allocation query path and the "spec/ is the code" convention intact.

## 5. Later

Rationale: real but either speculative, unblocked-by-nothing-urgent, or
dependent on evidence that does not exist yet.

- **054, 055, 057 — the emoji-width family.** 054 (ZWJ correction beyond VTE)
  is explicitly theoretical — no confirmed non-VTE user report — and its own
  ticket warns that a blanket per-terminal switch risks *regressing* terminals
  that render correctly. 055 (cursor-query measurement) is the most future-proof
  and the heaviest, with no bug currently requiring it. 057's own history
  records that the user-facing symptom does not reproduce on a real desktop.
  Gate all three behind a real reproduction; 041's measurement harness is the
  natural place to find one.
- **056 — cache the foot colour-theme probe** (P3). The probe costs 5-7 ms. The
  design is already fully decided in the ticket; it is simply not worth a slot
  yet.
- **051, 052 — canary infrastructure** (P3). 051 works and is open only for
  extension; 052 is a headless-GTK4 tooling gap on a non-primary terminal.
- **039 — group-search test expansion** (P3). Eighty-plus semantic groups of
  ranking tests. Genuine axis-2 value, ideal opportunistic work whenever search
  is touched — not a scheduled block.
- **042 — `:report` command** (P3). Nice ergonomics, needs a new screen with two
  editable text fields; do it after 044 makes adding a screen cheap.
- **018 — `:update` RPM mode** (P3), and **002 — distribution plan** (P3). 002
  is a *plan document* living in the tracker; see §6.
- **068 — `explore_gtk_emoji.py`** (P3, **new**, filed by this pass). A tracked,
  Makefile-wired Python script in a repo whose §1 forbids Python by name, with
  an MIT header in an AGPL tree. Delete-or-relocate; five minutes whenever
  anyone is next in the Makefile.
- **009 — WASM build under rootless podman** (P1 in file, Later in practice).
  Correctly diagnosed as unfixable by configuration: rootless userns forbids
  `mknod`, full stop. It needs a rootful runtime or a build VM — an
  infrastructure decision, not a coding task, and it blocks only the browser
  demo.

---

## 6. Close, downgrade, or relocate candidates

Recommendations only — no status was changed by this pass.

- **049 — native GUI engine (foot/Ghostty)**: filed P1, but it proposes owning
  Wayland protocol handling, CSD, and FreeType/HarfBuzz glyph rasterization
  inside a 900 KB binary. Its two motivating pains — foot's CBDT font
  requirement and the absence of positioning flags — are already answered far
  more cheaply by `EMOJIG_TERMINAL` (documented in the README) and by 065/040.
  **Recommend: downgrade to P3 and mark Draft**, as an architecture study rather
  than queued work. Escalate only if host-terminal spawning is shown to fail a
  goal the other tickets cannot reach.
- **019 — `:update` Homebrew mode**: Blocked on two things nobody is funding — a
  live brew tap and macOS support (emojig's POSIX paths and musl-static build
  are Linux-only). **Recommend: close as won't-do-yet**, and let it be re-filed
  the day macOS support is a real goal.
- **058 — Zig `unsetenv()`/environ desync**: a genuine upstream Zig 0.16 defect,
  but it affects no shipped emojig code path — it was found in a developer-only
  canary flag that has since moved to the sibling `fontwidth` project. The only
  remaining action is filing it upstream on Codeberg. **Recommend: file
  upstream, then close with the link**; the diagnosis is already preserved in
  `docs/Zig.md` §8.
- **057 — tilix/headless VS16 row length**: its own history section records the
  P1 hypothesis being retracted after the user verified the real GUI window is
  correct. What remains is a canary-environment reliability question.
  **Recommend: close, folding the residue into 051.**
- **052 — ptyxis blank in headless capture**: dev-tooling only, on a terminal
  the ticket itself notes is not primary. **Recommend: close as won't-fix**
  unless the headless recorder grows GTK4 support for other reasons.
- **002 — distribution and release plan**: not a work item. It is a good
  aspirational design document that the tracker has been carrying for a year,
  and other tickets (026, 018, 019) already cite it as a spec. **Recommend:
  move the durable content to `docs/` as an evergreen release-plan doc and close
  the ticket**, keeping the executable remainder in 026/018.

### Tracker hygiene observed (not fixed by this pass)

- Five tickets read `Closed` in their own metadata block but still live in
  `issues/` rather than `issues/archive/`: **014, 015, 024, 038, 043**.
  `docs/IssueTracking.md` §4.2 says a verified-closed ticket moves to the
  archive. The index is internally consistent (`harnez status` reports all 66
  tickets ok), so this is tidiness, not drift.
- **There is no CI configuration in the repository** — no `.woodpecker`, no
  `.forgejo`, no `.github`. Every gate (`make preflight`, `zig build test`,
  `go test ./...`, `review_audit`, `harnez index --check`) is local-only and
  runs at whatever moment a human or agent chooses to run it. For a solo
  maintainer with strong local-gate discipline that is a defensible trade, and
  002 already notes CI as low-priority-until-contributors, so **no new ticket
  was filed**. It is worth revisiting the moment 026 lands: an unverified
  release pipeline and an unautomated verification step are the same risk twice.

---

## 7. Reading order for the next agent

Do not re-derive these; each has already cost someone a wrong turn:

- `docs/SearchEngine.md` before search, ranking, or emoji data (011, 039).
- `docs/SpecDrivenConfig.md` §13 before any theme/palette field (050).
- `docs/EnvironmentDetection.md` before any terminal or mode sniffing (025,
  040, 054, 065).
- `docs/Zig.md` before any subprocess, pipe, fd, or `dlopen` code (020, 026,
  064, 067).
- `docs/EmojiWidthResearch.md` before the width family (041, 054, 055, 057).
