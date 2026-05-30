# Emojig: Release Checklist & Approach

## Signing

**minisign** — one-line public key, no keyserver, native goreleaser support (same choice as ziglang).
- `minisign.pub` lives in the repo root (public, referenced in README)
- Private key is a CI secret only (`MINISIGN_SECRET_KEY`) — never committed

---

## The approach in one sentence

**GoReleaser** (`custom` builder calling `zig build`) drives the whole release:
cross-compile matrix → tarballs → SHA256SUMS → minisign → `.deb`/`.rpm`
→ Homebrew formula → AUR PKGBUILD → upload to both Codeberg and GitHub.
One `.goreleaser.yaml`. Woodpecker (Codeberg) and GitHub Actions both call it;
macOS targets run only on the GitHub macOS runner (Codeberg has no macOS runners).

---

## External steps before starting

### 1. Codeberg (canonical source)

- Create `codeberg.org/ubunatic/emojig` (empty, no auto-init)
- Push:
  ```sh
  git remote add origin https://codeberg.org/ubunatic/emojig.git
  git push -u origin main
  ```
- Enable the repo at `ci.codeberg.org` (Woodpecker — flip switch in Codeberg repo Settings)
- Create a Codeberg API token: **Settings → Applications → Generate Token**
  Scopes: `write:repository`. Save as CI secret `CODEBERG_TOKEN`

### 2. GitHub (mirror + macOS CI)

- Create `github.com/ubunatic/emojig` (empty, no auto-init)
- Set up push mirror from Codeberg:
  Codeberg repo → **Settings → Mirrors → Add Push Mirror**
  → `https://github.com/ubunatic/emojig.git` + a GitHub PAT with `repo` scope
  Every push to Codeberg auto-mirrors to GitHub
- Create a GitHub fine-grained PAT: **GitHub → Settings → Developer settings → Fine-grained tokens**
  Scope: `contents: write` on that repo. Save as CI secret `GITHUB_RELEASE_TOKEN`

### 3. Signing keypair

```sh
# install if needed: apt install minisign
minisign -G
# → prompts for password, writes minisign.pub and minisign.key
```

- Commit `minisign.pub` to repo root
- Add the secret key as CI secret `MINISIGN_SECRET_KEY` on **both** Codeberg/Woodpecker
  and GitHub Actions — do not commit it

### 4. Homebrew tap repo

- Create `codeberg.org/ubunatic/homebrew-tap`
  GoReleaser pushes formula updates here automatically
- The Codeberg token from step 1 covers this if it has org-wide write scope;
  otherwise create a separate token

### 5. AUR (can defer to P1 release, but register names now)

- Create account at `aur.archlinux.org` if you don't have one
- Register package names `emojig` and `emojig-bin` (submit a minimal stub PKGBUILD)
- Upload SSH public key to the AUR account
- Add matching private key as CI secret `AUR_SSH_KEY`

### 6. Phase 0 in-repo changes (code tasks, not external)

These are handled in the repo — listed here so nothing is forgotten:

- [ ] `LICENSE` — AGPL-3.0-or-later full text
- [ ] `README.md`
- [ ] `--version` / `-v` flag (injects `build.zig.zon` version at build time)
- [ ] Version bump `0.0.0` → `0.1.0` in `build.zig.zon`
- [ ] `minisign.pub` added to repo root
- [ ] `.goreleaser.yaml`
- [ ] `.woodpecker/ci.yml` and `.woodpecker/release.yml`
- [ ] `.github/workflows/ci.yml` and `.github/workflows/release.yml`

---

## Open question

**macOS builds depend on the TUI work** — macOS has no foot, so `x86_64-macos`
and `aarch64-macos` only make sense once `--tui` mode lands. Options:

- Hold macOS for `0.2.0` after TUI is done (simpler first release)
- Include macOS in `0.1.0` if TUI lands in time

Decision affects whether the GitHub macOS runner is needed in the initial pipeline.

---

## Decisions log

| # | Topic | Decision |
|---|-------|----------|
| 1 | Signing | **minisign** |
| 2 | Release engine | **goreleaser** with `custom` Zig builder |
| 3 | CI | **Woodpecker** (Codeberg) + **GitHub Actions** (mirror + macOS) |
| 4 | PyPI | **No** |
| 5 | `go install` shim | **Postponed** |
| 6 | Repo hosts | Codeberg (canonical) + GitHub (push mirror) |
| 7 | macOS | **Pending** — depends on TUI work landing |
