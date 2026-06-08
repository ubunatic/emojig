<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Prompt Reference: Documentation & Asset Refactoring

Use this prompt to archive and refactor documentation, reorganize media assets, and clean up repository layouts.

---

## Original Task Prompt

```
1. Archive all docs, then cherry pick key points into new clean and concise versions of the "evergreen" docs/ 
2. Also move images to a sub folder so they do not pollute the docs/ dir
3. Add header sections to archived docs, which evergreen are replacing them and what extra content they may still cover that is not in the evergreens, and what info in the doc may be very outdated

Goals:

1. Teach developers and agents how to build inline TUIs
2. Explain common pitfalls when building such zig apps
3. Terminal integration stories
4. Story on the why/niche
5. You decided what else is worth keeping
```

---

## Agent Guidelines & Reasoning Hints

When executing this task or similar documentation refactoring, adhere to the following principles:

### 1. File and Path Auditing
* **Verify Tracking State**: Use `git ls-files` to determine which files are tracked and which are untracked. Avoid broken movements.
* **Update References Globally**: When moving assets (e.g. into `docs/media/`), search the entire project for path string matches (e.g., `.png`, `.mp4`) and rewrite them in files like `README.md`, `REUSE.toml`, and the documents themselves.

### 2. Scripting Constraints
* **No Python**: If mass modifications are needed (like editing 20+ archive banners), write a flat helper script in Go under `scripts/` and run it via `go run scripts/<name>.go`.
* **Licensing**: Any script or file added to the repository must begin with appropriate SPDX copyright/license headers to pass REUSE verification.

### 3. Archive Banners
When adding replacement headers to archived files, explicitly specify:
* **`Replaced by`**: Clickable Markdown file links (`[doc](file:///...)`) pointing to the new evergreen location.
* **`Extra Content Covered Here`**: Concrete details of low-level technical information not present in the clean/concise evergreen versions (to preserve historical implementation references).
* **`Outdated Information`**: Any stale versions, deprecated designs, or changed structures.

### 4. Git Worktree Staging Hygiene
* Never stage changes using `git add -A` or `git add .` blindly. Stage edits by explicit path to ensure concurrent agent changes in the main branch are not accidentally committed.
* Run `make preflight` (for REUSE compliance and formatting checks) before staging.

