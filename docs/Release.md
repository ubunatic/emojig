# Release Runbook

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Matches the release process, dependencies, and runbook for **Emojig v0.1.5**.

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
make release-snapshot
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

Run one of the automated version bump Makefile targets to update `build.zig.zon` with the correct Semantic Versioning increment:
```sh
make bump-patch     # e.g., 0.1.1 -> 0.1.2
make bump-minor     # e.g., 0.1.1 -> 0.2.0
make bump-major     # e.g., 0.1.1 -> 1.0.0
```

Add an entry to `CHANGELOG.md` detailing the changes (create the file if it does not exist yet).

### 3. Commit and tag

Instead of manually typing version numbers in Git commands, run the automated `tag` target. It extracts the version from `build.zig.zon`, commits the version and changelog modifications, and tags the commit:
```sh
make tag
```

Now push the commit and the tag to Codeberg:
```sh
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

Instead of running steps manually, you can execute the entire release pipeline using a single interactive command:

```sh
# 1. Bump the version (e.g., patch, minor, major)
make bump-patch

# 2. Add release notes detailing your changes to CHANGELOG.md

# 3. Run the fully interactive automated release pipeline
make release
```

The pipeline will run preflight verification tests, show you the target version, prompt for confirmation, and automatically handle all commit, tag, push, build, minisign, and Codeberg draft creation tasks.


---

## Release artifacts

| File | Description |
|------|-------------|
| `emojig-vX.Y.Z-x86_64-linux-musl.tar.gz` | Static binary + licenses (x86-64) |
| `emojig-vX.Y.Z-aarch64-linux-musl.tar.gz` | Static binary + licenses (aarch64) |
| `emojig_vX.Y.Z_linux_amd64.deb` | Debian/Ubuntu package |
| `emojig_vX.Y.Z_linux_aarch64.deb` | Debian/Ubuntu package (aarch64) |
| `emojig_vX.Y.Z_linux_amd64.rpm` | RPM package |
| `emojig_vX.Y.Z_linux_aarch64.rpm` | RPM package (aarch64) |
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
