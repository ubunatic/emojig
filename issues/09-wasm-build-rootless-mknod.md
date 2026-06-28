---
title: "WASM build fails under rootless podman: mknod blocked in user namespace"
status: in-progress
priority: p1
---

# Issue 09 — WASM (c2w) build fails under rootless podman: `mknod` blocked in user namespace

**Status:** 🟠 In progress — fix implemented (rootful podman), pending end-to-end verification
**Component:** `scripts/browser_demo.go` (c2w → container2wasm build path), `scripts/Dockerfile.c2w`

---

## Symptom

The c2w WASM compile fails partway through, in container2wasm's own `rootfs-amd64-dev` stage:

```
> [rootfs-amd64-dev 9/10] RUN mkdir -p /rootfs/... && mknod /rootfs/dev/null c 1 3 && chmod 666 /rootfs/dev/null:
1.365 mknod: /rootfs/dev/null: Operation not permitted
------
ERROR: failed to solve: process "/bin/sh -c ... mknod /rootfs/dev/null c 1 3 ..." did not complete successfully: exit code: 1
⚠️  WASM compilation failed: exit status 1
```

`Operation not permitted` is **EPERM** (a capability/namespace denial), not `EOPNOTSUPP` (a filesystem limitation).

## Root cause

This host runs **rootless podman**, and `findRuntime()` prefers `podman`. Note also that the
`docker` CLI here is **podman emulating docker** ("Emulate Docker CLI using podman"), so there is
no real rootful Docker available — both names resolve to the same rootless podman.

Rootless podman runs every container inside a **user namespace**. The Linux kernel forbids
creating device nodes (`mknod` of char/block devices) in a userns-owned mount — **regardless of
`--privileged`, dropped/added capabilities, or buildkit `security.insecure` entitlements.** The
nested-dockerd-in-a-container setup inherits the outer user namespace, so the inner build's
`mknod` is blocked too.

### Proof (minimal repro, no buildkit involved)

```
$ docker run --rm --privileged alpine sh -c 'mknod /tmp/null c 1 3 && echo OK'
mknod: /tmp/null: Operation not permitted
```

A plain `--privileged` container still cannot `mknod`. This rules out every cap/seccomp/buildkit
config knob — the blocker is the user namespace itself.

## Why config tweaks won't help

- `--privileged` — already set on the build container; insufficient (proof above).
- buildkit `RUN --security=insecure` + `--allow security.insecure` — affects caps/seccomp, **not**
  the userns device-node restriction. No effect here.
- Adding `CAP_MKNOD` — the cap is meaningless inside a userns for device-node creation.

The only fix is to leave the user namespace, i.e. run the build in a **root-owned kernel context**.

## Options (escalating weight)

1. **Rootful container runtime** for the c2w step — `sudo podman` (or a real rootful dockerd). Root
   containers are not userns-remapped by default, so `mknod` works. Lightest fix; needs root/sudo.
2. **Dedicated build VM** (Lima / `podman machine` / qemu / cloud builder) running a rootful daemon;
   download the resulting `wasm-out/` artifacts. Self-contained, no host root. ← user's instinct.
3. **Offload to remote/CI rootful builder**, publish `wasm-out/` as an artifact, skip local build.

## Decision — Option 1: rootful podman (implemented)

Verified on this host that rootful podman escapes the restriction:

```
$ sudo podman run --rm --privileged alpine sh -c 'mknod /tmp/null c 1 3 && echo MKNOD_OK'
MKNOD_OK
```

`browser_demo.go` now runs the **c2w build subsystem rootfully** while keeping the app-image
export rootless:

- Rootful (`sudo podman`): builder-image build/inspect (`buildC2WBuilderImage`), stale-build stop
  (`stopStaleBuilds`), the privileged nested-dockerd `run`, and the deferred stop cleanup. Helpers:
  `sudoCtx` / `sudoBare` (Stdin wired to the terminal so sudo can re-prompt).
- Rootless (`rt`): `podman save emojig-demo` — the image lives in the user's rootless storage; the
  rootful build only consumes the resulting tar (bind-mounted in).
- `primeSudo` runs `sudo -v` once up front so the multi-minute build doesn't prompt midway.
- `chownToUser` restores ownership of `scripts/wasm-out/` after the build (root wrote the files).

### Follow-on bugs uncovered once the build ran past `mknod`

Going rootful let the build reach steps that the early `mknod` failure had always masked:

1. **Builder image failed to build** — `Dockerfile.c2w` had `go build -q`, but `go build` has no
   `-q` flag (`flag provided but not defined: -q`). Removed it. (The earlier rootless runs only
   passed because a builder image had been cached before that flag was added.)
2. **Cache not persisting** — the in-container success path did `kill $DOCKER_PID; exit` with no
   `wait`, so PID 1 exited and the nested dockerd was SIGKILLed mid-flush, leaving the buildkit
   cache uncommitted. Now `kill -TERM` + `wait $DOCKER_PID` before exit.
3. **Export collision on `/out`** — c2w's buildx exports with `--output type=local,dest=/` and
   replaces the top-level `/out` entry; bind-mounting the host dir at `/out` made that a mountpoint,
   so the export died with `failed to remove /out: unlinkat //out: device or resource busy`. Fix:
   mount the host dir at `/export` instead, let c2w write a real `/out`, and `cp -a /out/. /export/`
   after a successful build.

### Consequences / notes

- The `emojig-c2w-dind-cache` volume and `emojig-c2w-builder` image now live in **root's** podman
  storage (separate from any rootless copies built during earlier failed attempts; those rootless
  leftovers are harmless but can be pruned).
- sudo here **requires a password** (no NOPASSWD), so the demo prompts once per run (cached ~5 min).
- If a sudo-free / fully self-contained path is later needed (CI, headless), revisit option 2 (build
  VM) — the implementation cleanly isolates the rootful calls behind `sudoCtx`/`sudoBare`.

## Notes / breadcrumbs already in place

- Filtered c2w live log (step headers + `DONE`/`CACHED`/`ERROR`) makes failures surface quickly.
- Nested-dockerd `/var/lib/docker` is persisted via the `emojig-c2w-dind-cache` named volume, so the
  expensive `apt-get`/`FROM` layers stay cached and reruns reach the `mknod` failure in seconds.
- Build containers are stopped (graceful, `stop -t 30`) not killed, to keep that cache intact.
