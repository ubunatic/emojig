<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Git Worktrees — Guide & Hard-Won Lessons

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026 (**Emojig v0.1.4**). Written after a
> multi-agent session that hit every one of the worktree pitfalls below. Read this
> before spinning up parallel work — most of these cost real debugging time.

Git worktrees let several branches live in separate directories that **share one
`.git`**. They're ideal for running parallel agents on isolated copies of the repo.
This repo is *mostly* worktree-ready out of the box — but there are sharp edges,
especially around **preparation** and **merging agent work back**.

---

## 1. Creating a worktree

Use the helper (creates a sibling dir + links the gitignored `data/`):

```sh
make worktree NAME=my-feature          # → ../emojig-my-feature on branch my-feature
make worktree NAME=fix WORKTREE_BRANCH=hotfix/x
cd ../emojig-my-feature && zig build test
git worktree remove ../emojig-my-feature   # when done
```

Raw git also works: `git worktree add -b branch ../emojig-branch`.

---

## 2. Preparation: what a fresh worktree is (and isn't) missing

A new worktree is a clean checkout of tracked files only. Consequences:

| Concern | State | Why it's fine / what to do |
|---|---|---|
| **Build / test** | ✅ Works immediately | `src/emojis.bin` is **tracked**, and `root.zig` embeds it. No bootstrap needed for `zig build` / `zig build test`. |
| **`data/`** (raw emoji JSON) | ⚠️ **Missing** — it's gitignored | Only `make pack` (regenerating `src/emojis.bin`) needs it. `make worktree` **symlinks** `data/` from the main checkout so `make pack` works there too. Raw `git worktree add` does **not** — link it yourself if you need to repack. |
| **`.zig-cache/`, `zig-out/`, `dist/`** | Per-worktree, gitignored | Each worktree builds independently — no collisions, but also no cache sharing (first build is cold). |
| **minisign key** | Shared | `MINISIGN_KEY_FILE` defaults to `$HOME/.minisign/minisign.key` (outside the repo), so every worktree sees it. |
| **`.claude/worktrees/`** | gitignored | Agent-tool worktrees live here; see §4. |

**Rule of thumb:** if a file is needed at build/run time, it must be **tracked**.
If it's only needed by a tooling step (`make pack`), gitignore it and link it in.

---

## 3. Merging agent work back — the #1 trap

When you launch an agent with `isolation: "worktree"`, the harness creates a worktree
**branched from a base commit (typically the repo HEAD at session start), and leaves
the agent's changes UNCOMMITTED in that worktree.** Two things bite:

### 3a. The agent's base can be STALE

If you commit new work to `main` *after* launching the agent, the agent's worktree
does **not** contain those commits. In this session: a `--list` feature was committed
to `main`, then a `--gui` agent was launched — but its worktree was based on the
older HEAD **without** `--list`.

> **Never `cp` the agent's whole file over `main` when `main` has advanced.** A naive
> `diff main vs agent` shows your *newer* commits as `-` (deletions), and copying the
> agent file would silently **revert** them. In this session that would have deleted
> the entire `--list` feature.

### 3b. The correct merge recipe

Diff the agent's worktree against **its own base (the merge-base)**, not against
current `main`. That patch contains *only* the agent's edits and applies cleanly onto
`main` as long as the touched regions didn't change in your newer commits:

```sh
WT=.claude/worktrees/agent-<id>
BASE=$(git merge-base HEAD <agent-branch>)        # the agent's real base
git -C "$WT" diff "$BASE" -- src/main.zig > /tmp/agent.patch

# Sanity: confirm the patch doesn't touch unrelated, newer features
grep -n 'opt_list\|--list' /tmp/agent.patch || echo "clean"

git apply --check /tmp/agent.patch && git apply /tmp/agent.patch
zig build && zig build test && zig fmt --check src/   # verify in the main tree
```

Then remove the worktree + branch:

```sh
git worktree remove "$WT" --force
git branch -D <agent-branch>
```

**Always re-run build/test in the main tree after applying** — "it passed in the
worktree" is not the same as "it composes with the rest of `main`."

---

## 4. Hygiene: keep transient worktrees out of git and lint

- **Gitignore agent worktrees.** `.claude/worktrees/` is ignored (see `.gitignore`).
  If it isn't, agent worktrees show as `?? .claude/` in `git status` **and**
  `reuse lint` walks into them — in this session that inflated the file count
  76 → 148 and produced a *false* REUSE non-compliance report. If `reuse lint`
  suddenly counts far more files than the repo has, a worktree is leaking into it.
- **`make worktree` siblings** (`../emojig-*`) live outside the repo, so they never
  pollute status. The in-repo `worktrees/` path is also gitignored as a fallback.

---

## 5. Concurrent edits in the shared main tree

Multiple agents/sessions can leave **uncommitted changes in the main working tree at
the same time** (e.g. one agent editing `website/` + `REUSE.toml` while you edit
`src/`). This makes `git status` show changes you didn't make.

- **Identify before you stage.** `git diff <file>` each unexpected entry; don't assume
  it's yours.
- **Stage by explicit path**, never `git add -A`/`git add .` blindly — you may scoop
  up another worker's half-finished change into your commit.
- **Group commits by concern** so each commit is one coherent unit and attribution
  stays clear.

---

## 6. Pre-flight checklist before parallel/agent work

- [ ] Build artifacts gitignored & untracked (`.zig-cache/`, `zig-out/`, `dist/`) ✅
- [ ] Compile inputs **tracked** (`src/emojis.bin`) so fresh worktrees build ✅
- [ ] Tooling-only inputs (`data/`) linked by `make worktree` ✅
- [ ] `.claude/worktrees/` gitignored ✅
- [ ] Know each agent's **base commit** so you can diff against the merge-base, not `main`
- [ ] After merging: `git apply` (not `cp`) + re-run `zig build test` + `zig fmt --check` in `main`
