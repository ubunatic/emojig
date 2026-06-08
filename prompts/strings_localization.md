<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Prompt Reference: Localization and Multi-Language Sync

Use this prompt when updating UI strings, adding new keys to `spec/strings.json`, or introducing support for additional languages.

---

## Original Task Prompt

```
1. Sync all localization files under `spec/strings_*.json` whenever `spec/strings.json` changes.
2. Ensure every JSON file contains the exact same keys as the main English specification.
3. Keep the format, structure, and spacing consistent across translations.
4. Translate all text accurately, preserving formatting variables like `{count}` and keyboard shortcuts like `Esc` / `Tab`.
```

---

## Agent Guidelines & Translation Hints

When localizing strings, respect these constraints:

### 1. File Naming & Structure
* All localized UI strings reside in flat files under `spec/` named `strings_<lang>.json` (e.g., `strings_es.json` for Spanish, `strings_fr.json` for French).
* Do not alter the JSON formatting; keys must match `spec/strings.json` exactly.

### 2. Formatting & Spacing Limits
* UI strings are rendered directly onto a width-restricted terminal grid (configured in `spec/layout.json`).
* Ensure translations do not exceed the width limits to prevent truncation.
* Retain any padding spaces used for aligning keys or prompts (e.g. ` 🔍 ` or the padding in key descriptions).

### 3. Special Variables & Controls
* **Live Counter**: The `{count}` placeholder is parsed and replaced dynamically. Keep it exactly as `{count}` in all files.
* **Control Keys**: Retain standard key labels like `Esc`, `Tab`, `Ctrl-C`, `Enter`, or translate them to their commonly accepted regional equivalents (e.g., `Échap` / `Entrée` in French).

### 4. Verification & Testing
* Run `make preflight` to run the built-in Zig unit test suite.
* The tests verify that all `strings_*.json` files compile and successfully parse into the `spec.Strings` structure, preventing missing or incorrectly typed keys.
