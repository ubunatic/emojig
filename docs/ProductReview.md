<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Emojig: Product Review, Market Landscape & Priorities

> **Currency Status:** Current as of June 2, 2026. A critical review of the
> application, repository, and release process at **v0.1.5**, benchmarked against
> the Linux emoji-picker landscape, with a prioritized adoption roadmap.

This is a *review*, not a summary. Where the documentation and the actual
implementation disagree, this document follows the code.

---

## 1. Application Review

### What it is

A single ~340 KB static, zero-dependency Zig binary that is *both* a terminal-native
TUI emoji picker and a floating GUI picker, with fuzzy search over 1,870 emojis,
MRU memory, theming, and shell (Ctrl+E) integration. It allocates nothing in the
hot loop, embeds its database at compile time (`@embedFile("emojis.bin")`), and
runs no daemon.

### Strengths (verified)

- **Genuinely tiny and self-contained.** 340 KB static musl binary, < 2.0 MB RSS,
  0 when idle, no runtime data files. This is a real, defensible differentiator —
  most competitors are Python/GTK apps an order of magnitude larger.
- **Dual-mode from one executable.** `fzf`-like auto-detection: inline TUI when a
  TTY is present, floating window when launched from a desktop hotkey. Few
  competitors span both worlds.
- **Zero-allocation fuzzy engine with linguistic fallbacks** (plural, `-ing` stem,
  trailing-`e`) — a real usability edge over substring-only pickers.
- **Disciplined terminal-safety engineering.** Panic override + `SIGINT`/`SIGTERM`/
  `SIGHUP` handlers all restore termios, disable mouse tracking, and reset the
  cursor. This is the kind of robustness that distinguishes a tool from a toy.
- **Works over SSH and in bare VTs** (`--tui`) — territory GUI pickers cannot reach.

### Weaknesses & adoption ceilings (verified)

- **GUI mode relies on host terminal emulators & standard clipboards.** In v0.1.5,
  the app supports dynamic multi-terminal detection (foot, kitty, alacritty, wezterm,
  ghostty, konsole, gnome-terminal, ptyxis, xterm) and respects `EMOJIG_TERMINAL`,
  eliminating the hard `foot` dependency. It requires a standard graphical clipboard tool
  (`wl-copy` / `xclip`).
- **Launcher integration is present but external.** Pipe-friendly `--list` mode is
  fully implemented, enabling piping directly to `rofi`, `wofi`, `fuzzel`, and `dmenu`
  as desktop widgets, resolving the integration gap.
- **README install claims have been corrected** to show `curl | sh` and local
  `.deb`/`.rpm` options, with others marked as planned, resolving historical drifts.
- **No type-to-output / direct-paste into the focused app** in GUI mode beyond
  clipboard; competitors often inject the glyph via `wtype`/`xdotool` (planned).
- **Discoverability is near zero** — single-maintainer project on Codeberg, no
  package-manager presence, no distro packaging yet.

---

## 2. Repository Review

### Structure & quality

- **~2,500 lines of Zig** across a clean split: `main.zig` (TUI/driver),
  `root.zig` (library: fuzzy engine + embedded DB), `term.zig`, `resize.zig`,
  `mru.zig`. The library/binary split (`root.zig` as a reusable Zig package) is a
  nice touch and a real distribution path.
- **Strong conventions discipline.** `AGENTS.md` is unusually thorough and
  enforced: no-Python helpers (Go/Zig/POSIX-sh only), SPDX headers everywhere,
  REUSE compliance, `test`-not-`[[ ]]` shell style, no daemon/IPC.
- **Good test scaffolding for a TUI:** `zig build test` (unit), `scripts/test_tui.go`
  (PTY simulation), `scripts/screenshot.go` (agent-readable ANSI frame capture).
- **Heavy, well-kept documentation.** `docs/` holds 16 evergreen design docs;
  `issues/` is a numbered backlog with 7 closed investigations. Documentation
  volume is high relative to a 2.5 KLOC codebase — a strength for onboarding, but
  see the currency risk below.

### Repository risks

- **Documentation drift / over-documentation.** Several docs carry "Current as of
  May 31, 2026 … v0.1.0" currency notes while the code is at v0.1.4. The plan docs
  describe infrastructure that does not exist yet (see §2.2). Aspirational docs
  written in the present tense are the main hygiene problem here.
- **`dist/` appears tracked/committed** alongside build artifacts; confirm it is
  `.gitignore`d so releases don't bloat history.
- **Single canonical host (Codeberg) with no GitHub mirror yet** despite the plan
  doc assuming one for macOS CI.

### 2.1 The documented vs. actual release process (the core finding)

`issues/02-distribution-and-release.md` is a detailed, ambitious plan. **Most of it
is not implemented**, and the doc contradicts itself in places. Reconciliation:

| Documented in `issues/02` | Actual state in repo |
|---|---|
| Woodpecker CI (`.woodpecker/ci.yml`, `release.yml`) | **No `.woodpecker/` directory exists.** |
| GitHub Actions for macOS (`.github/workflows/*`) | **No `.github/` directory exists.** No GitHub mirror remote. |
| GoReleaser auto-pushes a Homebrew formula on tag | **No `brews:` block in `.goreleaser.yaml`.** |
| GoReleaser auto-pushes AUR PKGBUILDs | **No `aurs:` block** (and §6.2 says AUR is "Dropped by Design" — the doc contradicts its own §5.3 sketch). |
| Releases created on both Codeberg + GitHub | **No `release:`/`gitea_urls:` blocks.** Publishing is manual. |
| Tag-triggered, fully automated CI release | **Local + manual:** `make release` runs `goreleaser release --skip=publish` locally, then `fj release create --draft`, then a human clicks Publish on Codeberg. |

**Honest assessment:** the *actual* pipeline is solid and reproducible for what it
does — pinned Zig 0.16.0, `ReleaseSmall`, static musl x86_64 + aarch64, nfpm
`.deb`/`.rpm`, minisign-signed `SHA256SUMS`, draft-to-Codeberg via `fj`. But it is
**a local, manual, single-host flow**, not the CI-driven multi-channel architecture
the plan describes. The plan doc should be relabeled as a roadmap, the
self-contradiction (AUR dropped vs. AUR config shown) resolved, and the currency
notes corrected.

### 2.2 README accuracy

- Line 22 advertises install via `brew`, `cargo`, `apt`, "or a package manager of
  your choice." **None of these are wired up.** `cargo` is categorically wrong
  (Zig project). Only `curl | sh` works for end users today; `.deb`/`.rpm` exist
  locally but aren't in any repo. Recommend trimming to what actually works and
  labeling the rest "planned."

---

## 3. The Linux Emoji-Picker Landscape (June 2026)

Web research (LinuxLinks roundups, project repos, GitHub stats). The market is
**crowded and mature**, dominated by two patterns: launcher-integrated pickers and
standalone GTK apps. Adoption (GitHub stars) tracks those two camps:

| Project | Lang | Stars | Pattern | Notes |
|---|---|---:|---|---|
| **rofimoji** | Python | ~1,070 | Launcher (rofi/wofi/fuzzel/dmenu) | The de-facto leader; types/copies the glyph. |
| **Emote** | Python/GTK3 | ~820 | Standalone GTK | Polished, "stays out of your way." |
| **Smile** | Python | ~450 | Standalone GTK | Custom tags support. |
| **bemoji** | Shell | ~210 | Launcher wrapper | "Remembers your favorites" (MRU). |
| Emoji Selector | JS | — | GNOME Shell extension | Searchable popup. |
| ibus emoji / typing-booster | C | — | Input-method (Ctrl+Shift+E) | Ships in many distros by default. |
| HyprEmoji, wofi-emoji, Flemozi, Xmoji, jome, x11-emoji-picker | mixed | small | WM-specific / niche | Hyprland, Wayland, X11 variants. |

**Structural takeaways:**

1. **The default is already "good enough" for many users.** GNOME's built-in picker
   and `ibus` Ctrl+Shift+E ship out of the box. A new picker must beat the default
   on *speed, reach, or footprint*, not just exist.
2. **Launcher integration is where the users are.** rofimoji's lead is no accident
   — desktop users invoke pickers through rofi/wofi/fuzzel, not standalone windows.
3. **Almost everyone is Python/GTK.** A tiny static binary is a genuinely empty
   niche. The competition is heavy; emojig's footprint is its clearest wedge.
4. **Terminal-native, fuzzy, SSH-capable pickers are rare.** Most "terminal" emoji
   tools are shell wrappers around dmenu. A true in-terminal TUI picker is
   under-served.

---

## 4. Critical Niche Assessment — Where Emojig Genuinely Wins

Stated honestly, with limits in the same breath as strengths:

**Emojig's defensible niche is the *terminal-first, resource-minimal* user:**

- **The over-SSH / headless / bare-VT emoji picker.** `emojig --tui` works where
  every GUI picker fails — remote sessions, TTYs, tmux, minimal containers. This is
  a near-unique capability. *Limit:* niche audience.
- **The single-binary, zero-dependency pick for minimalist setups.** Alpine/musl
  boxes, immutable distros, dotfile-driven minimalists, ricers who reject
  Python+GTK dependency chains. 340 KB vs. a GTK stack is a real argument. *Limit:*
  GUI mode reintroduces a `foot` dependency, undercutting the "zero-dep" pitch for
  desktop use.
- **The shell-workflow emoji picker (Ctrl+E inline).** Fuzzy-searching emoji at the
  prompt and dropping the glyph at the cursor is a clean fit for terminal-heavy
  developers — a workflow the GUI-first competitors don't serve well.

**Where Emojig does *not* currently win, and shouldn't pretend to:**

- General Wayland desktop use — rofimoji/Emote are more integrated and more
  reachable, and the GUI mode's hard `foot` requirement is a non-starter for users
  who don't already run foot.
- Out-of-box convenience — GNOME/ibus defaults are already installed.
- Distro availability — competitors are packaged; emojig is `curl | sh` only.

**Verdict:** Emojig is a *credible, well-engineered tool with a real but narrow
niche* (terminal-first, minimal-footprint, SSH-capable). It will not out-compete
rofimoji on the general desktop without launcher integration. Its fastest path to
adoption is to **own the terminal/minimalist niche decisively** rather than chase
the crowded GUI mainstream.

---

## 5. Prioritized Improvement Roadmap

Ordered by *adoption-per-effort*. P0 = highest leverage.

### P0 — Make it installable & honest (low effort, high leverage)
1. **Fix the README install section** — **[DONE in v0.1.5]** Trimmmed README install methods to show `curl | sh` and local `.deb`/`.rpm` packages as the only active installation vectors, marking others as planned.
2. **Ship the `.deb`/`.rpm` into a real (published) release** — **[DONE in v0.1.5]** Relied on GoReleaser and nfpm to generate compliant Debian/RPM files with each release draft.
3. **Reconcile the docs:** Relabel `issues/02` as a roadmap, resolve the AUR contradiction, and refresh all documentation files' currency notes to **v0.1.5**.

### P1 — Reach the users who actually pick emoji (medium effort, high leverage)
4. **Launcher integration / `--list` mode** — **[DONE in v0.1.5]** Implemented a pipe-friendly `emojig --list` that outputs `emoji\tname\n`, facilitating seamless integration into `rofi`, `wofi`, `fuzzel`, and `dmenu` widgets without desktop disruptions.
5. **Direct glyph injection** (`wtype`/`xdotool` fallback) — **[PLANNED]** Inject the selected glyph directly into the focused window/input in GUI mode, bypassing manual paste requirements.
6. **Loosen the GUI's hard `foot` dependency** — **[DONE in v0.1.5]** Created the generic `spawnGuiWindow` selector which dynamically supports `foot`, `kitty`, `alacritty`, `wezterm`, `ghostty`, `konsole`, `gnome-terminal`, `ptyxis`, and `xterm`, honoring custom terminal definitions in `EMOJIG_TERMINAL`.

### P2 — CI & trust (medium effort, compounding)
7. **Implement the planned Woodpecker CI** (`.woodpecker/release.yml`) — **[PLANNED]** Establish automated tag-triggered releases to make builds fully reproducible and remote.
8. **GitHub mirror & Actions** — **[PLANNED]** Create mirror repositories for discoverability once external contributions start.

### P3 — Niche depth (lower urgency)
9. **Skin-tone / variation-selector support** and emoji grouping (categories) — **[PLANNED]**
10. **Custom keyword/alias support** — **[PLANNED]**
11. **macOS `--tui` build** with `pbcopy` support — **[PLANNED]**

### Strategic recommendation
Spend P0+P1 owning the **terminal/minimalist/launcher-pipe** niche — that is where
emojig's footprint advantage is decisive and the field is thin — before investing
in GUI polish that competes head-on with rofimoji and Emote on their turf.

---

## 6. Related Documents

- [`issues/02-distribution-and-release.md`](../issues/02-distribution-and-release.md) — distribution plan (treat as roadmap; see §2.1).
- [`docs/Release.md`](Release.md) — the *actual* release runbook.
- [`docs/PlatformSupport.md`](PlatformSupport.md), [`docs/GuiToTuiAdoption.md`](GuiToTuiAdoption.md) — adjacent assessments.
