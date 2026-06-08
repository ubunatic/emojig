<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [WebSandbox.md](file:///home/uwe/projects/emojig/docs/WebSandbox.md)
> - **Extra Content Covered Here:** Direct build commands for container2wasm and dependencies, custom target compilation details, and optimization options.
> - **Outdated Information:** None.

---


# WASM Browser Build Pipeline (container2wasm)

How `scripts/browser_demo.go` compiles the emojig container to WebAssembly so the
TUI runs fully client-side in a browser (the **W**ASM mode of the demo, alongside
the **D**ocker/ttyd live mode). This captures the hard-won learnings from getting
[container2wasm (c2w)](https://github.com/ktock/container2wasm) to work under
rootless podman. See also `issues/09-wasm-build-rootless-mknod.md`.

> TL;DR of the gotchas, in order of discovery:
> 1. Rootless podman **cannot `mknod`** (user namespace) → the c2w build must run **rootfully** (`sudo podman`).
> 2. The nested dockerd's cache only persists if it is allowed to **flush** before the container exits (`wait $DOCKER_PID`).
> 3. c2w's buildx export **replaces `/out`** → never bind-mount onto `/out`; mount a sibling and copy.
> 4. c2w **does not emit `index.html`** → you must supply the htdocs (loader page + JS) yourself.

---

## Architecture

```
browser_demo.go (host, rootless)
 ├─ podman build emojig-demo            (rootless — the app image; ttyd live mode uses it too)
 ├─ podman save emojig-demo -> tar      (rootless — export for the build container)
 └─ sudo podman run --privileged  emojig-c2w-builder            (ROOTFUL)
       │  (image: docker:dind + c2w, built by scripts/Dockerfile.c2w)
       └─ nested dockerd  (storage on the emojig-c2w-dind-cache volume)
             └─ c2w -> docker buildx build   (the actual container->wasm compile)
                   └─ Bochs/TinyEMU x86 emulator (WASI) + wasi-vfs pack of the guest rootfs
```

The emulator (Bochs for x86) is itself compiled to WASM; `wasi-vfs pack` embeds
the guest Linux kernel + the emojig rootfs **into** the `.wasm` so the page is
self-contained and needs no server at runtime.

---

## 1. Rootless podman cannot `mknod` → build rootfully

`findRuntime()` prefers `podman`, and on this host `docker` is itself **podman
emulating docker**. podman here is **rootless**, so every container runs in a
**user namespace**, where the kernel forbids creating device nodes:

```
$ podman run --rm --privileged alpine sh -c 'mknod /tmp/null c 1 3 && echo OK'
mknod: /tmp/null: Operation not permitted        # EPERM, even with --privileged
```

c2w's `rootfs-amd64-dev` stage does `mknod /rootfs/dev/null`, so the build dies
with `Operation not permitted`. **No config fixes this** — not `--privileged`,
not `CAP_MKNOD`, not buildkit `security.insecure`. The blocker is the user
namespace itself. The only escape is a root-owned kernel context:

```
$ sudo podman run --rm --privileged alpine sh -c 'mknod /tmp/null c 1 3 && echo OK'
MKNOD_OK                                          # rootful is NOT userns-remapped
```

### Implementation

- `sudoCtx` / `sudoBare` wrap `sudo <rt> …` (Stdin wired to the terminal so sudo
  can re-prompt). `primeSudo` runs `sudo -v` once up front so the multi-minute
  build doesn't pause to prompt.
- **Rootful:** builder-image build/inspect, stale-build stop, the privileged
  nested-dockerd `run`, the deferred stop. The builder image and cache volume
  therefore live in **root's** storage.
- **Rootless:** `podman save emojig-demo` — the app image is in the user's
  rootless storage; the rootful build only consumes the resulting tar.
- `chownToUser` restores ownership of `scripts/wasm-out/` afterward (root wrote it).
- sudo here has **no NOPASSWD**, so the demo prompts once per run (cached ~5 min).

---

## 2. Nested dockerd cache must be flushed before exit

The nested dockerd stores pulled base images and the buildkit layer cache in
`/var/lib/docker`, backed by the named volume **`emojig-c2w-dind-cache`** so runs
reuse it instead of re-pulling ubuntu/rust/golang and re-running every `apt-get`.

Two things are required for the cache to actually survive:

- **Graceful stop:** the in-container PID 1 is `sh`, which does not forward
  signals. A `trap … TERM INT` sends `SIGTERM` to dockerd and `wait`s, so
  `docker stop` (used everywhere instead of `rm -f`, with `-t 30`) lets dockerd
  flush rather than being SIGKILLed mid-write.
- **Wait on the success path too:** the normal-completion path must
  `kill -TERM $DOCKER_PID; wait $DOCKER_PID` **before** `exit`. Without the
  `wait`, PID 1 exits immediately, the container is torn down, dockerd is
  SIGKILLed before committing, and the **next run starts cold**. This was the
  bug behind "caching never persists." With the wait, the second run shows
  `CACHED` on the toolchain/base stages.

Stale build containers from an interrupted run are stopped at start
(`stopStaleBuilds`, filtered by `ancestor=emojig-c2w-builder`) — two daemons on
one `/var/lib/docker` volume would corrupt it.

> The tail stages (`bochs-dev-wizer`, `bochs-dev-packed`/`wasi-vfs pack`) fold in
> the emojig rootfs, so they correctly re-run every time the app changes — only
> the toolchain/base stages above them stay `CACHED`. That is expected, not a miss.

---

## 3. Never bind-mount onto `/out` (buildx export collision)

c2w runs buildx with `--output type=local,dest=…` and the export tree's
top-level entry is the output dir. The local exporter **replaces** that entry, so
if the host dir is bind-mounted exactly there it fails:

```
#120 exporting to client directory
#120 ERROR: failed to remove /out: unlinkat //out: device or resource busy
```

(You can't `unlink` a mountpoint.) **Fix:** mount the host output dir at a
**sibling** path (`/export`), let c2w write a real, non-mounted output dir, and
`cp -a <c2w-out>/. /export/` after a successful build. (This was masked for a
long time by the earlier `mknod` failure, which stopped the build before export.)

---

## 4. c2w does NOT produce `index.html` — you assemble the htdocs

c2w's output is a **wasm/JS module**, not a servable page. Our demo's outer page
(`wasmHtmlContent`) just iframes `/wasm-out/index.html`, so `scripts/wasm-out/`
must contain a loader page + supporting JS that we provide from c2w's
`examples/`.

> **Decision: WASI/Bochs path** (reuses the warm Bochs cache; committed loader
> JS, no webpack). The emscripten/QEMU path is faster in-browser but a heavier,
> different build — kept as a documented alternative below.

### Implemented assembly (WASI/Bochs)

1. **Invoke** `c2w emojig-demo /out/out.wasm` (no `--to-js`) → single WASI wasm.
2. **htdocs source:** `scripts/Dockerfile.c2w` copies `examples/wasi-browser/htdocs/`
   to `/opt/c2w-htdocs` in the builder image (instead of `rm -rf`-ing the clone).
3. **Assemble:** after a successful build, `cp -a /opt/c2w-htdocs/. /out/` puts
   index.html + loader JS beside `out.wasm`, then everything is copied to the
   host `scripts/wasm-out/`.
4. **Patch the image path:** the htdocs `index.html` hardcodes the wasm at server
   root (`location.origin + "/out.wasm"`); since the demo serves these from
   `/wasm-out/`, a `sed` repoints it to `/wasm-out/out.wasm`. The loader passes
   this via `postMessage` and `getImagename()` returns it, so the worker fetches
   the right URL.

### Cross-origin isolation is mandatory

The WASI-browser runtime uses `SharedArrayBuffer` + `Atomics.wait`, which the
browser only exposes in a **cross-origin-isolated** context. The Go file server
must send (via the `crossOriginIsolated` middleware — mirrors c2w's apache
`xterm-pty.conf`):

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without these, `SharedArrayBuffer` is undefined and the page fails to boot. (The
CDN `xterm`/`xterm-pty` scripts must satisfy COEP `require-corp`; jsDelivr serves
them with a compatible `Cross-Origin-Resource-Policy`, same as the upstream c2w
example.)

### `--to-js` argument contract (from c2w `cmd/c2w/main.go`)

`filepath.Split(output)` decides file-vs-dir:

- `c2w … /out`  → dir=`/`, file=`out` → exports the wasm as the **file** `/out`
  (and with `--to-js` this is actually rejected: *"output destination must be a
  slash-terminated directory path"*).
- `c2w … /out/` → dir=`/out`, file=`""` → adds `--target=js`, exports the htdocs
  **directory** `/out/`. **The trailing slash matters.**

### The two browser paths (both work without webpack)

| | **WASI / Bochs** (currently building) | **emscripten / QEMU** |
|---|---|---|
| Invoke | `c2w emojig-demo <htdocs>/out.wasm` (no `--to-js`) | `c2w --to-js emojig-demo <htdocs>/` (trailing slash) |
| c2w emits | `out.wasm` (single file) | `out.js` + `*.wasm` + `*.data` |
| htdocs to add | `examples/wasi-browser/htdocs/*` — `index.html`, `stack.js`, `stack-worker.js`, `worker.js`, `worker-util.js`, `wasi-util.js`, `ws-delegate.js`, `browser_wasi_shim/` (all committed JS, **no webpack**) | `examples/emscripten-simple/htdocs/index.html` + `examples/emscripten/xterm-pty.conf` |
| Runtime | interpreter, single-thread → **slower** | QEMU JIT (MTTCG), multicore → **faster** |
| Build weight | **light** — this is the warm Bochs/`wasi-vfs` cache | **heavy** — different QEMU-emscripten stages, cold cache |

> The full `examples/emscripten/` path *does* need webpack/xterm-pty bundling;
> `emscripten-simple` does not. The `wasi-browser` JS is committed as-is.

### Assembly target

Either way, the final `scripts/wasm-out/` must contain `index.html` (+ the
path's JS) and the generated wasm, so the demo's iframe (`/wasm-out/index.html`)
loads. The htdocs source files live in the c2w repo; they must be vendored into
this repo or copied out of the builder image (which currently `rm -rf`s its c2w
clone in `scripts/Dockerfile.c2w`).

---

## Operational notes

- **Filtered live log:** c2w's buildkit output is piped through `awk` that prints
  only the first line of each `#N` step plus `DONE`/`CACHED`/`ERROR` (with
  `fflush()` so it stays live). Full log is `tee`'d for the on-failure dump.
- **Progress watcher:** `watchOutDir` polls the mounted output dir and reports
  files as they appear/grow (recursive `WalkDir`).
- **Builder image** (`scripts/Dockerfile.c2w`): `docker:dind` + `go build` of
  c2w. NB: `go build` has **no `-q` flag** (that was a real bug → `flag provided
  but not defined: -q`).
- **Reset a corrupt/large cache:** `sudo podman volume rm emojig-c2w-dind-cache`.
  Old **rootless** leftovers from early attempts are harmless:
  `podman volume rm emojig-c2w-dind-cache` / `podman rmi emojig-c2w-builder`.
- **Output skip / cache gate:** `main` skips the whole WASM build when
  `scripts/wasm-out/index.html` already exists (prints "WASM already built").
  `rm -rf scripts/wasm-out` forces a rebuild while keeping the dind cache warm.
