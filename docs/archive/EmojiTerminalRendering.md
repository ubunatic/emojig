
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [InlineTuiGuide.md](file:///home/uwe/projects/emojig/docs/InlineTuiGuide.md)
> - **Extra Content Covered Here:** Unicode standard code point details for VS-16 (`U+FE0F`), explanation of character width databases, and list of terminals broken/correct (Tilix, Foot, Claude Code, agy).
> - **Outdated Information:** Version references to v0.1.5.

---
# Emoji Terminal Rendering: Variation Selector-16 Artifacts

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Describes terminal rendering behavior observed with **Emojig v0.1.5** on Linux.

---

## 1. The Symptom

When a user copies an emoji from the picker and pastes it into a terminal input line, some terminals display a visible `<fe0f>` artifact immediately after the emoji glyph. For example, pasting "🏔" may appear as:

```
🏔<fe0f>
```

This is **not a bug in Emojig**. The picker copies the correct Unicode sequence. The artifact is a terminal emulator rendering issue.

---

## 2. What Is U+FE0F?

`U+FE0F` is **Unicode Variation Selector-16 (VS-16)**. It is a zero-width, invisible formatting character defined in the Unicode standard that instructs rendering engines to display the preceding character in emoji (pictographic) presentation rather than text presentation.

Many characters in Unicode have both a text form and an emoji form. For example, `U+1F3D4` (🏔 mountain) is unambiguous as an emoji, but characters like `☀` (sun, U+2600) can render as a monochrome symbol or a full-color emoji depending on context. Appending VS-16 (`U+2600 U+FE0F`) forces the emoji form.

Modern operating systems, mobile keyboards, and clipboard implementations routinely append VS-16 when copying emojis to ensure consistent rendering. Emojig's picker follows this convention.

---

## 3. Why Some Terminals Show `<fe0f>` and Others Don't

The difference in behavior comes down to how a terminal emulator handles **character width detection** for zero-width Unicode characters.

When a terminal receives a character, it consults its internal Unicode width database (analogous to the POSIX `wcwidth()` function) to determine how many columns the character occupies. VS-16 must be reported as **width 0** — it is invisible and takes no space. When a terminal's Unicode data is up to date, VS-16 is silently swallowed and the emoji is displayed correctly.

When a terminal's Unicode width table is **outdated or incomplete**, it may return a non-zero width for VS-16. The terminal then treats it as a printable character and renders it literally, producing the visible `<fe0f>` artifact in the input line. The shell's readline layer cannot compensate for this, because it trusts the terminal's width reporting.

Each terminal emulator maintains its own Unicode width database, independent of the host OS. Update cadence varies considerably across projects, which explains inconsistent behavior across terminals running on the same machine.

### Observed behavior (as of May 2026)

| Terminal | VS-16 Handling | Notes |
|----------|---------------|-------|
| **tilix** | Broken — shows `<fe0f>` | libvte with outdated Unicode data |
| **foot** | Broken — shows `<fe0f>` | Own renderer with stale width tables |
| **Claude Code TUI** | Correct — invisible | Modern Unicode data |
| **agy** | Correct — invisible | Modern Unicode data |

This is a non-exhaustive sample. Any terminal with an outdated Unicode width database may exhibit the broken behavior.

---

## 4. This Is Expected and Out of Emojig's Control

There is no reliable application-level workaround. Emojig cannot strip VS-16 from copied emojis because:

1. **Stripping VS-16 changes the emoji.** For characters with dual text/emoji presentations, removing VS-16 may result in a monochrome symbol being pasted instead of the expected emoji glyph.
2. **The artifact is in the input echo, not the clipboard.** The terminal displays `<fe0f>` as part of rendering the readline input buffer, but the actual clipboard content is the correct Unicode sequence. After the user submits the input (presses Enter), the string is interpreted correctly by the shell.
3. **The fix belongs in the terminal.** Updating the terminal emulator's bundled Unicode data — or switching to a terminal that handles emoji width correctly — resolves the issue.

---

## 5. Reporting the Issue Upstream

Users experiencing this on tilix or foot should report it to the respective terminal projects, referencing:

- The specific emoji sequence that triggers the artifact (e.g., `U+1F3D4 U+FE0F`)
- The Unicode standard version their terminal's width tables are based on
- The expected behavior: VS-16 (`U+FE0F`) must be reported as zero-width (`wcwidth` returns 0)
