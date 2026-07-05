---
title: Spec System Reference
weight: 30
---

# Cati Spec System — Authoritative Reference


The `spec/` directory is **application code**, not configuration. Treat it with the same rigour as Go source: every change must be intentional, every object must be used, and the spec must always be readable by the running app.

---

## 1. Core Rule

> **Spec files are the single source of truth. Go code must not duplicate or shadow spec values.**

Violations:
- Hardcoded fallback maps in Go that mirror spec content (`loadButtons` returning Go-default labels)
- Keys hardcoded in switch cases that are already in `buttons.yaml keys:`
- Actions hardcoded in Go that no spec button references

If the spec file cannot be read at runtime, the app degrades gracefully (raw key names shown instead of labels, no crash) — it does **not** fall back to a Go-maintained copy of the spec content.

---

## 2. File Map

| File | Schema | Role |
|------|--------|------|
| `spec/style.yaml` | `schemas/style.schema.json` | All visual tokens: colors, borders, caps, scrollbar |
| `spec/labels.yaml` | `schemas/labels.schema.json` | Non-button strings: icons, hints, URLs, titles |
| `spec/buttons.yaml` | `schemas/buttons.schema.json` | Button text, action bindings, keyboard shortcuts |
| `spec/views.yaml` | `schemas/views.schema.json` | Per-view layout rows; `hidden_keys:` for invisible bindings |
| `spec/theme.yaml` | `schemas/theme.schema.json` | Semantic style tokens (primary, secondary, danger, …) |
| `spec/controls.yaml` | `schemas/controls.schema.json` | Settings form fields with type/min/max/values |
| `spec/config.yaml` | `schemas/config.schema.json` | App config defaults loaded before user config |
| `spec/about.yaml` | — | About page content (title, content, controls) |

Every YAML file has a companion JSON Schema in `spec/schemas/` for editor validation and auto-complete.

---

## 3. Key Concepts

### 3.1 `spec/buttons.yaml` — the action registry

Every user-facing action is defined here. An action not listed here does not exist.

```yaml
buttons:
  quit:
    text: "{ 'Q' | bold | light }uit"   # supports full renderTpl syntax
    style: danger                         # theme token
    action: quit                          # Go action name — must be in schema enum
    keys: ["q", "Q", "<c-c>"]            # named aliases resolved by resolveKeyName()
```

**Named key aliases** (resolved by `resolveKeyName` in Go):

| Alias | Terminal sequence |
|-------|-------------------|
| `<esc>` | `\x1b` |
| `<bs>` | `\x7f` |
| `<c-c>` | `\x03` |
| `<cr>` | `\x0d` |
| `<space>` | `" "` |
| `<up>` `<down>` `<left>` `<right>` | `\x1b[A` … `\x1b[D` |
| `<pgup>` `<pgdn>` | `\x1b[5~` `\x1b[6~` |

**Hidden buttons** — key-binding-only entries with no visible label:

```yaml
  nav_up:
    text: ""          # empty → not rendered in button bar
    style: secondary
    action: nav_up
    keys: ["<up>"]
```

These must be placed in a `hidden_keys:` row in `spec/views.yaml`, **not** in a visible `row:`.

### 3.2 `spec/views.yaml` — layout rows

Three row types per view:

```yaml
views:
  browser:
    - area: grid                                # content fill area
    - row: "{ prev } { next } | { quit }"      # visible button bar
    - hidden_keys: "{ nav_up } { nav_down }"   # key-only bindings (not rendered)
    - row: "{ hint_browser }"                  # hint bar (contains hint_ label)
```

- `row:` — first non-hint row drives `drawBottomMenu`; hint rows drive `drawHintBar`
- `hidden_keys:` — contributes to key maps via `loadViewKeyRows()` but is invisible

### 3.3 Key dispatch pipeline

```
spec/buttons.yaml keys:
  → resolveKeyName() → resolved byte sequences
  → loadButtonKeyDefs() → map[buttonName]buttonKeyDef{action, keys}
  → buildViewKeyMaps(loadViewKeyRows(), defs)
     → per-view map[key]action
  → viewKeyAction(tok) in keyboard switch default: case
  → action handler in Go switch
```

Structural keys not driven by any button (e.g. `\x0d` Enter to open, `\t` Tab in settings, arrow-pan in image viewer) remain as explicit `case` entries in Go with a comment marking them as structural.

`\x03` (Ctrl-C) is **always** kept as an explicit hardcoded case in every keyboard handler as a last-resort quit safeguard — independent of whether `quit` button's `<c-c>` key is loaded from spec.

---

## 4. Quality Invariants — "the spec compiles"

The spec is considered **clean** when all of the following hold:

1. **No stale actions** — every `action:` value in `buttons.yaml` appears in the schema enum AND has a handler in Go
2. **No unused buttons** — every button defined in `buttons.yaml` appears in at least one view row or `hidden_keys:` row in `views.yaml`
3. **No schema drift** — every property used in any YAML file is declared in its companion schema; no extra properties exist in schema that no YAML uses
4. **No Go fallbacks** — Go loading functions (`loadButtons`, `loadButtonKeyDefs`, etc.) do not contain hardcoded copies of spec content; the spec file is the only source
5. **Keys are specced** — every key that triggers an action must have a `keys:` entry in `buttons.yaml` on the button that owns the action; undocumented hardcoded keys are a bug
6. **Labels are complete** — every label key referenced in any view row or hint bar template exists in `labels.yaml`

---

## 5. Agent Rules

When working with spec files, agents **must**:

- **Read the spec before editing Go** — understand which actions, keys, and labels exist before writing handlers
- **Update spec and Go together** — adding a new action means: schema enum, buttons.yaml entry, views.yaml placement, Go handler, test
- **Run schema validation** after any spec change: `make validate-spec` (or equivalent)
- **Write tests** that assert spec integrity (see §6)
- **Never add Go fallback copies** of spec content — if a fallback is needed, add a failing test that catches the divergence
- **Close the loop on removals** — removing a button means removing it from views.yaml, removing its action from the schema enum if unused, and removing its Go handler

---

## 6. Tests for Spec Integrity

Spec tests live in `cmd/` alongside the loaders. Each test function should be named `TestSpec<Thing>`.

Required coverage:

| Test | What it checks |
|------|---------------|
| `TestSpecButtonsLoad` | `loadButtonKeyDefs()` returns non-empty map; all buttons have non-empty action |
| `TestSpecButtonsAllUsed` | every button name in `buttons.yaml` appears in some view's row or `hidden_keys:` |
| `TestSpecActionsAllHandled` | every `action:` in `buttons.yaml` has a case in `viewKeyAction` dispatch (or is structural-documented) |
| `TestSpecViewsLoad` | `loadViewButtonRows()` and `loadViewKeyRows()` return entries for all expected views |
| `TestSpecKeyResolve` | `resolveKeyName` maps all documented aliases correctly |
| `TestSpecNoGoFallback` | `loadButtons("")` returns only labels sourced from spec (not hardcoded) |

---

## 7. Change Checklist

When modifying the spec, work through this list:

- [ ] Added `action:` to schema enum if new
- [ ] Added button to `buttons.yaml` with text, style, action, keys
- [ ] Placed button in a `row:` or `hidden_keys:` in `views.yaml`
- [ ] Added Go handler for the action in the relevant keyboard `default:` switch
- [ ] Added Go handler for the action in the relevant mouse click switch
- [ ] Updated `docs/Design.md` section 3 if the data flow changed
- [ ] No stale entries remain (removed button removed from all view rows)
- [ ] `go vet ./...` clean, `go test ./...` green, `make install` succeeds
