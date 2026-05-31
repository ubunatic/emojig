# Release Runbook

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the release process, dependencies, and runbook for **Emojig v0.1.0**.

## Prerequisites

Install once per machine:

```sh
make deps   # installs foot, minisign, reuse (apt) and goreleaser, fj (go install)
```

You also need:
- `zig` 0.16.0 on `PATH`
- Codeberg credentials stored once: `fj auth login`
- `minisign.pub` / `minisign.key` keypair generated once:
  ```sh
  minisign -G   # writes minisign.pub + minisign.key, prompts for password
  ```
  Commit `minisign.pub`. Never commit `minisign.key`.

---

## Local snapshot build (no tag, no publish)

```sh
make release
```

Produces `dist/` with tarballs, `.deb`, `.rpm`, and `SHA256SUMS`. Signing is
skipped because `--snapshot` builds are not real releases.

---

## Cutting a real release

### 1. Pre-flight checks

```sh
reuse lint          # licence headers clean
zig build test      # tests pass
zig fmt --check src/
```

### 2. Bump version and write changelog

Edit `build.zig.zon`:
```
.version = "0.X.Y",
```

Add an entry to `CHANGELOG.md` (create it if it doesn't exist yet).

Commit:
```sh
git commit -am "release: v0.X.Y"
```

### 3. Tag and push

```sh
git tag -a v0.X.Y -m "emojig v0.X.Y"
git push origin main v0.X.Y
```

The tag must exist on Codeberg before `fj` can create a release against it.

### 4. Build artifacts

```sh
export MINISIGN_KEY_FILE=~/.minisign/minisign.key
goreleaser release --clean --skip=publish
```

GoReleaser will:
- Cross-compile `x86_64-linux-musl` and `aarch64-linux-musl` via `zig build`
- Assemble tarballs (`emojig-vX.Y.Z-<target>.tar.gz`) with `LICENSES/` and `README.md`
- Build `.deb` and `.rpm` packages
- Generate `SHA256SUMS`
- Sign `SHA256SUMS` with minisign → `SHA256SUMS.minisig`

### 5. Create draft release

```sh
VERSION=0.X.Y
fj release create "emojig v${VERSION}" \
  --tag "v${VERSION}" \
  --draft \
  $(printf -- '--attach %s ' dist/*.tar.gz dist/*.deb dist/*.rpm dist/SHA256SUMS dist/SHA256SUMS.minisig)
```

`fj` uses credentials from `fj auth login` (run once after installing). It detects
the repo from the git remote automatically.

### 6. Review and publish the draft

Open the Codeberg release, verify the artifact list and changelog, then click
**Publish**.

---

## Quick release runbook

```sh
# 1. pre-flight checks
make preflight

# 2. bump version in build.zig.zon, update CHANGELOG.md, then commit
git commit -am "release: v0.X.Y"

# 3. tag and push
git tag -a v0.X.Y -m "emojig v0.X.Y"
git push origin main v0.X.Y

# 4. build, sign, and create draft release
make release-fj

# 5. open Codeberg, review the draft, and click Publish
```

---

## Release artifacts

| File | Description |
|------|-------------|
| `emojig-vX.Y.Z-x86_64-linux-musl.tar.gz` | Static binary + licenses (x86-64) |
| `emojig-vX.Y.Z-aarch64-linux-musl.tar.gz` | Static binary + licenses (arm64) |
| `emojig_vX.Y.Z_linux_amd64.deb` | Debian/Ubuntu package |
| `emojig_vX.Y.Z_linux_arm64.deb` | Debian/Ubuntu package (arm64) |
| `emojig_vX.Y.Z_linux_amd64.rpm` | RPM package |
| `emojig_vX.Y.Z_linux_arm64.rpm` | RPM package (arm64) |
| `SHA256SUMS` | Checksums for all artifacts |
| `SHA256SUMS.minisig` | minisign signature over `SHA256SUMS` |

Verify a download:
```sh
minisign -V -p minisign.pub -m SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

---

## Versioning policy

- `0.x` while CLI flags / config format may still change
- Bump **minor** for new features, **patch** for bug fixes
- Promote to `1.0.0` once `--gui`/`--tui`, `EMOJIG_THEME`, and clipboard
  behaviour are stable
- Never re-upload under the same tag — mistakes get a new patch tag
