<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Git Worktrees — Guide & Development Hygiene

Git worktrees allow multiple branches to live concurrently in separate directories while sharing a single underlying `.git` repository. This is especially useful when running parallel automated agents or developer branches.

---

## 1. Initializing a Worktree

We provide a Makefile target that automates worktree creation and sets up gitignored assets:
```sh
# Create a worktree named 'my-feature' on a new branch of the same name
make worktree NAME=my-feature

# Navigate and run tests
cd ../emojig-my-feature
zig build test
```

### The `make worktree` Difference
A raw `git worktree add` command only checks out tracked files. Since the raw emoji JSON database (`data/emoji.json`) is gitignored, a raw checkout cannot run database recompilation (`make pack`). The `make worktree` helper resolves this by automatically **symlinking** the `data/` directory from the main repository checkout.

---

## 2. Merging Agent Work Back Safely

When automated agents are launched with `isolation: "worktree"`, they operate in a separate directory branched from a specific base commit. 

> [!WARNING]
> **Never copy the agent's modified files directly over your main working directory.** If the main branch has advanced since the agent was spawned, a direct file copy will silently revert newer commits.

### The Correct Merge Procedure

To merge changes safely, extract the diff between the agent's branch and its original merge-base, then apply it as a patch:

1. **Find the merge base**:
   ```sh
   WT=.claude/worktrees/agent-<id>
   BASE=$(git merge-base HEAD <agent-branch>)
   ```
2. **Generate the diff patch**:
   ```sh
   git -C "$WT" diff "$BASE" -- src/main.zig > /tmp/agent.patch
   ```
3. **Check and apply the patch**:
   ```sh
   git apply --check /tmp/agent.patch
   git apply /tmp/agent.patch
   ```
4. **Clean up the worktree and branch**:
   ```sh
   git worktree remove "$WT" --force
   git branch -D <agent-branch>
   ```
5. **Verify in the main tree**:
   ```sh
   zig build test
   zig fmt --check src/
   ```

---

## 3. Hygiene & Contribution Checklist

* **Keep build cache separate**: Build artifacts (`.zig-cache/`, `zig-out/`, `dist/`) are gitignored and managed per-worktree to avoid directory locks and build collisions.
* **Ignore transient worktrees**: The folder `.claude/worktrees/` is gitignored. If a worktree is created elsewhere inside the repo, it must be ignored to prevent `reuse lint` from walking into it and reporting licensing errors.
* **Stage by explicit path**: When multiple workers or agents are editing a shared main tree, never run `git add .` or `git add -A`. Always stage files by their specific paths to prevent staging unfinished third-party changes.
