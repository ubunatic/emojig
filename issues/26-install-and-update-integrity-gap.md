<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "install.sh and self-update still skip artifact verification"
status: open
priority: p1
---

# 26 — `install.sh` and self-update still skip artifact verification

**Status:** Open  
**Priority:** P1

## Problem

The current release plan says the direct install path should verify downloaded
artifacts, but the implementation still does not.

Today:

- `scripts/install.sh` downloads the tarball and extracts it immediately
- there is no `SHA256SUMS` download
- there is no `sha256sum` check
- there is no `minisign` verification step
- the curl-install update mode still points back to the same installer

So the repository's current **distribution trust story is stronger in docs than
in code**.

## Evidence

- `issues/02-distribution-and-release.md:356` — `Download tarball + SHA256SUMS, verify hash, extract emojig`
- `scripts/install.sh:50-61` — section header says "Download & Verify Release Archive", but the code only downloads + extracts
- `src/integration.zig:286` — `cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";`

## Reproduction

```sh
go run ./scripts/review_audit install-update-integrity
```

Current result: **fails**, because the release plan promises verification while
the installer and curl-update path still skip it.

## Why this matters

This is the strongest resilience issue in the repo right now:

1. users cannot detect a corrupted or tampered tarball before extraction
2. self-update inherits the same trust gap
3. the project already publishes signing/checksum material, so the missing step
   is not policy — it is implementation drift

## Suggested fix

Make the direct install/update path match the documented release model:

1. download the tarball **and** `SHA256SUMS`
2. verify the tarball hash before extraction
3. optionally verify `SHA256SUMS` with `minisign.pub`
4. keep `install.sh` and the curl-install update branch aligned

## Chosen direction

**Decision (2026-06-21):** Keep the installer simple and document the risk more
clearly instead of adding verification logic right now.

That means this issue shifts from "add verification to the installer" toward:

1. making the trust tradeoff explicit in installer/update docs
2. avoiding wording that falsely implies verification already happens
3. keeping the backlog note open until the docs and wording fully match reality

## Related older issue

This is related to the broader release planning work in
[Issue 02](02-distribution-and-release.md), but it is concrete enough to track
as its own implementation gap.
