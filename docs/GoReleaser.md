# GoReleaser Notes

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the active GoReleaser pipeline and compilation flags for **Emojig v0.1.0**.

## What we use it for

GoReleaser drives the release pipeline: cross-compiles via `zig build`,
assembles tarballs, builds `.deb`/`.rpm` via nfpm, generates `SHA256SUMS`,
signs with minisign, and creates the Codeberg draft release.

See `.goreleaser.yaml` and `docs/Release.md` for the runbook.

---

## Lessons learned

### Free vs Pro — watch the creep

GoReleaser is nominally open-source but a growing set of builders are
**Pro-only**. We hit this directly:

| Feature | Tier |
|---------|------|
| `builder: go` | Free |
| `builder: rust` | Free |
| `builder: zig` | Free (experimental) |
| `builder: custom` | **Pro** |
| `builder: prebuilt` | **Pro** |
| `builder: deno`, `bun` | **Pro** |

`custom` and `prebuilt` are the two most useful builders for non-Go projects.
Their absence from the free tier is a real constraint. The `zig` builder works
for us today but is marked experimental — if it moves to Pro, we switch to the
shell-script alternative (see below).

### Zig builder specifics

- Use `targets` (Zig-style triples), **not** `goos`/`goarch`:
  ```yaml
  targets:
    - x86_64-linux-musl
    - aarch64-linux-musl
  ```
- Pass build flags via `flags`:
  ```yaml
  flags:
    - -Doptimize=ReleaseSmall
    - -Dversion={{ .Version }}
  ```
- `{{ .Version }}` is the tag without the `v` prefix (e.g. `0.1.0`).

### Injecting version into the Zig binary

In `build.zig`:
```zig
const version = b.option([]const u8, "version", "...") orelse "dev";
const options = b.addOptions();
options.addOption([]const u8, "version", version);
exe.root_module.addOptions("build_options", options);
```

In `src/main.zig`:
```zig
const build_options = @import("build_options");
// then: build_options.version
```

Build locally with: `zig build -Dversion=0.1.0`

### minisign signing

`minisign -s` takes a **key file path**, not key content. In CI, write the
secret to a file before calling goreleaser:

```sh
printf '%s' "${MINISIGN_SECRET_KEY}" > /tmp/minisign.key
export MINISIGN_KEY_FILE=/tmp/minisign.key
goreleaser release --clean
```

The `.goreleaser.yaml` `signs` block reads `$MINISIGN_KEY_FILE`.
Skip signing for local snapshot builds: `--skip=sign`.

### Local snapshot

`goreleaser release --snapshot --clean --skip=sign` — builds all artifacts
locally into `dist/`, no tag or token required.

---

## OSS alternative (no GoReleaser)

If GoReleaser's Pro-only creep becomes a problem, the same pipeline is
straightforward to replicate with standard tools:

```
zig build  →  nfpm    →  sha256sum  →  minisign  →  fj release create
(binaries)    (deb/rpm)  (SHA256SUMS)  (.sig)        (Codeberg draft)
```

### Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `nfpm` | Build `.deb` / `.rpm` from a yaml spec | `go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest` |
| `sha256sum` | Generate checksums | coreutils |
| `minisign` | Sign the checksum file | `sudo apt install minisign` |
| `fj` | Create Codeberg release, upload assets | https://codeberg.org/forgejo-contrib/forgejo-cli |

`nfpm` is by the same author as GoReleaser, independently MIT-licensed, no Pro tier.
`fj` is the official Forgejo/Codeberg CLI — no vendor lock-in, no paid tier.

### Release script sketch

```sh
VERSION=0.1.0
mkdir -p dist

# build — one prefix per target to avoid overwriting during parallel builds
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl  -Dversion=$VERSION --prefix dist/build-amd64
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-musl -Dversion=$VERSION --prefix dist/build-aarch64

# tarballs
tar -czf dist/emojig-$VERSION-x86_64-linux-musl.tar.gz  -C dist/build-amd64/bin emojig
tar -czf dist/emojig-$VERSION-aarch64-linux-musl.tar.gz -C dist/build-aarch64/bin emojig

# deb / rpm
nfpm package -f nfpm.yaml -p deb --target dist/
nfpm package -f nfpm.yaml -p rpm --target dist/

# checksum + sign
sha256sum dist/*.tar.gz dist/*.deb dist/*.rpm > dist/SHA256SUMS
minisign -S -s "$MINISIGN_KEY_FILE" -m dist/SHA256SUMS

# create draft release and upload all artifacts in one call
fj release create "emojig v$VERSION" \
  --tag "v$VERSION" \
  --draft \
  $(for f in dist/*.tar.gz dist/*.deb dist/*.rpm dist/SHA256SUMS dist/SHA256SUMS.minisig; do
      printf ' --attach %s' "$f"
    done)
```

An `nfpm.yaml` for this project is a near-copy of the `nfpms:` block in
`.goreleaser.yaml`.

### Woodpecker pipeline sketch

```yaml
when:
  event: tag
  ref: refs/tags/v*

steps:
  - name: release
    image: alpine
    environment:
      MINISIGN_SECRET_KEY:
        from_secret: MINISIGN_SECRET_KEY
      FJ_TOKEN:
        from_secret: CODEBERG_TOKEN
    commands:
      - apk add --no-cache curl xz go git
      - curl -fsSL https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz | tar -xJ -C /usr/local
      - ln -sf /usr/local/zig-linux-x86_64-0.16.0/zig /usr/local/bin/zig
      - go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
      - go install codeberg.org/forgejo-contrib/forgejo-cli@latest
      - printf '%s' "$MINISIGN_SECRET_KEY" > /tmp/minisign.key
      - export MINISIGN_KEY_FILE=/tmp/minisign.key
      - export VERSION=${CI_COMMIT_TAG#v}
      - sh scripts/release.sh   # the sketch above, extracted to a script
```

Secrets needed: `MINISIGN_SECRET_KEY`, `CODEBERG_TOKEN` (with `write:repository` scope).

`fj` reads `FJ_TOKEN` for auth and detects the repo from the git remote automatically.
