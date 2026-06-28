---
status: open
priority: p3
---

# Emojig: Distribution & Release Plan

> [!NOTE]
> **Currency Status:** Roadmap, updated June 2, 2026 for **Emojig v0.1.5**. This is
> an *aspirational* plan. The **implemented** release flow (local GoReleaser build +
> manual `fj` draft to Codeberg) lives in [`docs/Release.md`](../docs/Release.md).
> **AUR and Nix are dropped. Homebrew is low priority.** Active channels: the
> `curl | sh` static installer (P0) and `.deb` / `.rpm` packages (P2).

How to ship `emojig` to many machines through many package managers, and how to
cut a clean release every time.

---

## 0. The Organizing Principle

> **One source of truth: Codeberg Releases carrying cross-compiled static
> binaries. Every package manager is a thin fetch-or-build shim over those.**

Do not maintain nine independent distribution stories. Maintain **one** — a
tagged release on Codeberg with a fixed set of attached artifacts — and make
each channel (Homebrew, AUR, Nix, `curl | sh`, `.deb`/`.rpm`) either
*download that artifact* or *build from that exact source tag*.

Two properties make this possible:

1. **Zig cross-compiles to static musl binaries.** A single
   `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall` produces a
   relocatable, dependency-free executable. The binary *is* the package.
2. **The emoji database is embedded** via `@embedFile("emojis.bin")`. No data
   files to ship, no post-install fetch. The binary is the whole product.

### Hosting topology

| Host | Role |
|------|------|
| `codeberg.org/ubunatic/emojig` | Canonical git repo + Releases (artifact source of truth) |
| `github.com/ubunatic/emojig` | Push mirror; GitHub Actions CI (macOS runners) — **low priority until there are external contributors** |
| `codeberg.org/ubunatic/homebrew-tap` | Homebrew formula repo (GoReleaser pushes here) |
| `ubunatic.com/emojig` | Vanity redirects + Go meta tags (low priority, see §4) |

---

## 1. Platform Reality

### Architecture

`emojig` ships as **one binary** with two modes:

- `--gui` (default) — launches and manages a terminal window using multi-terminal spawning
  (`spawnGuiWindow` in `src/host.zig`). Supports foot/kitty/alacritty/wezterm/ghostty/konsole/
  gnome-terminal/ptyxis/xfce4-terminal/xterm on both Wayland and X11.
- `--tui` — raw terminal UI, runs inside any existing terminal. Fallback when
  `--gui` is not viable (macOS, SSH, headless).

Additional runtime dep: `wl-copy` (Wayland) or `xclip` (X11) for clipboard.
`foot` itself is a runtime dep for `--gui` mode, not bundled.

### Target matrix

| Target | Mode | Status |
|--------|------|--------|
| `x86_64-linux-musl` | `--gui` + `--tui` | **P0** |
| `aarch64-linux-musl` | `--gui` + `--tui` | **P0** |
| `x86_64-macos` | `--tui` only | Pending macOS CI runner |
| `aarch64-macos` | `--tui` only | Pending macOS CI runner |
| Windows | — | Out of scope |

macOS builds require a macOS CI runner (GitHub Actions `macos-latest`).
Cross-compiling macOS targets from Linux is not viable without Apple's SDK.

### Channel priority

| Tier | Channels |
|------|----------|
| **P0** | Release tarballs + `SHA256SUMS`, `install.sh` (`curl \| sh` installer script) |
| **P2** | `.deb` / `.rpm` packages |
| **Low** | Homebrew tap (`brew`) — deferred; nice-to-have once binaries are in wide use |
| **AUR** | *Dropped / Closed by Design to avoid PKGBUILD maintenance overhead* |
| **Nix** | *Dropped / Closed by Design to focus resources on `install.sh` + deb/rpm* |
| **Go** | *Dropped / Closed by Design to avoid Go runtime/compilation wrapper overhead* |

---

## 2. Phase 0 — Repository Blockers

These must land before the first tag.

### 2.1 Code tasks (done in this repo)

- [x] License compliance via **`reuse`** (FSFE REUSE spec):
      `LICENSES/AGPL-3.0-or-later.txt`, `LICENSES/Unicode-DFS-2016.txt`,
      SPDX headers in all source files, `.reuse/dep5` for binary/data files.
      Add `reuse lint` to CI as a gate. Install: `pip install reuse`.
- [x] `README.md` — one-liner, screenshot/asciinema, install matrix, `--theme`/`EMOJIG_THEME`, runtime deps
- [x] Version bump `0.0.0` → `0.1.0` in `build.zig.zon`
- [x] `--version` / `-v` flag (injects version at build time via `build_options`)
- [x] `minisign.pub` in repo root
- [x] `.goreleaser.yaml`
- [ ] `.woodpecker/ci.yml` and `.woodpecker/release.yml`
- [ ] `.github/workflows/ci.yml` and `.github/workflows/release.yml`

### 2.2 External steps (human, one-time)

**Codeberg (canonical source)**
- Create `codeberg.org/ubunatic/emojig` (empty, no auto-init)
- `git remote add origin https://codeberg.org/ubunatic/emojig.git && git push -u origin main`
- Enable repo at `ci.codeberg.org` (Woodpecker — flip switch in repo Settings)
- Create API token: **Settings → Applications → Generate Token**, scope `write:repository`
  → CI secret `CODEBERG_TOKEN`

**GitHub (mirror + macOS CI)**
- Create `github.com/ubunatic/emojig` (empty, no auto-init)
- Set up push mirror from Codeberg: repo → **Settings → Mirrors → Add Push Mirror**
  → `https://github.com/ubunatic/emojig.git` + GitHub PAT with `repo` scope
- Create fine-grained PAT: **GitHub → Settings → Developer settings → Fine-grained tokens**,
  scope `contents: write` → CI secret `GITHUB_RELEASE_TOKEN`

**Signing keypair (minisign)**
```sh
minisign -G   # prompts for password; writes minisign.pub + minisign.key
```
- Commit `minisign.pub` to repo root
- Add secret key as CI secret `MINISIGN_SECRET_KEY` on both Woodpecker and GitHub — never commit it

**Homebrew tap repo**
- Create `codeberg.org/ubunatic/homebrew-tap` (GoReleaser pushes formula updates here)

**AUR (Dropped / Closed by Design)**
- Registration and packaging for AUR are skipped to focus on Homebrew (`brew`) and direct `curl | sh` installers.

---

## 3. The Release Process

### 3.1 Definition of a clean release

1. **Tag-driven & SemVer.** Only from an annotated tag `vMAJOR.MINOR.PATCH` on `main`. Tag version equals `build.zig.zon`.
2. **Reproducible.** Pinned Zig version (`0.16.0`), `ReleaseSmall`, static musl targets.
3. **Self-describing.** `CHANGELOG.md` entry per release.
4. **Verifiable.** Every artifact has a line in `SHA256SUMS`; `SHA256SUMS` is signed with minisign.
5. **Immutable.** Never re-upload under the same tag. A mistake means a new patch tag.

### 3.2 Release artifacts

```
emojig-vX.Y.Z-x86_64-linux-musl.tar.gz
emojig-vX.Y.Z-aarch64-linux-musl.tar.gz
emojig-vX.Y.Z-x86_64-macos.tar.gz          ← when TUI lands
emojig-vX.Y.Z-aarch64-macos.tar.gz         ← when TUI lands
emojig-vX.Y.Z-x86_64-linux.deb
emojig-vX.Y.Z-aarch64-linux.deb
emojig-vX.Y.Z-x86_64-linux.rpm
SHA256SUMS
SHA256SUMS.minisig
```

Each tarball: `emojig` binary + `LICENSE` + `README.md`. GoReleaser assembles all of this.

### 3.3 Versioning policy

- `0.x` while CLI flags / modes may still change. Bump **minor** for features, **patch** for fixes.
- Promote to `1.0.0` once `--gui`/`--tui` flags, `EMOJIG_THEME`, and exit/clipboard behavior are stable.
- The embedded DB format (`emojis.bin`) is internal; it does not affect the public version contract.

### 3.4 Cut-a-release runbook

```sh
# 1. Land all features on main, green CI.
# 2. Bump version in build.zig.zon, add CHANGELOG.md entry, commit.
git commit -am "Release v0.1.0"
# 3. Annotated tag — GoReleaser reads this.
git tag -a v0.1.0 -m "emojig v0.1.0"
git push origin main v0.1.0
# CI detects the tag, runs goreleaser, creates the Codeberg + GitHub release.
```

### 3.5 Downstream propagation

GoReleaser handles automatically on each tag push:
- `.deb` / `.rpm` via built-in nfpm

Deferred / dropped:
- Homebrew tap formula — **low priority**, not yet wired into `.goreleaser.yaml`
- AUR PKGBUILDs — **dropped**
- Nix flake — **dropped**

Manual per release:
- [ ] Verify `curl | sh` installer resolves "latest" correctly

---

## 4. The `ubunatic.com/emojig` Vanity Layer

Low priority. A small static page (Codeberg Pages or any static host) serving:

**Go vanity meta tags** (makes `go get` work for source browsing):
```html
<meta name="go-import"
      content="ubunatic.com/emojig git https://codeberg.org/ubunatic/emojig">
```

**HTTP redirects:**
- `ubunatic.com/emojig` → Codeberg repo
- `ubunatic.com/emojig/install.sh` → raw `install.sh` in repo
- `ubunatic.com/emojig/releases` → Codeberg Releases page

`go install ubunatic.com/emojig@latest` as a functional installer is **postponed** —
the Go toolchain cannot compile Zig. A shim can be added later if there is demand.

---

## 5. CI: Woodpecker + GitHub Actions via GoReleaser

**GoReleaser** is the release engine for both CI hosts. It handles: cross-compilation
(via `custom` builder running `zig build`), archive assembly, SHA256SUMS, minisign
signing, `.deb`/`.rpm` (nfpm built-in), Homebrew formula push, AUR PKGBUILD push,
and release creation on both Codeberg and GitHub. One `.goreleaser.yaml` config.

### 5.1 Woodpecker (Codeberg) — Linux targets

`.woodpecker/ci.yml` — runs on push and PR:
```yaml
when:
  event: [push, pull_request]
steps:
  - name: test
    image: alpine  # + zig setup step
    commands:
      - zig build test
      - zig build
      - go run scripts/test_tui.go
      - zig fmt --check src/
```

`.woodpecker/release.yml` — runs on `v*` tags:
```yaml
when:
  event: tag
  ref: refs/tags/v*
steps:
  - name: release
    image: goreleaser/goreleaser  # + zig setup step
    environment:
      CODEBERG_TOKEN:     { from_secret: CODEBERG_TOKEN }
      GITHUB_TOKEN:       { from_secret: GITHUB_RELEASE_TOKEN }
      MINISIGN_SECRET_KEY: { from_secret: MINISIGN_SECRET_KEY }
      AUR_SSH_KEY:        { from_secret: AUR_SSH_KEY }
    commands:
      - goreleaser release --clean
```

Woodpecker builds Linux targets only (`x86_64-linux-musl`, `aarch64-linux-musl`).
Cross-compilation via Zig — no macOS runner needed here.

### 5.2 GitHub Actions — macOS targets (when TUI lands)

> **Low priority until there are external contributors.** The GitHub mirror and its
> Actions (macOS runners) are deferred; Codeberg + Woodpecker cover Linux releases today.

`.github/workflows/release.yml` — runs on `v*` tags:
```yaml
jobs:
  release-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with: { version: "0.16.0" }
      - name: GoReleaser (macOS targets only)
        uses: goreleaser/goreleaser-action@v6
        with:
          args: release --clean --config .goreleaser.macos.yaml
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          MINISIGN_SECRET_KEY: ${{ secrets.MINISIGN_SECRET_KEY }}
```

### 5.3 GoReleaser config sketch

`.goreleaser.yaml` (Linux, driven by Woodpecker):
```yaml
builds:
  - id: emojig-linux
    builder: custom
    targets:
      - linux_amd64
      - linux_arm64
    build_details:
      env: []
    hooks:
      pre:
        - cmd: sh -c 'zig build -Doptimize=ReleaseSmall -Dtarget={{ if eq .Arch "amd64" }}x86_64{{ else }}aarch64{{ end }}-linux-musl'
      post:
        - cmd: cp zig-out/bin/emojig dist/emojig

archives:
  - format: tar.gz
    name_template: "emojig-{{ .Version }}-{{ .Os }}-{{ .Arch }}"

checksum:
  name_template: SHA256SUMS
  algorithm: sha256

signs:
  - cmd: minisign
    args: ["-S", "-s", "{{ .Env.MINISIGN_SECRET_KEY }}", "-m", "${artifact}"]
    artifacts: checksum

nfpms:
  - package_name: emojig
    formats: [deb, rpm]
    recommends: [wl-clipboard]
    suggests: [xclip, foot]
    license: AGPL-3.0-or-later

# brews: LOW PRIORITY — deferred, intentionally NOT in the current .goreleaser.yaml.
#   Build-from-source formula pushed to codeberg.org/ubunatic/homebrew-tap.
#   Wire this up only once the static binaries see real-world use.
#
# aurs: DROPPED by design — no PKGBUILD maintenance overhead.
# nix:  DROPPED by design.

gitea_urls:
  api: https://codeberg.org/api/v1/
  download: https://codeberg.org
  skip_tls_verify: false

release:
  gitea:
    owner: ubunatic
    name: emojig
  github:
    owner: ubunatic
    name: emojig
  draft: false
  prerelease: auto

changelog:
  sort: asc
  filters:
    exclude: ["^docs:", "^test:", "^chore:"]
```

---

## 6. Channel-by-Channel Specs

### 6.1 `curl | sh` installer (P0)

`install.sh` in-repo (POSIX `sh`, no bash-isms):

1. Detect `uname -s`/`-m` → map to release asset; refuse non-Linux with a clear message (until macOS TUI ships)
2. Resolve "latest" via the Codeberg Releases API (or accept `EMOJIG_VERSION` env)
3. Download tarball + `SHA256SUMS`, verify hash, extract `emojig`
4. Install to `~/.local/bin` (default) or `$PREFIX/bin`; print PATH hint
5. Warn if `wl-clipboard`/`xclip` is missing

Served at `ubunatic.com/emojig/install.sh` once the vanity domain is set up.

### 6.2 AUR — (Closed / Dropped by Design)

AUR packaging (`emojig` / `emojig-bin`) has been dropped to avoid PKGBUILD maintenance overhead, shifting focus fully to Homebrew (`brew`) and the direct `curl | sh` static installer.

### 6.3 Nix flake (Closed / Dropped by Design)

Nix flake packaging has been dropped to focus development and release resources entirely on the Homebrew (`brew`) and `install.sh` distribution paths.

### 6.4 `.deb` / `.rpm` (P2)

Produced automatically by GoReleaser via built-in nfpm. No separate `nfpm.yaml` needed.
`Recommends: wl-clipboard`; `Suggests: xclip, foot`. Attached to the Release.

### 6.5 Homebrew tap (Low priority — deferred)

`codeberg.org/ubunatic/homebrew-tap`. Would have GoReleaser push an updated formula on
each release (build-from-source using `zig`, `depends_on :linux`). **Not yet wired into
`.goreleaser.yaml`** — deferred until the static binaries see real-world use.

### 6.6 Zig package consumers (native, bonus)

Other Zig projects can depend on the **library** (`src/root.zig` — fuzzy engine + embedded DB):

```sh
zig fetch --save https://codeberg.org/ubunatic/emojig/archive/v0.1.0.tar.gz
```

Keep `root.zig`'s public API documented. This is the most idiomatic distribution path
for the reusable parts.

---

## 7. Phased Rollout

| Phase | Deliverable | Channels live |
|-------|-------------|---------------|
| **0** | LICENSE, README, Codeberg push, GitHub mirror, keypair, version 0.1.0, `--version`, goreleaser config, CI files | — |
| **1** | First tagged Release via goreleaser | Release tarballs, `SHA256SUMS`, `zig fetch`, `.deb`/`.rpm` |
| **2** | `install.sh`, vanity domain Go meta tags | `curl \| sh` |
| **3** | *(dropped — no longer planned)* | — |
| **4** | Homebrew tap (low priority, only if demand) | `brew install` |
| **5** | macOS builds (after `--tui` lands) | macOS `curl \| sh` |
| **6** | `go install` shim if demand exists | `go install` |

---

## 8. Decisions

| # | Topic | Decision |
|---|-------|----------|
| 1 | License | **AGPL-3.0-or-later** |
| 2 | CI | **Woodpecker** (Codeberg, Linux) + **GitHub Actions** (macOS) |
| 3 | Release engine | **GoReleaser** with `custom` Zig builder |
| 4 | Signing | **minisign** — `minisign.pub` in repo root; key as CI secret |
| 5 | Repo hosts | **Codeberg** (canonical) + **GitHub** (push mirror) |
| 6 | PyPI | **No** |
| 7 | `go install` shim | **Postponed** — vanity meta tags only for now |
| 8 | macOS targets | **Pending TUI work** — `0.2.0` at earliest |
| 9 | foot bundling | **System foot** (runtime dep, not bundled) — inherit foot bug fixes |
| 10 | Binary modes | **`--gui`** (foot, default) + **`--tui`** (any terminal, in progress) |
