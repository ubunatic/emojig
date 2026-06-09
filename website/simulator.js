/*
 * SPDX-FileCopyrightText: 2026 Uwe Jugel
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

class EmojigSimulator {
  constructor() {
    this.query = "";
    this.selectedIdx = null;
    this.theme = "dark";
    this.systemTheme = "dark";
    this.showBorder = false;
    this.safeMode = false;
    this.isFocused = false;
    // Ignore the synthetic mouseenter the browser fires on grid cells when a
    // keyboard nav re-renders the DOM under a stationary pointer (it would
    // otherwise yank the selection back to the hovered cell). Cleared on a
    // real mousemove.
    this.suppressHover = false;
    this.fsRoot = this._makeFs();
    this.cwd    = ["home", "you", "projects", "emojig"];
    this.fakeEnv = {
      HOME:         "/home/you",
      USER:         "you",
      SHELL:        "/bin/zsh",
      TERM:         "xterm-256color",
      EDITOR:       "emojig",
      PATH:         "/home/you/.local/bin:/usr/local/bin:/usr/bin:/bin",
      EMOJIG_THEME: "dark",
      LANG:         "en_US.UTF-8",
      PWD:          "/home/you/projects/emojig",
      GREETING:     "Hello 👋",
    };

    // Shell-widget mode: the terminal starts at a shell prompt. Typing echoes
    // characters; Ctrl+E launches the emojig picker (the TUI). Picking an emoji
    // inserts it into the command line — exactly like the real shell widget.
    this.mode = "shell"; // "shell" | "tui"
    this.shellLines = []; // completed terminal lines: { kind: 'cmd' | 'out', text }
    this.shellInput = ""; // current command line being typed
    this.cursorPos = 0; // cursor index within shellInput (in code points)
    this.shellHistory = []; // executed commands, oldest first
    this.historyIdx = null; // pointer while browsing history; null = editing fresh line
    this.shellDraft = ""; // in-progress line stashed when history browsing begins
    this.maxShellRows = 16; // visible rows before older lines scroll off the top

    this.cols = 6;
    this.rows = 4;
    this.contentWidth = 25;

    this.detectSystemTheme();
    this.setupMediaListeners();
  }

  detectSystemTheme() {
    if (
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: light)").matches
    ) {
      this.systemTheme = "light";
    } else {
      this.systemTheme = "dark";
    }
  }

  setupMediaListeners() {
    if (window.matchMedia) {
      window
        .matchMedia("(prefers-color-scheme: light)")
        .addEventListener("change", (e) => {
          this.systemTheme = e.matches ? "light" : "dark";
          if (this.theme === "system") {
            this.updateThemeClass();
            this.render();
          }
        });
    }
  }

  getEffectiveTheme() {
    return this.theme === "system" ? this.systemTheme : this.theme;
  }

  // --- Fuzzy Matching Algorithm (Zig Port) ---

  matchTermDirect(term, target) {
    if (term.length === 0) return 0;

    let score = 0;
    let targetIdx = 0;
    let termIdx = 0;
    let consecutive = 0;

    const termLower = term.toLowerCase();
    const targetLower = target.toLowerCase();

    while (termIdx < termLower.length) {
      if (targetIdx >= targetLower.length) return null; // Not a subsequence

      const termChar = termLower[termIdx];
      const targetChar = targetLower[targetIdx];

      if (termChar === targetChar) {
        let charScore = 10;

        // Bonus for matching at the start of a word
        if (targetIdx === 0 || target[targetIdx - 1] === " ") {
          charScore += 40;
        }

        // Compounding bonus for consecutive matches
        if (consecutive > 0) {
          charScore += 20 * consecutive;
        }

        score += charScore;
        consecutive += 1;
        termIdx += 1;
      } else {
        // Small gap penalty
        score -= 1;
        consecutive = 0;
      }
      targetIdx += 1;
    }

    // Penalty for starting late in the target string
    const startIdx = targetIdx - term.length;
    score -= startIdx;

    return score;
  }

  matchTerm(term, target) {
    if (term.length === 0) return 0;

    let score = this.matchTermDirect(term, target);
    if (score !== null) return score;

    // Fallback: Plurals (if term ends in 's' and length > 3, e.g. "cars" -> "car")
    if (term.length > 3 && term[term.length - 1].toLowerCase() === "s") {
      const last2 = term[term.length - 2].toLowerCase();
      if (last2 !== "s") {
        // avoid "glass", "grass"
        // If it ends in "ies" and length > 5 (e.g. "cherries" -> "cherry")
        if (
          term.length > 5 &&
          last2 === "e" &&
          term[term.length - 3].toLowerCase() === "i"
        ) {
          const alternate = term.slice(0, term.length - 3) + "y";
          const s = this.matchTermDirect(alternate, target);
          if (s !== null) return s - 5;
        }
        // If it ends in "es" and length > 4 (e.g. "boxes" -> "box")
        if (term.length > 4 && last2 === "e") {
          const alternate1 = term.slice(0, term.length - 2); // strip "es"
          const s1 = this.matchTermDirect(alternate1, target);
          if (s1 !== null) return s1 - 5;

          const alternate2 = term.slice(0, term.length - 1); // strip "s" (e.g. "shoes" -> "shoe")
          const s2 = this.matchTermDirect(alternate2, target);
          if (s2 !== null) return s2 - 5;
        }
        // Default plural strip 's'
        const alternate = term.slice(0, term.length - 1);
        const s = this.matchTermDirect(alternate, target);
        if (s !== null) return s - 5;
      }
    }

    // Fallback: Word stems (if term ends in 'ing' and length > 4, e.g. "racing" -> "rac" or "race")
    if (term.length > 4 && term.toLowerCase().endsWith("ing")) {
      const stem = term.slice(0, term.length - 3);
      // try stem directly (e.g. "racing" -> "rac")
      const s = this.matchTermDirect(stem, target);
      if (s !== null) return s - 5;

      // try stem + "e" (e.g. "racing" -> "race")
      const alternate = stem + "e";
      const s2 = this.matchTermDirect(alternate, target);
      if (s2 !== null) return s2 - 5;

      // If double consonant stem (e.g. "running" -> "run")
      if (stem.length > 2 && stem[stem.length - 1] === stem[stem.length - 2]) {
        const alternate2 = stem.slice(0, stem.length - 1);
        const s3 = this.matchTermDirect(alternate2, target);
        if (s3 !== null) return s3 - 5;
      }
    }

    // Fallback: Query stem (if term ends in 'e' and length > 3, e.g. "race" -> "rac")
    if (term.length > 3 && term[term.length - 1].toLowerCase() === "e") {
      const alternate = term.slice(0, term.length - 1);
      const s = this.matchTermDirect(alternate, target);
      if (s !== null) return s - 5;
    }

    return null;
  }

  fuzzyMatch(query, target) {
    let totalScore = 0;
    const terms = query.trim().split(/\s+/);
    let hasTerms = false;

    for (const term of terms) {
      if (!term) continue;
      hasTerms = true;
      const score = this.matchTerm(term, target);
      if (score === null) return null;
      totalScore += score;
    }

    if (!hasTerms) return 0;
    return totalScore;
  }

  // --- Search Logic ---

  getEmojiWidth(emoji) {
    if (!emoji) return 0;
    if (emoji.includes("\ufe0f")) {
      return 2;
    }
    const cp = emoji.codePointAt(0);
    if (cp >= 0x1f000) {
      return 2;
    }
    if (cp === 0x231a || cp === 0x231b || cp === 0x23f3 ||
        (cp >= 0x23e9 && cp <= 0x23ec) ||
        cp === 0x23f0 ||
        cp === 0x2b50 || cp === 0x2b55 || cp === 0x2b1b || cp === 0x2b1c ||
        (cp >= 0x3000 && cp <= 0x32ff)) {
      return 2;
    }
    if (cp === 0x25fd || cp === 0x25fe ||
        cp === 0x2614 || cp === 0x2615 ||
        (cp >= 0x2648 && cp <= 0x2653) ||
        cp === 0x267f ||
        cp === 0x2693 ||
        cp === 0x26a1 ||
        cp === 0x26bd || cp === 0x26be ||
        cp === 0x26c4 || cp === 0x26c5 ||
        cp === 0x26d4 ||
        cp === 0x26ea ||
        cp === 0x26f2 || cp === 0x26f3 ||
        cp === 0x26f5 ||
        cp === 0x26fa ||
        cp === 0x26fd ||
        cp === 0x2705 ||
        cp === 0x270a || cp === 0x270b ||
        cp === 0x2728 ||
        cp === 0x274c ||
        cp === 0x274e ||
        (cp >= 0x2753 && cp <= 0x2755) || cp === 0x2757 ||
        (cp >= 0x2795 && cp <= 0x2797) ||
        cp === 0x27b0 || cp === 0x27bf ||
        cp === 0x26aa || cp === 0x26ab ||
        cp === 0x26ce) {
      return 2;
    }
    return 1;
  }

  getFilteredMatches() {
    if (typeof EMOJI_DB === "undefined") return [];
    const db = EMOJI_DB;

    let actualQuery = this.query;
    let filterWidth = null;
    if (this.query.length >= 2) {
      if ((this.query[0] === 'e' || this.query[0] === 'E') && this.query[1] === ':') {
        actualQuery = this.query.slice(2);
        filterWidth = 2;
      } else if ((this.query[0] === 't' || this.query[0] === 'T') && this.query[1] === ':') {
        actualQuery = this.query.slice(2);
        filterWidth = 1;
      }
    }

    if (actualQuery.trim() === "") {
      const filtered = [];
      for (let i = 0; i < db.length; i++) {
        const item = db[i];
        if (filterWidth !== null && this.getEmojiWidth(item[0]) !== filterWidth) {
          continue;
        }
        filtered.push({
          emoji: item[0],
          description: item[1],
          originalIdx: i,
          score: 0,
        });
      }
      return filtered.slice(0, 60);
    }

    const matches = [];
    for (let i = 0; i < db.length; i++) {
      const item = db[i];
      if (filterWidth !== null && this.getEmojiWidth(item[0]) !== filterWidth) {
        continue;
      }
      const score = this.fuzzyMatch(actualQuery, item[2]);
      if (score !== null) {
        matches.push({
          emoji: item[0],
          description: item[1],
          originalIdx: i,
          score: score,
        });
      }
    }

    // Sort by score descending, then by original index ascending
    matches.sort((a, b) => {
      if (b.score !== a.score) {
        return b.score - a.score;
      }
      return a.originalIdx - b.originalIdx;
    });

    return matches;
  }

  // --- Render Logic ---

  stripVariationSelectors(emoji) {
    return emoji.replace(/[\uFE0E\uFE0F]/g, "");
  }

  formatEmoji(emoji) {
    return this.safeMode ? this.stripVariationSelectors(emoji) : emoji;
  }

  updateThemeClass() {
    const screenEl = document.getElementById("sim-screen");
    if (!screenEl) return;
    screenEl.className =
      "sim-screen theme-" +
      this.getEffectiveTheme() +
      (this.isFocused ? " focused" : "");
  }

  render() {
    const screenEl = document.getElementById("sim-screen");
    if (!screenEl) return;

    if (this.mode === "shell") {
      this.renderShell(screenEl);
      return;
    }

    const matches = this.getFilteredMatches();
    const totalMatches = matches.length;
    const topCount = Math.min(60, totalMatches);
    const topMatches = matches.slice(0, topCount);

    // Keep selection in bounds
    if (this.selectedIdx !== null) {
      if (totalMatches === 0) {
        this.selectedIdx = null;
      } else if (this.selectedIdx >= topCount) {
        this.selectedIdx = topCount - 1;
      }
    }

    // Inline TUI: prepend recent shell lines to show the picker appearing in-place.
    let html = this.renderShellContext();

    // Helper to pad strings to monospace columns
    const padRight = (str, len) => {
      let visLen = str.length;
      // Emoji characters count as 2 columns, but standard strings count as 1.
      // In a simple web representation, we just pad using standard lengths.
      // To ensure character-perfect terminal alignments, we count the visual length.
      let chars = [...str];
      let visualWidth = 0;
      for (let ch of chars) {
        // Check if it is a double-width char (emojis, CJK)
        if (ch.codePointAt(0) > 0x1f000 || ch === "🔍") {
          visualWidth += 2;
        } else {
          visualWidth += 1;
        }
      }
      const diff = len - visualWidth;
      return str + (diff > 0 ? " ".repeat(diff) : "");
    };

    // 1. Top Border
    if (this.showBorder) {
      html += `<div class="sim-row sim-border"></div>`;
    }

    // 2. Blank Top Padding
    html += `<div class="sim-row"> </div>`;

    // 3. Search Bar
    const searchPrompt = "🔍 ";
    const queryText = this.query;
    // Remaining spacer logic: content_width(25) - prompt(3) - icon(4) = 18.
    const maxQueryCols = 18;
    const displayQuery =
      queryText.length > maxQueryCols
        ? queryText.slice(0, maxQueryCols)
        : queryText;
    const padLen = Math.max(0, maxQueryCols - displayQuery.length);

    const themeIcon =
      this.theme === "dark" ? "🌙" : this.theme === "light" ? "🌞" : "🔆";

    const placeholderHtml =
      displayQuery.length === 0
        ? `<span class="sim-cursor">█</span><span class="sim-search-placeholder">search…</span><span>${" ".repeat(Math.max(0, padLen - 8))}</span>`
        : `<span class="sim-search-query">${displayQuery}</span><span class="sim-cursor">█</span><span>${" ".repeat(Math.max(0, padLen - 1))}</span>`;
    html +=
      `<div class="sim-row sim-search"> ` +
      `<span class="sim-search-prompt">${searchPrompt}</span>` +
      placeholderHtml +
      `<span class="sim-theme-icon" id="sim-theme-toggle" title="Cycle Theme (Tab)"> ${themeIcon} </span>` +
      `</div>`;

    const isHelpMode = this.query === "?";

    if (isHelpMode) {
      // Help screen: rows+3 rows replace spacer+grid+spacer+desc (spec/strings.json)
      const helpTitle = "Help & Keybindings:";
      const helpLines = [
        "  Typing: Search",
        "  Arrows: Navigate",
        "  Enter:  Copy & Exit",
        "  Tab:    Toggle Theme",
        "  Esc:    Exit",
      ];
      for (let i = 0; i < this.rows + 3; i++) {
        let text = "";
        if (i < helpLines.length + 1) {
          text = i === 0 ? helpTitle : helpLines[i - 1];
        }
        html += `<div class="sim-row sim-help"> ${text}</div>`;
      }
    } else {
      // 4. Spacer Row
      html += `<div class="sim-row"> </div>`;

      // 5. Grid Rows
      html += `<div class="sim-grid">`;
      for (let r = 0; r < this.rows; r++) {
        let rowHtml = `<div class="sim-row"> `;
        for (let c = 0; c < this.cols; c++) {
          const idx = r * this.cols + c;
          if (idx < topCount) {
            const match = topMatches[idx];
            const formattedEmoji = this.formatEmoji(match.emoji);
            const isSelected = this.selectedIdx === idx;
            if (isSelected) {
              rowHtml += `<span class="sim-cell selected" data-idx="${idx}">[${formattedEmoji}]</span>`;
            } else {
              rowHtml += `<span class="sim-cell" data-idx="${idx}"> ${formattedEmoji} </span>`;
            }
          } else {
            rowHtml += `    `;
          }
        }
        rowHtml += `</div>`;
        html += rowHtml;
      }
      html += `</div>`;

      // 6. Spacer Row
      html += `<div class="sim-row"> </div>`;

      // 7. Description Row
      let descText = "";
      if (this.selectedIdx !== null && topMatches[this.selectedIdx]) {
        descText = topMatches[this.selectedIdx].description;
      }
      const maxDescLen = this.contentWidth - 1;
      let displayDesc = descText;
      if (descText.length > maxDescLen) {
        displayDesc = descText.slice(0, maxDescLen - 3) + "...";
      }
      html += `<div class="sim-row"> ${padRight(displayDesc, maxDescLen)}</div>`;
    }

    // 8. Status Bar Row
    const statusText = this.query.length === 0
      ? ` ?:help  ↕↔|↵|Esc`
      : ` ${totalMatches}  ↕↔|↵|Esc`;
    html += `<div class="sim-row sim-status">${padRight(statusText, this.contentWidth + 1)}</div>`;

    // 9. Bottom Border
    if (this.showBorder) {
      html += `<div class="sim-row sim-border"></div>`;
    }

    screenEl.innerHTML = html;

    // Re-bind click handlers for cells inside the screen
    const cells = screenEl.querySelectorAll(".sim-cell");
    cells.forEach((cell) => {
      const idx = parseInt(cell.getAttribute("data-idx"));
      cell.addEventListener("mouseenter", () => {
        // Skip the synthetic enter fired by a keyboard-driven re-render;
        // only a genuine mouse movement (which clears the flag) selects.
        if (this.suppressHover) return;
        this.selectedIdx = idx;
        this.render();
      });
      cell.addEventListener("click", () => {
        const match = topMatches[idx];
        this.selectEmoji(match.emoji);
      });
    });

    // Theme icon toggle hover
    const toggleEl = document.getElementById("sim-theme-toggle");
    if (toggleEl) {
      toggleEl.addEventListener("mouseenter", () =>
        toggleEl.classList.add("hovered"),
      );
      toggleEl.addEventListener("mouseleave", () =>
        toggleEl.classList.remove("hovered"),
      );
      toggleEl.addEventListener("click", (e) => {
        e.stopPropagation();
        this.cycleTheme();
      });
    }
  }

  // --- Shell Mode ---

  escapeHtml(str) {
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  get promptHtml() {
    return `<span class="sim-shell-user">you@emojig</span>` +
      `<span class="sim-shell-path">:${this.cwdString()}</span>` +
      `<span class="sim-shell-sym">$</span> `;
  }

  _makeFs() {
    const F = (m) => ({ type: "file", perms: "-rw-r--r--", size: "   0", date: "Jun  9 12:00", owner: "you", ...m });
    const D = (children, m={}) => ({ type: "dir",  perms: "drwxr-xr-x", size: "4096", date: "Jun  9 12:00", owner: "you", children, ...m });
    return D({
      "home": D({ "you": D({ "projects": D({ "emojig": D({
        "README.md":  F({ size: "1.2K", date: "Jun  9 11:55" }),
        "Makefile":   F({ size: " 567", date: "Jun  9 11:55" }),
        "emojig":     F({ perms: "-rwxr-xr-x", size: " 42K", date: "Jun  9 12:30", owner: "root" }),
        "src": D({
          "main.zig":  F({ size: "8.1K", date: "Jun  9 12:00" }),
          "input.zig": F({ size: "3.4K", date: "Jun  9 11:30" }),
        }, { size: "  96", date: "Jun  9 10:00" }),
        "notes.txt":  F({ size: " 128", date: "Jun  9 09:15" }),
        ".secret":    F({ perms: "-rw-------", size: "  42", date: "Jun  9 09:00" }),
      }) }) }) }, { owner: "root" }),
      "etc":  D({}, { owner: "root" }),
      "tmp":  D({}, { owner: "root", perms: "drwxrwxrwt" }),
      "usr":  D({ "bin": D({}, { owner: "root" }), "local": D({}, { owner: "root" }) }, { owner: "root" }),
      "var":  D({}, { owner: "root" }),
    }, { owner: "root" });
  }

  resolvePath(path) {
    const isAbs = path.startsWith("/");
    const resolved = isAbs ? [] : [...this.cwd];
    for (const p of path.split("/").filter(Boolean)) {
      if (p === ".") continue;
      if (p === "..") { resolved.pop(); continue; }
      resolved.push(p);
    }
    let node = this.fsRoot, parent = null;
    for (let i = 0; i < resolved.length; i++) {
      if (!node || node.type !== "dir") return null;
      parent = node;
      node = node.children[resolved[i]];
      if (!node) return null;
    }
    return { node, parent, name: resolved.at(-1) ?? "", components: resolved };
  }

  cwdNode() {
    let n = this.fsRoot;
    for (const c of this.cwd) n = n?.children?.[c];
    return n ?? null;
  }

  cwdString() {
    const full = "/" + this.cwd.join("/");
    const home = "/home/you";
    return full.startsWith(home) ? "~" + full.slice(home.length) : full;
  }

  seedShell() {
    this.fsRoot = this._makeFs();
    this.cwd    = ["home", "you", "projects", "emojig"];
    this.shellLines = [
      { kind: "cmd", text: "git status" },
      { kind: "out", text: "On branch main — 3 files changed" },
      { kind: "cmd", text: "git add ." },
    ];
    this.shellHistory = ["git status", "git add ."];
    this.historyIdx = null;
    this.shellDraft = "";
    this.setInput("git commit -m 'release: v1.2 ");
  }

  // --- Line editing (code-point safe, so the cursor never splits an emoji) ---

  setInput(text) {
    this.shellInput = text;
    this.cursorPos = Array.from(text).length;
  }

  insertAtCursor(text) {
    const arr = Array.from(this.shellInput);
    const ins = Array.from(text);
    arr.splice(this.cursorPos, 0, ...ins);
    this.shellInput = arr.join("");
    this.cursorPos += ins.length;
  }

  deleteBeforeCursor() {
    if (this.cursorPos <= 0) return;
    const arr = Array.from(this.shellInput);
    arr.splice(this.cursorPos - 1, 1);
    this.shellInput = arr.join("");
    this.cursorPos--;
  }

  deleteAtCursor() {
    const arr = Array.from(this.shellInput);
    if (this.cursorPos >= arr.length) return;
    arr.splice(this.cursorPos, 1);
    this.shellInput = arr.join("");
  }

  moveCursor(delta) {
    const len = Array.from(this.shellInput).length;
    this.cursorPos = Math.max(0, Math.min(len, this.cursorPos + delta));
  }

  moveWordLeft() {
    const arr = Array.from(this.shellInput);
    const isSpace = (ch) => ch === undefined || /\s/.test(ch);
    let i = this.cursorPos;
    while (i > 0 && isSpace(arr[i - 1])) i--; // skip whitespace before cursor
    while (i > 0 && !isSpace(arr[i - 1])) i--; // skip the word itself
    this.cursorPos = i;
  }

  moveWordRight() {
    const arr = Array.from(this.shellInput);
    const isSpace = (ch) => ch === undefined || /\s/.test(ch);
    const n = arr.length;
    let i = this.cursorPos;
    while (i < n && isSpace(arr[i])) i++; // skip whitespace after cursor
    while (i < n && !isSpace(arr[i])) i++; // skip the word itself
    this.cursorPos = i;
  }

  historyPrev() {
    if (this.shellHistory.length === 0) return;
    if (this.historyIdx === null) {
      this.shellDraft = this.shellInput; // stash the in-progress line
      this.historyIdx = this.shellHistory.length - 1;
    } else if (this.historyIdx > 0) {
      this.historyIdx--;
    } else {
      return; // already at the oldest entry
    }
    this.setInput(this.shellHistory[this.historyIdx]);
  }

  historyNext() {
    if (this.historyIdx === null) return; // not browsing history
    if (this.historyIdx < this.shellHistory.length - 1) {
      this.historyIdx++;
      this.setInput(this.shellHistory[this.historyIdx]);
    } else {
      this.historyIdx = null; // past the newest entry → restore the draft
      this.setInput(this.shellDraft);
    }
  }

  renderShell(screenEl) {
    const rows = [];
    for (const line of this.shellLines) {
      if (line.kind === "cmd") {
        rows.push(
          `<div class="sim-row">${this.promptHtml}${this.escapeHtml(line.text)}</div>`,
        );
      } else {
        rows.push(
          `<div class="sim-row sim-shell-out">${this.escapeHtml(line.text)}</div>`,
        );
      }
    }

    // Current input line with a blinking block cursor over the char at cursorPos.
    const arr = Array.from(this.shellInput);
    const before = this.escapeHtml(arr.slice(0, this.cursorPos).join(""));
    const underChar = arr[this.cursorPos];
    const under = underChar ? this.escapeHtml(underChar) : " ";
    const after = this.escapeHtml(arr.slice(this.cursorPos + 1).join(""));
    rows.push(
      `<div class="sim-row">${this.promptHtml}${before}` +
        `<span class="sim-shell-cursor">${under}</span>${after}</div>`,
    );

    // Keep only the last N rows so the active prompt is always visible.
    const visible = rows.slice(-this.maxShellRows);
    screenEl.innerHTML = visible.join("");
  }

  // Render recent shell lines + current input as the inline TUI header.
  renderShellContext() {
    const maxContext = 3;
    const recent = this.shellLines.slice(-maxContext);
    const rows = [];
    for (const line of recent) {
      if (line.kind === "cmd") {
        rows.push(`<div class="sim-row">${this.promptHtml}${this.escapeHtml(line.text)}</div>`);
      } else {
        rows.push(`<div class="sim-row sim-shell-out">${this.escapeHtml(line.text)}</div>`);
      }
    }
    // Current input (no cursor — cursor is now in the search bar below)
    rows.push(`<div class="sim-row">${this.promptHtml}${this.escapeHtml(this.shellInput)}</div>`);
    return rows.join("");
  }

  parseEchoArgs(args) {
    const trimmed = args.trim();
    // Strip one matching pair of surrounding quotes, like a real shell would.
    if (trimmed.length >= 2) {
      const q = trimmed[0];
      if ((q === '"' || q === "'") && trimmed[trimmed.length - 1] === q) {
        return trimmed.slice(1, -1);
      }
    }
    return args;
  }

  completeWord(word) {
    const lastSlash = word.lastIndexOf("/");
    let dirNode, prefix, pathPrefix;
    if (lastSlash === -1) {
      dirNode = this.cwdNode();
      prefix = word;
      pathPrefix = "";
    } else {
      const dirStr = lastSlash === 0 ? "/" : word.slice(0, lastSlash);
      prefix = word.slice(lastSlash + 1);
      pathPrefix = word.slice(0, lastSlash + 1);
      const r = dirStr === "/" ? { node: this.fsRoot } : this.resolvePath(dirStr);
      dirNode = (r && r.node.type === "dir") ? r.node : null;
    }
    if (!dirNode) return null;
    const showHidden = prefix.startsWith(".");
    const hits = Object.entries(dirNode.children)
      .filter(([n]) => n.startsWith(prefix) && (showHidden || !n.startsWith(".")))
      .sort(([a], [b]) => a.localeCompare(b));
    if (hits.length === 0) return null;
    const [name, node] = hits[0];
    return pathPrefix + name + (node.type === "dir" ? "/" : "");
  }

  handleTabComplete() {
    const arr = Array.from(this.shellInput);
    let wordStart = this.cursorPos;
    while (wordStart > 0 && arr[wordStart - 1] !== " ") wordStart--;
    const word = arr.slice(wordStart, this.cursorPos).join("");
    const completed = this.completeWord(word);
    if (completed === null) return;
    const before = arr.slice(0, wordStart).join("");
    const after  = arr.slice(this.cursorPos).join("");
    this.shellInput = before + completed + after;
    this.cursorPos = wordStart + Array.from(completed).length;
    this.render();
  }

  expandVars(text) {
    return text.replace(/\$([A-Z_][A-Z0-9_]*)/g, (_, name) => this.fakeEnv[name] ?? "");
  }

  executeShell() {
    const raw = this.shellInput;
    this.shellLines.push({ kind: "cmd", text: raw });

    // Record non-empty commands in history (skip consecutive duplicates).
    if (
      raw.trim() !== "" &&
      this.shellHistory[this.shellHistory.length - 1] !== raw
    ) {
      this.shellHistory.push(raw);
    }
    this.historyIdx = null;
    this.shellDraft = "";
    this.setInput("");

    const trimmed = raw.trim();
    if (trimmed === "") {
      this.render();
      return;
    }

    const sp = trimmed.indexOf(" ");
    let cmd = sp === -1 ? trimmed : trimmed.slice(0, sp);
    let args = sp === -1 ? "" : trimmed.slice(sp + 1);
    let isSudo = false;
    if (cmd === "sudo") {
      isSudo = true;
      const sp2 = args.indexOf(" ");
      cmd = sp2 === -1 ? args : args.slice(0, sp2);
      args = sp2 === -1 ? "" : args.slice(sp2 + 1);
    }

    switch (cmd) {
      case "echo":
        this.shellLines.push({ kind: "out", text: this.expandVars(this.parseEchoArgs(args)) });
        break;
      case "clear":
        this.shellLines = [];
        break;
      case "pwd":
        this.shellLines.push({ kind: "out", text: "/" + this.cwd.join("/") });
        break;
      case "cd": {
        const target = args.trim();
        if (!target || target === "~") {
          this.cwd = ["home", "you"];
          this.fakeEnv.PWD = "/home/you";
          break;
        }
        const cdResult = this.resolvePath(target);
        if (!cdResult) {
          this.shellLines.push({ kind: "out", text: `cd: no such file or directory: ${target}` });
          break;
        }
        if (cdResult.node.type !== "dir") {
          this.shellLines.push({ kind: "out", text: `cd: not a directory: ${target}` });
          break;
        }
        this.cwd = cdResult.components;
        this.fakeEnv.PWD = "/" + this.cwd.join("/");
        break;
      }
      case "env":
        for (const [k, v] of Object.entries(this.fakeEnv)) {
          this.shellLines.push({ kind: "out", text: `${k}=${v}` });
        }
        break;
      case "neofetch": {
        const lines = [
          `you@emojig 🔍`,
          `──────────────────────────────`,
          `OS:       EmojiOS 6.9 🐧`,
          `Host:     TerminalBook Pro`,
          `Kernel:   6.9.0-emojig`,
          `Shell:    zsh 5.9`,
          `Terminal: emojig-tui`,
          `CPU:      EmojiCore™ @ 4.2 GHz`,
          `Memory:   420 MiB / 6969 MiB 🧠`,
          `Uptime:   42 mins ⏱️`,
          `Colors:   🟥🟧🟨🟩🟦🟪⬛⬜`,
        ];
        for (const l of lines) this.shellLines.push({ kind: "out", text: l });
        break;
      }
      case "ls":
      case "ll": {
        const longFmt    = cmd === "ll" || args.includes("-l");
        const showHidden = cmd === "ll" || args.includes("-a");
        const pathArg    = args.trim().split(/\s+/).filter(a => !a.startsWith("-"))[0] ?? ".";
        const lsResult   = this.resolvePath(pathArg);
        if (!lsResult) {
          this.shellLines.push({ kind: "out", text: `ls: cannot access '${pathArg}': No such file or directory` });
          break;
        }
        let entries;
        if (lsResult.node.type === "file") {
          entries = [{ name: pathArg.split("/").at(-1), node: lsResult.node }];
        } else {
          entries = Object.entries(lsResult.node.children)
            .filter(([n]) => showHidden || !n.startsWith("."))
            .map(([n, nd]) => ({ name: n, node: nd }));
        }
        if (longFmt) {
          this.shellLines.push({ kind: "out", text: `total ${entries.length * 8}` });
          for (const { name, node } of entries) {
            const ow = node.owner.padEnd(4);
            const sz = String(node.size).padStart(4);
            this.shellLines.push({ kind: "out", text: `${node.perms} 1 ${ow} ${ow} ${sz} ${node.date} ${name}` });
          }
        } else {
          const names = entries.map(({ name, node }) => node.type === "dir" ? name + "/" : name);
          if (names.length > 0) this.shellLines.push({ kind: "out", text: names.join("  ") });
        }
        break;
      }
      case "ps":
        this.shellLines.push({ kind: "out", text: "  PID TTY          TIME CMD" });
        this.shellLines.push({ kind: "out", text: " 1234 pts/0    00:00:02 zsh" });
        this.shellLines.push({ kind: "out", text: " 5678 pts/0    00:00:00 emojig" });
        this.shellLines.push({ kind: "out", text: " 9012 pts/0    00:00:00 ps" });
        break;
      case "touch": {
        const touchTargets = args.trim().split(/\s+/).filter(Boolean);
        const now = new Date();
        const MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
        const tDate = `${MON[now.getMonth()]} ${String(now.getDate()).padStart(2," ")} ${String(now.getHours()).padStart(2,"0")}:${String(now.getMinutes()).padStart(2,"0")}`;
        for (const t of touchTargets) {
          const parts  = t.split("/");
          const tName  = parts.pop();
          const dirStr = parts.length ? parts.join("/") : ".";
          const dr = this.resolvePath(dirStr);
          if (!dr || dr.node.type !== "dir") {
            this.shellLines.push({ kind: "out", text: `touch: cannot touch '${t}': No such file or directory` });
            continue;
          }
          if (!dr.node.children[tName]) {
            dr.node.children[tName] = { type: "file", perms: "-rw-r--r--", size: "   0", date: tDate, owner: "you" };
          }
        }
        break;
      }
      case "rm": {
        const rmParts   = args.trim().split(/\s+/);
        const rmFlags   = rmParts.filter(p => p.startsWith("-")).join("");
        const rmTargets = rmParts.filter(p => !p.startsWith("-"));
        const hasR      = rmFlags.includes("r");

        rmLoop: for (const target of rmTargets) {
          if (!target) continue;
          const rr = this.resolvePath(target);
          if (!rr) {
            this.shellLines.push({ kind: "out", text: `rm: cannot remove '${target}': No such file or directory` });
            continue;
          }
          const { node, parent, name } = rr;

          if (node.type === "dir" && !hasR) {
            this.shellLines.push({ kind: "out", text: `rm: cannot remove '${target}': Is a directory` });
            continue;
          }
          if (node.owner === "root" && !isSudo) {
            this.shellLines.push({ kind: "out", text: `rm: cannot remove '${target}': Permission denied` });
            if (rr.components.length === 0)
              this.shellLines.push({ kind: "out", text: "hint: try sudo rm -rf /" });
            continue;
          }
          // Nuclear: sudo rm -r /
          if (rr.components.length === 0 && hasR) {
            const boom = [
              "rm: descending into '/'…",
              "rm: removing '/usr'… 💥",
              "rm: removing '/home'… 💥",
              "rm: removing '/etc'… 💥",
              "rm: removing '/var'… 💥",
              "rm: removing '/tmp'… 💥",
              "rm: this is fine 🔥",
              "💥💥💥",
            ];
            boom.forEach((msg, i) => {
              setTimeout(() => {
                this.shellLines.push({ kind: "out", text: msg });
                this.render();
                if (i === boom.length - 1) {
                  setTimeout(() => {
                    document.body.innerHTML =
                      '<div style="display:flex;align-items:center;justify-content:center;' +
                      'height:100vh;font-size:50vw;background:#000;margin:0;cursor:pointer" ' +
                      'title="refresh to recover" onclick="location.reload()">💀</div>';
                  }, 600);
                }
              }, i * 350);
            });
            break rmLoop;
          }
          if (parent) delete parent.children[name];
        }
        break;
      }
      case "help":
        this.shellLines.push({
          kind: "out",
          text: "commands: echo $VAR, ls/ll, cd, pwd, ps, env, touch, rm, git, neofetch, clear, help",
        });
        this.shellLines.push({
          kind: "out",
          text: "press Ctrl+E to launch the emoji picker",
        });
        break;
      case "git": {
        const sub = args.trim().split(/\s+/)[0];
        if (sub === "status") {
          this.shellLines.push({ kind: "out", text: "On branch main" });
          this.shellLines.push({ kind: "out", text: "Changes to be committed:" });
          this.shellLines.push({ kind: "out", text: "  modified: src/main.zig" });
        } else if (sub === "add") {
          // silent like the real thing
        } else if (sub === "commit") {
          const m = args.match(/-m\s+['"](.+)['"]/s);
          const msg = m ? m[1] : args.replace(/^commit\s*/, "").trim() || "update";
          const hash = Math.random().toString(16).slice(2, 9);
          this.shellLines.push({ kind: "out", text: `[main ${hash}] ${msg}` });
          this.shellLines.push({ kind: "out", text: " 3 files changed, 42 insertions(+), 7 deletions(-)" });
        } else {
          this.shellLines.push({ kind: "out", text: `git: '${sub}' not supported in demo` });
        }
        break;
      }
      default:
        this.shellLines.push({
          kind: "out",
          text: `zsh: command not found: ${cmd}`,
        });
    }
    this.render();
  }

  openTui() {
    this.mode = "tui";
    this.query = "";
    this.selectedIdx = null;
    const inputEl = document.getElementById("sim-query-input");
    if (inputEl) inputEl.value = "";
    this.updateThemeClass();
    this.render();
  }

  closeTui() {
    // Cancel the picker (Esc / Ctrl+C) and return to the shell unchanged.
    this.mode = "shell";
    this.query = "";
    this.selectedIdx = null;
    const inputEl = document.getElementById("sim-query-input");
    if (inputEl) { inputEl.value = ""; inputEl.blur(); }
    this.render();
  }

  // --- Action Methods ---

  cycleTheme() {
    if (this.theme === "dark") {
      this.theme = "light";
    } else if (this.theme === "light") {
      this.theme = "system";
    } else {
      this.theme = "dark";
    }

    // Sync visual theme selector in options if present
    const optSelector = document.getElementById("sim-opt-theme");
    if (optSelector) {
      optSelector.value = this.theme;
    }

    this.updateThemeClass();
    this.render();
  }

  selectEmoji(emoji) {
    // Insert the picked emoji into the command line and return to the shell,
    // mirroring the real Ctrl+E widget. Also copy it for good measure.
    const formatted = this.formatEmoji(emoji);
    this.insertAtCursor(formatted); // drop it in at the cursor, like the real widget
    this.mode = "shell";
    this.query = "";
    this.selectedIdx = null;
    const inputEl = document.getElementById("sim-query-input");
    if (inputEl) { inputEl.value = ""; inputEl.blur(); }
    this.updateThemeClass();
    this.render();

    if (navigator.clipboard) {
      navigator.clipboard.writeText(formatted).catch(() => {});
    }
    this.showToast(formatted);
  }

  showToast(emoji) {
    // Remove existing toast if present
    const oldToast = document.querySelector(".sim-toast");
    if (oldToast) oldToast.remove();

    const toast = document.createElement("div");
    toast.className = "sim-toast";
    toast.innerHTML = `<span class="sim-toast-icon">✓</span> Inserted ${emoji} into the command line!`;
    document.body.appendChild(toast);

    // Trigger reflow
    toast.offsetHeight;
    toast.classList.add("show");

    setTimeout(() => {
      toast.classList.remove("show");
      setTimeout(() => toast.remove(), 300);
    }, 2000);
  }

  resetShell() {
    this.query = "";
    this.selectedIdx = null;
    this.seedShell();

    const inputEl = document.getElementById("sim-query-input");
    if (inputEl) inputEl.value = "";

    this.openTui();
  }

  // --- Keyboard Navigation ---

  handleKeydown(e) {
    // If focus is not active, ignore keydown
    if (!this.isFocused) return;

    if (this.mode === "shell") {
      this.handleShellKey(e);
      return;
    }
    this.handleTuiKey(e);
  }

  handleShellKey(e) {
    // Let the panel's search input drive the picker instead of the shell line.
    if (e.target && e.target.id === "sim-query-input") return;

    if (e.ctrlKey) {
      const k = e.key.toLowerCase();
      if (k === "arrowleft") {
        e.preventDefault();
        this.moveWordLeft(); // jump to start of previous word
        this.render();
      } else if (k === "arrowright") {
        e.preventDefault();
        this.moveWordRight(); // jump past the next word
        this.render();
      } else if (k === "e") {
        e.preventDefault();
        this.openTui(); // launch the emojig picker
      } else if (k === "c") {
        e.preventDefault();
        this.shellLines.push({ kind: "cmd", text: this.shellInput + "^C" });
        this.historyIdx = null;
        this.setInput("");
        this.render();
      } else if (k === "k") {
        e.preventDefault();
        this.shellLines = [];
        this.render();
      } else if (k === "a") {
        e.preventDefault();
        this.cursorPos = 0; // start of line
        this.render();
      }
      return;
    }
    if (e.altKey || e.metaKey) return;

    if (e.key === "Tab") {
      e.preventDefault();
      this.handleTabComplete();
    } else if (e.key === "Enter") {
      e.preventDefault();
      this.executeShell();
    } else if (e.key === "Backspace") {
      e.preventDefault();
      this.deleteBeforeCursor();
      this.render();
    } else if (e.key === "Delete") {
      e.preventDefault();
      this.deleteAtCursor();
      this.render();
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      this.moveCursor(-1);
      this.render();
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      this.moveCursor(1);
      this.render();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      this.historyPrev();
      this.render();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      this.historyNext();
      this.render();
    } else if (e.key === "Home") {
      e.preventDefault();
      this.cursorPos = 0;
      this.render();
    } else if (e.key === "End") {
      e.preventDefault();
      this.cursorPos = Array.from(this.shellInput).length;
      this.render();
    } else if (e.key.length === 1) {
      e.preventDefault();
      this.insertAtCursor(e.key);
      this.render();
    }
  }

  handleTuiKey(e) {
    // Skip modifiers
    if (e.ctrlKey || e.altKey || e.metaKey) {
      // Ctrl+C cancels the picker and returns to the shell
      if (e.ctrlKey && e.key.toLowerCase() === "c") {
        e.preventDefault();
        this.closeTui();
      }
      return;
    }

    const matches = this.getFilteredMatches();
    const topCount = Math.min(this.cols * this.rows, matches.length);

    // Keyboard navigation should win over hover until the mouse actually moves.
    if (
      e.key === "ArrowUp" ||
      e.key === "ArrowDown" ||
      e.key === "ArrowLeft" ||
      e.key === "ArrowRight"
    ) {
      this.suppressHover = true;
    }

    if (e.key === "ArrowUp") {
      e.preventDefault();
      if (this.selectedIdx === null) {
        if (topCount > 0) this.selectedIdx = 0;
      } else {
        let sel = this.selectedIdx;
        if (sel >= this.cols) {
          sel -= this.cols;
        } else {
          const target = sel + (this.rows - 1) * this.cols;
          sel = target < topCount ? target : topCount - 1;
        }
        this.selectedIdx = sel;
      }
      this.render();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      if (this.selectedIdx === null) {
        if (topCount > 0) this.selectedIdx = 0;
      } else {
        let sel = this.selectedIdx;
        const target = sel + this.cols;
        sel = target < topCount ? target : sel % this.cols;
        this.selectedIdx = sel;
      }
      this.render();
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      if (this.selectedIdx === null) {
        if (topCount > 0) this.selectedIdx = 0;
      } else {
        let sel = this.selectedIdx;
        sel = sel > 0 ? sel - 1 : topCount - 1;
        this.selectedIdx = sel;
      }
      this.render();
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      if (this.selectedIdx === null) {
        if (topCount > 0) this.selectedIdx = 0;
      } else {
        let sel = this.selectedIdx;
        sel = sel < topCount - 1 ? sel + 1 : 0;
        this.selectedIdx = sel;
      }
      this.render();
    } else if (e.key === "Backspace") {
      if (e.target.id === "sim-query-input") {
        // Let the browser handle backspace natively in the input,
        // the 'input' event listener will sync the state.
        return;
      }
      e.preventDefault();
      if (this.query.length > 0) {
        this.query = this.query.slice(0, -1);
        this.selectedIdx = topCount > 0 ? 0 : null;
        // Sync input element
        const inputEl = document.getElementById("sim-query-input");
        if (inputEl) inputEl.value = this.query;
        this.render();
      }
    } else if (e.key === "Escape") {
      e.preventDefault();
      this.closeTui(); // cancel picker, back to the shell prompt
    } else if (e.key === "Tab") {
      e.preventDefault();
      this.cycleTheme();
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (this.selectedIdx !== null && matches[this.selectedIdx]) {
        this.selectEmoji(matches[this.selectedIdx].emoji);
      }
    } else if (e.key.length === 1) {
      if (e.target.id === "sim-query-input") {
        // Let the browser handle text input natively in the input,
        // the 'input' event listener will sync the state.
        return;
      }
      this.query += e.key;
      // Set selection to index 0 on first typed char if not set
      this.selectedIdx = 0;
      // Sync input element
      const inputEl = document.getElementById("sim-query-input");
      if (inputEl) inputEl.value = this.query;
      this.render();
    }
  }
}

// Initialize on page load
document.addEventListener("DOMContentLoaded", () => {
  const sim = new EmojigSimulator();
  window.emojigSimulator = sim;

  const screenEl = document.getElementById("sim-screen");
  const inputEl = document.getElementById("sim-query-input");
  const borderOpt = document.getElementById("sim-opt-border");
  const safeOpt = document.getElementById("sim-opt-safe");
  const themeOpt = document.getElementById("sim-opt-theme");
  const focusBadge = document.getElementById("sim-focus-badge");

  // Seed the shell and open the picker inline — demonstrating the inline TUI USP.
  sim.seedShell();
  sim.openTui();

  // Keyboard stays inactive until the user clicks the terminal (matching the
  // focus badge). We capture keys at the document level rather than via a
  // focused <input>, so activating on load would otherwise swallow page-wide
  // keystrokes (e.g. Space to scroll) before the user touches the demo.

  // Event binding: Terminal screen focus
  screenEl.addEventListener("click", () => {
    sim.isFocused = true;
    sim.updateThemeClass();
    updateFocusBadge(true);
    // In picker (TUI) mode, hand focus to the panel input so touch devices get
    // a soft keyboard for fuzzy search. In shell mode keep DOM focus off the
    // input so keystrokes flow to the command line.
    if (sim.mode === "tui" && inputEl) inputEl.focus();
  });

  document.addEventListener("click", (e) => {
    const insideTerminal = screenEl.contains(e.target);
    const insidePanel = document
      .getElementById("sim-panel")
      ?.contains(e.target);
    if (!insideTerminal && !insidePanel) {
      sim.isFocused = false;
      sim.updateThemeClass();
      updateFocusBadge(false);
    }
  });

  function updateFocusBadge(focused) {
    if (!focusBadge) return;
    if (focused) {
      focusBadge.className = "sim-focus-badge active";
      focusBadge.innerHTML = `<span class="sim-dot-indicator"></span> Focused (Keyboard Active)`;
    } else {
      focusBadge.className = "sim-focus-badge inactive";
      focusBadge.innerHTML = `<span class="sim-dot-indicator"></span> Click here to focus keys`;
    }
  }

  // Sync search input box — only drives the query when the picker is already open.
  if (inputEl) {
    inputEl.addEventListener("input", (e) => {
      if (sim.mode !== "tui") return;
      sim.query = e.target.value;
      // Reset selection to first match
      const matches = sim.getFilteredMatches();
      sim.selectedIdx = matches.length > 0 ? 0 : null;
      sim.updateThemeClass();
      sim.render();
    });
    inputEl.addEventListener("focus", () => {
      sim.isFocused = true;
      sim.updateThemeClass();
      updateFocusBadge(true);
    });
  }

  // Setup Options Toggle
  if (borderOpt) {
    borderOpt.addEventListener("change", (e) => {
      sim.showBorder = e.target.checked;
      sim.render();
    });
  }

  if (safeOpt) {
    safeOpt.addEventListener("change", (e) => {
      sim.safeMode = e.target.checked;
      sim.render();
    });
  }

  if (themeOpt) {
    themeOpt.addEventListener("change", (e) => {
      sim.theme = e.target.value;
      sim.updateThemeClass();
      sim.render();
    });
  }

  // Bind physical keydown events
  document.addEventListener("keydown", (e) => {
    // If typing in other inputs not related to simulator, ignore
    if (e.target.tagName === "INPUT" && e.target !== inputEl) {
      return;
    }
    sim.handleKeydown(e);
  });

  // A real pointer movement re-enables hover selection in the picker grid.
  document.addEventListener("mousemove", () => {
    if (sim.suppressHover) sim.suppressHover = false;
  });

  // Mobile DPAD Controllers
  const setupDpad = (btnClass, action) => {
    const btn = document.querySelector(`.sim-dpad-btn.${btnClass}`);
    if (btn) {
      btn.addEventListener("click", () => {
        sim.isFocused = true;
        updateFocusBadge(true);
        action();
      });
    }
  };

  setupDpad("up", () => {
    if (sim.mode === "shell") {
      sim.historyPrev();
      sim.render();
      return;
    }
    const matches = sim.getFilteredMatches();
    const topCount = Math.min(this.cols * this.rows, matches.length);
    if (sim.selectedIdx === null) {
      if (topCount > 0) sim.selectedIdx = 0;
    } else {
      let sel = sim.selectedIdx;
      if (sel >= sim.cols) {
        sel -= sim.cols;
      } else {
        const target = sel + (sim.rows - 1) * sim.cols;
        sel = target < topCount ? target : topCount - 1;
      }
      sim.selectedIdx = sel;
    }
    sim.render();
  });

  setupDpad("down", () => {
    if (sim.mode === "shell") {
      sim.historyNext();
      sim.render();
      return;
    }
    const matches = sim.getFilteredMatches();
    const topCount = Math.min(this.cols * this.rows, matches.length);
    if (sim.selectedIdx === null) {
      if (topCount > 0) sim.selectedIdx = 0;
    } else {
      let sel = sim.selectedIdx;
      const target = sel + sim.cols;
      sel = target < topCount ? target : sel % sim.cols;
      sim.selectedIdx = sel;
    }
    sim.render();
  });

  setupDpad("left", () => {
    if (sim.mode === "shell") {
      sim.moveCursor(-1);
      sim.render();
      return;
    }
    const matches = sim.getFilteredMatches();
    const topCount = Math.min(this.cols * this.rows, matches.length);
    if (sim.selectedIdx === null) {
      if (topCount > 0) sim.selectedIdx = 0;
    } else {
      let sel = sim.selectedIdx;
      sel = sel > 0 ? sel - 1 : topCount - 1;
      sim.selectedIdx = sel;
    }
    sim.render();
  });

  setupDpad("right", () => {
    if (sim.mode === "shell") {
      sim.moveCursor(1);
      sim.render();
      return;
    }
    const matches = sim.getFilteredMatches();
    const topCount = Math.min(this.cols * this.rows, matches.length);
    if (sim.selectedIdx === null) {
      if (topCount > 0) sim.selectedIdx = 0;
    } else {
      let sel = sim.selectedIdx;
      sel = sel < topCount - 1 ? sel + 1 : 0;
      sim.selectedIdx = sel;
    }
    sim.render();
  });

  setupDpad("ok", () => {
    if (sim.mode === "shell") {
      sim.executeShell(); // run the current command line
      return;
    }
    const matches = sim.getFilteredMatches();
    if (sim.selectedIdx !== null && matches[sim.selectedIdx]) {
      sim.selectEmoji(matches[sim.selectedIdx].emoji);
    }
  });
});
