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
    const spec  = (typeof jsdemoSpec !== "undefined") ? jsdemoSpec : null;
    this.webSpec = (typeof EMOJIG_WEB_SPEC !== "undefined") ? EMOJIG_WEB_SPEC : null;
    this.shellUser     = spec?.user   ?? "you";
    this.shellHost     = spec?.host   ?? "emojig";
    this.promptTpl     = spec?.prompt ?? "{user@host}:{cwd}{sym} ";
    this.cwd    = spec?.cwd
      ? spec.cwd.replace(/^\//, "").split("/").filter(Boolean)
      : ["home", "you", "projects", "emojig"];
    this.fsRoot = this._makeFs(spec?.entries ?? null, this.cwd);
    this.fakeEnv = Object.assign({
      HOME:         "/home/" + this.shellUser,
      USER:         this.shellUser,
      SHELL:        "/bin/zsh",
      TERM:         "xterm-256color",
      EDITOR:       "emojig",
      PATH:         "/home/you/.local/bin:/usr/local/bin:/usr/bin:/bin",
      EMOJIG_THEME: "dark",
      LANG:         "en_US.UTF-8",
      PWD:          "/" + (spec?.cwd ?? "/home/you/projects/emojig").replace(/^\//, ""),
      GREETING:     "Hello 👋",
    }, spec?.env ?? {});

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

    this.cols = this.webSpec?.layout?.cols ?? 6;
    this.rows = this.webSpec?.layout?.rows ?? 4;
    this.contentWidth = this.webSpec?.layout?.width ?? (this.cols * 4 + 1);
    this.maxResults = this.webSpec?.layout?.max_results ?? (5 * 16 * 16);

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

  // matchTerm scores a term with plural/stem fallbacks plus synonym
  // matching (max score across all attempts) — mirrors src/root.zig and
  // internal/emoji/fuzzy.go. The synonym map is emitted into emojis.js
  // by scripts/pack_emojis from spec/synonyms.json.
  matchTerm(term, target) {
    if (term.length === 0) return 0;

    let best = this.matchTermSelf(term, target);

    const synonyms =
      typeof EMOJI_SYNONYMS !== "undefined" ? EMOJI_SYNONYMS : null;
    if (synonyms) {
      const synList = synonyms[term.toLowerCase()];
      if (synList) {
        for (const syn of synList) {
          const s = this.matchTermDirect(syn, target);
          if (s !== null && (best === null || s > best)) best = s;
        }
      }
    }

    return best;
  }

  // matchTermSelf: direct match with plural/stem/trailing-e fallbacks.
  matchTermSelf(term, target) {
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

  rangeFilter(name, fallbackMin, fallbackMax, fallbackPenalty) {
    const spec = this.webSpec?.filters?.[name] ?? null;
    return {
      min: spec?.min_codepoint ?? fallbackMin,
      max: spec?.max_codepoint ?? fallbackMax,
      penalty: spec?.penalty ?? fallbackPenalty,
    };
  }

  // Box-drawing / block-element glyphs generated from spec/boxart.json.
  isBoxArt(emoji) {
    if (!emoji) return false;
    const range = this.rangeFilter("box_art", 0x2500, 0x259f, 150);
    const cp = emoji.codePointAt(0);
    return cp >= range.min && cp <= range.max;
  }

  // Braille pattern glyphs generated from spec/braille.json.
  isBraille(emoji) {
    if (!emoji) return false;
    const range = this.rangeFilter("braille", 0x2800, 0x28ff, 150);
    const cp = emoji.codePointAt(0);
    return cp >= range.min && cp <= range.max;
  }

  // Number of raised dots (0-8) encoded by a Braille pattern codepoint.
  brailleDotCount(emoji) {
    if (!this.isBraille(emoji)) return 0;
    const cp = emoji.codePointAt(0);
    let bits = cp - 0x2800;
    let count = 0;
    while (bits) {
      count += bits & 1;
      bits >>= 1;
    }
    return count;
  }

  getEmojiWidth(emoji) {
    if (!emoji) return 0;
    // VS15 explicitly requests text presentation: single-width.
    if (emoji.includes("\ufe0e")) {
      return 1;
    }
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

  isWordBoundary(ch) {
    return ch === undefined || ch === " " || ch === "\t" || ch === "-" || ch === "_";
  }

  isWordInSearch(search, word) {
    if (!search || !word) return false;
    const hay = search.toLowerCase();
    const needle = word.toLowerCase();
    let idx = hay.indexOf(needle);
    while (idx !== -1) {
      const before = idx === 0 || this.isWordBoundary(hay[idx - 1]);
      const afterIdx = idx + needle.length;
      const after = afterIdx >= hay.length || this.isWordBoundary(hay[afterIdx]);
      if (before && after) return true;
      idx = hay.indexOf(needle, idx + 1);
    }
    return false;
  }

  findCategorySpecMatch(term, allowPrefix) {
    const categories = this.webSpec?.categories ?? [];
    if (!term) return null;
    const q = term.toLowerCase();
    for (const cat of categories) {
      const name = (cat.name ?? "").toLowerCase();
      const short = (cat.short ?? "").toLowerCase();
      if (name === q || short === q) {
        return { spec: cat, isSynonym: !cat.switcher };
      }
    }
    if (allowPrefix) {
      for (const cat of categories) {
        const name = (cat.name ?? "").toLowerCase();
        const short = (cat.short ?? "").toLowerCase();
        if (name.startsWith(q) || short.startsWith(q)) {
          return { spec: cat, isSynonym: !cat.switcher };
        }
      }
    }
    for (const cat of categories) {
      for (const syn of cat.synonyms ?? []) {
        if (syn.toLowerCase() === q) {
          return { spec: cat, isSynonym: true };
        }
      }
    }
    return null;
  }

  findCategorySpec(term) {
    return this.findCategorySpecMatch(term, true)?.spec ?? null;
  }

  emojiMatchesCategory(search, cat) {
    if (!cat) return false;
    if (this.isWordInSearch(search, cat.name)) return true;
    if (this.isWordInSearch(search, cat.short)) return true;
    for (const syn of cat.synonyms ?? []) {
      if (this.isWordInSearch(search, syn)) return true;
    }
    return false;
  }

  parseSearchOptions() {
    let actualQuery = this.query;
    let filterWidth = null;
    let filterBox = false;
    let filterBraille = false;
    let brailleDotFilter = null;
    let filterCategory = null;

    if (this.query.length >= 3 &&
        (this.query[0] === 'b' || this.query[0] === 'B') &&
        (this.query[1] === 'r' || this.query[1] === 'R') && this.query[2] === ':') {
      filterBraille = true;
      const rest = this.query.slice(3);
      let digits = rest.endsWith(':') ? rest.slice(0, -1) : rest;
      actualQuery = "";
      if (digits.length > 0 && /^\d+$/.test(digits)) {
        brailleDotFilter = parseInt(digits, 10);
      } else {
        actualQuery = rest;
      }
    } else if (this.query.length >= 2) {
      if ((this.query[0] === 'e' || this.query[0] === 'E') && this.query[1] === ':') {
        actualQuery = this.query.slice(2);
        filterWidth = 2;
      } else if ((this.query[0] === 't' || this.query[0] === 'T') && this.query[1] === ':') {
        actualQuery = this.query.slice(2);
        filterWidth = 1;
      } else if ((this.query[0] === 'b' || this.query[0] === 'B') && this.query[1] === ':') {
        actualQuery = this.query.slice(2);
        filterBox = true;
      }
    }

    if (actualQuery.startsWith("c:") || actualQuery.startsWith("C:")) {
      const afterC = actualQuery.slice(2);
      const spaceIdx = afterC.indexOf(" ");
      if (spaceIdx === -1) {
        filterCategory = afterC;
        actualQuery = "";
      } else {
        filterCategory = afterC.slice(0, spaceIdx);
        actualQuery = afterC.slice(spaceIdx + 1);
      }
    }

    if (filterCategory === null) {
      const trimmed = actualQuery.trimStart();
      const leading = actualQuery.length - trimmed.length;
      const spaceIdx = trimmed.indexOf(" ");
      const firstWord = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
      const match = this.findCategorySpecMatch(firstWord, false);
      if (match) {
        filterCategory = firstWord;
        if (!match.isSynonym) {
          actualQuery = spaceIdx === -1 ? "" : actualQuery.slice(leading + spaceIdx + 1);
        }
      }
    }

    return {
      actualQuery,
      filterWidth,
      filterBox,
      filterBraille,
      brailleDotFilter,
      filterCategory,
    };
  }

  getFilteredMatches() {
    if (typeof EMOJI_DB === "undefined") return [];
    const db = EMOJI_DB;
    const {
      actualQuery,
      filterWidth,
      filterBox,
      filterBraille,
      brailleDotFilter,
      filterCategory,
    } = this.parseSearchOptions();
    const categorySpec = filterCategory === null ? null : this.findCategorySpec(filterCategory);

    const braillePasses = (emoji) => {
      if (!filterBraille) return true;
      if (!this.isBraille(emoji)) return false;
      if (brailleDotFilter !== null && this.brailleDotCount(emoji) !== brailleDotFilter) return false;
      return true;
    };

    const categoryPasses = (item) => {
      if (filterCategory === null) return true;
      return this.emojiMatchesCategory(item[2], categorySpec);
    };

    if (actualQuery.trim() === "") {
      const filtered = [];
      for (let i = 0; i < db.length; i++) {
        const item = db[i];
        if (filterWidth !== null && this.getEmojiWidth(item[0]) !== filterWidth) {
          continue;
        }
        if (filterBox && !this.isBoxArt(item[0])) {
          continue;
        }
        if (!braillePasses(item[0])) {
          continue;
        }
        if (!categoryPasses(item)) {
          continue;
        }
        filtered.push({
          emoji: item[0],
          description: item[1],
          originalIdx: i,
          score: 0,
        });
      }
      if (filterBraille) {
        filtered.sort((a, b) => this.brailleDotCount(a.emoji) - this.brailleDotCount(b.emoji));
      }
      return filtered.slice(0, this.maxResults);
    }

    const matches = [];
    for (let i = 0; i < db.length; i++) {
      const item = db[i];
      if (filterWidth !== null && this.getEmojiWidth(item[0]) !== filterWidth) {
        continue;
      }
      if (filterBox && !this.isBoxArt(item[0])) {
        continue;
      }
      if (!braillePasses(item[0])) {
        continue;
      }
      if (!categoryPasses(item)) {
        continue;
      }
      let score = this.fuzzyMatch(actualQuery, item[2]);
      if (score !== null) {
        // Box art and Braille patterns rank below genuine emoji matches in
        // general searches; br: searches sort purely by ascending dot count.
        if (this.isBoxArt(item[0])) score -= this.rangeFilter("box_art", 0x2500, 0x259f, 150).penalty;
        if (this.isBraille(item[0])) score -= this.rangeFilter("braille", 0x2800, 0x28ff, 150).penalty;
        if (filterBraille) score = -this.brailleDotCount(item[0]);
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

  displayWidth(str) {
    let width = 0;
    for (const ch of [...str]) {
      width += (ch.codePointAt(0) > 0x1f000 || ch === "🔍") ? 2 : 1;
    }
    return width;
  }

  formatSpecLine(line) {
    const oscLink = /^\u001b]8;;([^\u001b]+)\u001b\\([^\u001b]+)\u001b]8;;\u001b\\$/;
    const match = line.match(oscLink);
    if (match) {
      return `<a class="sim-link" href="${this.escapeHtml(match[1])}">${this.escapeHtml(match[2])}</a>`;
    }
    return this.escapeHtml(line.replace(/\u001b\][^\u001b]*\u001b\\/g, ""));
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
    const visibleCells = this.cols * this.rows;
    const topCount = Math.min(visibleCells, totalMatches);
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
      const visualWidth = this.displayWidth(str);
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
    const searchPrompt = this.webSpec?.strings?.search_prompt ?? "🔍 ";
    const searchPlaceholder = this.webSpec?.strings?.search_placeholder ?? "search…";
    const queryText = this.query;
    const maxQueryCols = Math.max(1, this.contentWidth - this.displayWidth(searchPrompt) - 4);
    const displayQuery =
      queryText.length > maxQueryCols
        ? queryText.slice(0, maxQueryCols)
        : queryText;
    const padLen = Math.max(0, maxQueryCols - displayQuery.length);

    const themeIcon =
      this.theme === "dark" ? "🌙" : this.theme === "light" ? "🌞" : "🔆";

    const placeholderHtml =
      displayQuery.length === 0
        ? `<span class="sim-cursor">█</span><span class="sim-search-placeholder">${this.escapeHtml(searchPlaceholder)}</span><span>${" ".repeat(Math.max(0, padLen - this.displayWidth(searchPlaceholder)))}</span>`
        : `<span class="sim-search-query">${displayQuery}</span><span class="sim-cursor">█</span><span>${" ".repeat(Math.max(0, padLen - 1))}</span>`;
    html +=
      `<div class="sim-row sim-search">` +
      `<span class="sim-search-prompt">${this.escapeHtml(searchPrompt)}</span>` +
      placeholderHtml +
      `<span class="sim-theme-icon" id="sim-theme-toggle" title="Cycle Theme (Tab)"> ${themeIcon} </span>` +
      `</div>`;

    const isHelpMode = this.query.startsWith("?");

    if (isHelpMode) {
      const isMorePage = this.query.startsWith("??");
      const helpLines = isMorePage
        ? (this.webSpec?.strings?.help_lines_more ?? [])
        : (this.webSpec?.strings?.help_lines ?? []);
      for (let i = 0; i < this.rows + 3; i++) {
        let text = "";
        if (i < helpLines.length) {
          text = this.formatSpecLine(helpLines[i]);
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
              const left = this.webSpec?.strings?.cursor_left ?? "[";
              const right = this.webSpec?.strings?.cursor_right ?? "]";
              rowHtml += `<span class="sim-cell selected" data-idx="${idx}">${this.escapeHtml(left)}${formattedEmoji}${this.escapeHtml(right)}</span>`;
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
    const statusSpec = this.webSpec?.strings?.status_default ?? {};
    const statusTemplate = this.query.length === 0
      ? (this.contentWidth >= 32 ? statusSpec.on_view_wide : statusSpec.on_view)
      : (this.contentWidth >= 32 ? statusSpec.on_search_wide : statusSpec.on_search);
    const statusText = (statusTemplate ?? (this.query.length === 0 ? " ?:help  ↕↔|↵|Esc" : " {count}  ↕↔|↵|Esc"))
      .replace("{count}", String(totalMatches));
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
    const cwd  = this.cwdString();
    const subs = {
      "user@host": ["sim-shell-user", `${this.shellUser}@${this.shellHost}`],
      "user":      ["sim-shell-user", this.shellUser],
      "host":      ["sim-shell-user", this.shellHost],
      "cwd":       ["sim-shell-path", cwd],
      "sym":       ["sim-shell-sym",  "$"],
    };
    const clsOf = { user: "sim-shell-user", host: "sim-shell-user",
                    cwd:  "sim-shell-path",  path: "sim-shell-path",
                    sym:  "sim-shell-sym" };
    return this.promptTpl.split(/(\{[^}]+\})/).map(part => {
      const m = part.match(/^\{([^}]+)\}$/);
      if (m) {
        const key = m[1], col = key.indexOf(":");
        if (col !== -1) {
          const cls = clsOf[key.slice(0, col)] ?? "sim-shell-sym";
          return `<span class="${cls}">${this.escapeHtml(key.slice(col + 1))}</span>`;
        }
        const [cls, val] = subs[key] ?? ["sim-shell-sym", part];
        return `<span class="${cls}">${this.escapeHtml(val)}</span>`;
      }
      return part ? `<span class="sim-shell-sym">${this.escapeHtml(part)}</span>` : "";
    }).join("");
  }

  _makeFs(entries, cwdParts) {
    const F = (m) => ({ type: "file", perms: "-rw-r--r--", size: "   0", date: "Jun  9 12:00", owner: "you", ...m });
    const D = (children, m={}) => ({ type: "dir",  perms: "drwxr-xr-x", size: "4096", date: "Jun  9 12:00", owner: "you", children, ...m });
    const parts = cwdParts ?? ["home", "you", "projects", "emojig"];

    // Build the project dir — from spec entries if provided, else hardcoded fallback.
    const projectChildren = {};
    const specEntries = entries ?? [
      { path: "README.md",     size: "1.2K", date: "Jun  9 11:55" },
      { path: "Makefile",      size: " 567", date: "Jun  9 11:55" },
      { path: "emojig",        perms: "-rwxr-xr-x", size: " 42K", date: "Jun  9 12:30", owner: "root" },
      { path: "src/",          size: "  96", date: "Jun  9 10:00" },
      { path: "src/main.zig",  size: "8.1K", date: "Jun  9 12:00" },
      { path: "src/input.zig", size: "3.4K", date: "Jun  9 11:30" },
      { path: "notes.txt",     size: " 128", date: "Jun  9 09:15" },
      { path: ".secret",       perms: "-rw-------", size: "  42", date: "Jun  9 09:00" },
    ];
    for (const e of specEntries) {
      const { path, ...meta } = e;
      const parts = path.replace(/\/$/, "").split("/").filter(Boolean);
      const isDir = path.endsWith("/");
      let cur = projectChildren;
      for (let i = 0; i < parts.length - 1; i++) {
        if (!cur[parts[i]]) cur[parts[i]] = D({});
        cur = cur[parts[i]].children;
      }
      const name = parts.at(-1);
      if (isDir) {
        cur[name] = cur[name] ? Object.assign(cur[name], meta) : D({}, meta);
      } else {
        cur[name] = F(meta);
      }
    }

    // Build nested intermediate dirs from root down to the project dir.
    const rootChildren = {
      "etc":  D({}, { owner: "root" }),
      "tmp":  D({}, { owner: "root", perms: "drwxrwxrwt" }),
      "usr":  D({ "bin": D({}, { owner: "root" }), "local": D({}, { owner: "root" }) }, { owner: "root" }),
      "var":  D({}, { owner: "root" }),
    };
    let cur = rootChildren;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!cur[p]) cur[p] = D({}, i === 0 ? { owner: "root" } : {});
      cur = cur[p].children;
    }
    cur[parts.at(-1)] = D(projectChildren);
    return D(rootChildren, { owner: "root" });
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
    const home = this.fakeEnv?.HOME ?? "/home/" + this.shellUser;
    return full === home ? "~" : full.startsWith(home + "/") ? "~" + full.slice(home.length) : full;
  }

  seedShell() {
    const spec = (typeof jsdemoSpec !== "undefined") ? jsdemoSpec : null;
    this.cwd    = spec?.cwd
      ? spec.cwd.replace(/^\//, "").split("/").filter(Boolean)
      : ["home", "you", "projects", "emojig"];
    this.fsRoot = this._makeFs(spec?.entries ?? null, this.cwd);
    const history = spec?.seed?.history ?? ["git status", "git add ."];
    const input   = spec?.seed?.input   ?? "git commit -m 'release: v1.2 ";
    this.shellLines = history.flatMap((cmd, i) => {
      const lines = [{ kind: "cmd", text: cmd }];
      if (i === 0) lines.push({ kind: "out", text: "On branch main — 3 files changed" });
      return lines;
    });
    this.shellHistory = [...history];
    this.historyIdx = null;
    this.shellDraft = "";
    this.setInput(input);
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

  expandGlobs(argStr) {
    return argStr.trim().split(/\s+/).flatMap(token => {
      if (!token.includes("*")) return [token];
      const lastSlash = token.lastIndexOf("/");
      const dirStr  = lastSlash <= 0 ? (lastSlash === 0 ? "/" : ".") : token.slice(0, lastSlash);
      const pattern = lastSlash === -1 ? token : token.slice(lastSlash + 1);
      const pfx     = lastSlash === -1 ? "" : token.slice(0, lastSlash + 1);
      const r = this.resolvePath(dirStr);
      if (!r || r.node.type !== "dir") return [token];
      const re = new RegExp("^" +
        pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
      const showHidden = pattern.startsWith(".");
      const hits = Object.keys(r.node.children)
        .filter(n => re.test(n) && (showHidden || !n.startsWith(".")))
        .sort();
      return hits.length ? hits.map(n => pfx + n) : [token];
    }).join(" ");
  }

  _nowDate() {
    const now = new Date();
    const MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    return `${MON[now.getMonth()]} ${String(now.getDate()).padStart(2," ")} ${String(now.getHours()).padStart(2,"0")}:${String(now.getMinutes()).padStart(2,"0")}`;
  }

  _fakeCatContent(name, ext) {
    const known = {
      "README.md": [
        "# emojig", "",
        "A Zig terminal emoji picker. Pick any emoji with Ctrl+E.", "",
        "## Install", "  make && make install", "",
        "## Usage", "  emojig [query]    # standalone", "  # or press Ctrl+E in your shell",
      ],
      "Makefile": [
        "BIN := emojig", "SRC := $(wildcard src/*.zig)", "",
        "all: $(BIN)", "",
        "$(BIN): $(SRC)", "\tzig build-exe -O ReleaseSafe src/main.zig -o $(BIN)", "",
        "install: $(BIN)", "\tcp $(BIN) ~/.local/bin/", "",
        "clean:", "\trm -f $(BIN)",
      ],
      "notes.txt": [
        "TODO:", "  - skin-tone modifiers", "  - frecency sorting", "  - AUR package", "",
        "done: fuzzy search, Ctrl+E hook, tab completion 🎉",
      ],
      ".secret": ["hunter2"],
    };
    if (known[name]) return known[name];
    if (ext === "zig") return [
      `// ${name}`, `const std = @import("std");`, "",
      `pub fn main() !void {`,
      `    const out = std.io.getStdOut().writer();`,
      `    try out.print("emojig\\n", .{});`,
      `}`,
    ];
    if (ext === "md") return [`# ${name.replace(/\.md$/, "")}`, "", "(no content)"];
    if (ext === "json") return ["{", `  "${name.replace(/\.json$/, "")}": true`, "}"];
    return [`(${name}: empty)`];
  }

  _cloneNode(node) {
    if (node.type === "file") return { ...node };
    return { ...node, children: Object.fromEntries(
      Object.entries(node.children).map(([k, v]) => [k, this._cloneNode(v)])
    )};
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

    args = this.expandGlobs(args);

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
        const homeParts = this.fakeEnv.HOME.replace(/^\//, "").split("/").filter(Boolean);
        let cdTarget = args.trim();
        if (!cdTarget || cdTarget === "~") {
          this.cwd = homeParts; this.fakeEnv.PWD = this.fakeEnv.HOME; break;
        }
        if (cdTarget.startsWith("~/")) cdTarget = this.fakeEnv.HOME + "/" + cdTarget.slice(2);
        const cdResult = this.resolvePath(cdTarget);
        if (!cdResult) { this.shellLines.push({ kind:"out", text:`cd: no such file or directory: ${args.trim()}` }); break; }
        if (cdResult.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`cd: not a directory: ${args.trim()}` }); break; }
        this.cwd = cdResult.components;
        this.fakeEnv.PWD = "/" + this.cwd.join("/");
        break;
      }

      case "ls":
      case "ll": {
        const lsParts    = args.trim().split(/\s+/).filter(Boolean);
        const lsFlags    = lsParts.filter(a => a.startsWith("-")).join("");
        const longFmt    = cmd === "ll" || lsFlags.includes("l");
        const showHidden = cmd === "ll" || lsFlags.includes("a");
        const oneLine    = lsFlags.includes("1");
        const lsTargets  = lsParts.filter(a => !a.startsWith("-"));
        const paths      = lsTargets.length ? lsTargets : ["."];
        const sortEnts   = (ents) => ents.sort(([na, a], [nb, b]) =>
          a.type !== b.type ? (a.type === "dir" ? -1 : 1) : na.localeCompare(nb));

        for (let ti = 0; ti < paths.length; ti++) {
          const pathArg  = paths[ti];
          const lsResult = this.resolvePath(pathArg);
          if (!lsResult) { this.shellLines.push({ kind:"out", text:`ls: cannot access '${pathArg}': No such file or directory` }); continue; }
          if (paths.length > 1) {
            if (ti > 0) this.shellLines.push({ kind:"out", text:"" });
            this.shellLines.push({ kind:"out", text:`${pathArg}:` });
          }
          const entries = lsResult.node.type === "file"
            ? [[pathArg.split("/").at(-1), lsResult.node]]
            : sortEnts(Object.entries(lsResult.node.children).filter(([n]) => showHidden || !n.startsWith(".")));
          if (longFmt) {
            if (lsResult.node.type === "dir") this.shellLines.push({ kind:"out", text:`total ${entries.length * 8}` });
            for (const [name, node] of entries) {
              const ow = node.owner.padEnd(4);
              const sz = String(node.size).padStart(5);
              this.shellLines.push({ kind:"out", text:`${node.perms} 1 ${ow} ${ow} ${sz} ${node.date} ${name}${node.type === "dir" ? "/" : ""}` });
            }
          } else if (oneLine) {
            for (const [name, node] of entries)
              this.shellLines.push({ kind:"out", text: name + (node.type === "dir" ? "/" : "") });
          } else {
            const names = entries.map(([name, node]) => name + (node.type === "dir" ? "/" : ""));
            if (names.length) this.shellLines.push({ kind:"out", text: names.join("  ") });
          }
        }
        break;
      }

      case "tree": {
        const treeParts     = args.trim().split(/\s+/).filter(Boolean);
        const treeFlags     = treeParts.filter(a => a.startsWith("-")).join("");
        const showHiddenTree = treeFlags.includes("a");
        const treePathArg   = treeParts.find(a => !a.startsWith("-")) ?? ".";
        const treeResult    = this.resolvePath(treePathArg);
        if (!treeResult || treeResult.node.type !== "dir") {
          this.shellLines.push({ kind:"out", text:`tree: '${treePathArg}': No such directory` }); break;
        }
        this.shellLines.push({ kind:"out", text: treePathArg });
        let treeFiles = 0, treeDirs = 0;
        const walkTree = (node, prefix) => {
          const ents = Object.entries(node.children)
            .filter(([n]) => showHiddenTree || !n.startsWith("."))
            .sort(([na, a], [nb, b]) => a.type !== b.type ? (a.type === "dir" ? -1 : 1) : na.localeCompare(nb));
          ents.forEach(([name, child], i) => {
            const last = i === ents.length - 1;
            this.shellLines.push({ kind:"out", text: prefix + (last ? "└── " : "├── ") + name + (child.type === "dir" ? "/" : "") });
            if (child.type === "dir") { treeDirs++; walkTree(child, prefix + (last ? "    " : "│   ")); }
            else treeFiles++;
          });
        };
        walkTree(treeResult.node, "");
        this.shellLines.push({ kind:"out", text:"" });
        this.shellLines.push({ kind:"out", text:`${treeDirs} director${treeDirs === 1 ? "y" : "ies"}, ${treeFiles} file${treeFiles === 1 ? "" : "s"}` });
        break;
      }

      case "cat": {
        for (const target of args.trim().split(/\s+/).filter(Boolean)) {
          const r = this.resolvePath(target);
          if (!r) { this.shellLines.push({ kind:"out", text:`cat: ${target}: No such file or directory` }); continue; }
          if (r.node.type === "dir") { this.shellLines.push({ kind:"out", text:`cat: ${target}: Is a directory` }); continue; }
          const fname = target.split("/").at(-1);
          const ext   = fname.includes(".") ? fname.split(".").pop() : "";
          for (const l of this._fakeCatContent(fname, ext)) this.shellLines.push({ kind:"out", text: l });
        }
        break;
      }

      case "mkdir": {
        const mkParts      = args.trim().split(/\s+/).filter(Boolean);
        const mkFlags      = mkParts.filter(a => a.startsWith("-")).join("");
        const makeParents  = mkFlags.includes("p");
        const d            = this._nowDate();
        for (const target of mkParts.filter(a => !a.startsWith("-"))) {
          if (makeParents) {
            const segs = target.replace(/^\//, "").split("/").filter(Boolean);
            let cur = target.startsWith("/") ? this.fsRoot : this.cwdNode();
            for (const seg of segs) {
              if (!cur.children[seg]) cur.children[seg] = { type:"dir", perms:"drwxr-xr-x", size:"4096", date:d, owner:"you", children:{} };
              else if (cur.children[seg].type !== "dir") { this.shellLines.push({ kind:"out", text:`mkdir: cannot create directory '${target}': Not a directory` }); break; }
              cur = cur.children[seg];
            }
          } else {
            const ls = target.lastIndexOf("/");
            const parentStr = ls <= 0 ? (ls === 0 ? "/" : ".") : target.slice(0, ls);
            const newName   = target.slice(ls + 1);
            const pr = ls === 0 ? { node: this.fsRoot } : this.resolvePath(parentStr);
            if (!pr || pr.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`mkdir: cannot create directory '${target}': No such file or directory` }); continue; }
            if (pr.node.children[newName]) { this.shellLines.push({ kind:"out", text:`mkdir: cannot create directory '${target}': File exists` }); continue; }
            pr.node.children[newName] = { type:"dir", perms:"drwxr-xr-x", size:"4096", date:d, owner:"you", children:{} };
          }
        }
        break;
      }

      case "rmdir": {
        for (const target of args.trim().split(/\s+/).filter(Boolean)) {
          const r = this.resolvePath(target);
          if (!r) { this.shellLines.push({ kind:"out", text:`rmdir: failed to remove '${target}': No such file or directory` }); continue; }
          if (r.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`rmdir: failed to remove '${target}': Not a directory` }); continue; }
          if (Object.keys(r.node.children).length) { this.shellLines.push({ kind:"out", text:`rmdir: failed to remove '${target}': Directory not empty` }); continue; }
          if (r.node.owner === "root" && !isSudo) { this.shellLines.push({ kind:"out", text:`rmdir: failed to remove '${target}': Permission denied` }); continue; }
          if (r.parent) delete r.parent.children[r.name];
        }
        break;
      }

      case "cp": {
        const cpParts   = args.trim().split(/\s+/).filter(Boolean);
        const cpFlags   = cpParts.filter(a => a.startsWith("-")).join("");
        const recursive = cpFlags.includes("r") || cpFlags.includes("R");
        const cpArgs    = cpParts.filter(a => !a.startsWith("-"));
        if (cpArgs.length < 2) { this.shellLines.push({ kind:"out", text:"cp: missing destination" }); break; }
        const cpDest       = cpArgs.at(-1);
        const cpDestResult = this.resolvePath(cpDest);
        const d            = this._nowDate();
        for (const src of cpArgs.slice(0, -1)) {
          const srcResult = this.resolvePath(src);
          if (!srcResult) { this.shellLines.push({ kind:"out", text:`cp: cannot stat '${src}': No such file or directory` }); continue; }
          if (srcResult.node.type === "dir" && !recursive) { this.shellLines.push({ kind:"out", text:`cp: -r not specified; omitting directory '${src}'` }); continue; }
          const srcName = src.split("/").at(-1);
          let destParent, destName;
          if (cpDestResult && cpDestResult.node.type === "dir") {
            destParent = cpDestResult.node; destName = srcName;
          } else {
            const ls = cpDest.lastIndexOf("/");
            const pr = ls === 0 ? { node: this.fsRoot } : this.resolvePath(ls <= 0 ? "." : cpDest.slice(0, ls));
            if (!pr || pr.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`cp: cannot create '${cpDest}': No such file or directory` }); continue; }
            destParent = pr.node; destName = cpDest.slice(ls + 1);
          }
          destParent.children[destName] = this._cloneNode({ ...srcResult.node, date: d });
        }
        break;
      }

      case "mv": {
        const mvParts = args.trim().split(/\s+/).filter(a => !a.startsWith("-")).filter(Boolean);
        if (mvParts.length < 2) { this.shellLines.push({ kind:"out", text:"mv: missing destination" }); break; }
        const mvDest       = mvParts.at(-1);
        const mvDestResult = this.resolvePath(mvDest);
        for (const src of mvParts.slice(0, -1)) {
          const srcResult = this.resolvePath(src);
          if (!srcResult) { this.shellLines.push({ kind:"out", text:`mv: cannot stat '${src}': No such file or directory` }); continue; }
          if (srcResult.node.owner === "root" && !isSudo) { this.shellLines.push({ kind:"out", text:`mv: cannot move '${src}': Permission denied` }); continue; }
          const { parent: srcParent, name: srcName, node: srcNode } = srcResult;
          let destParent, destName;
          if (mvDestResult && mvDestResult.node.type === "dir") {
            destParent = mvDestResult.node; destName = srcName;
          } else {
            const ls = mvDest.lastIndexOf("/");
            const pr = ls === 0 ? { node: this.fsRoot } : this.resolvePath(ls <= 0 ? "." : mvDest.slice(0, ls));
            if (!pr || pr.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`mv: cannot move '${src}' to '${mvDest}': No such directory` }); continue; }
            destParent = pr.node; destName = mvDest.slice(ls + 1);
          }
          destParent.children[destName] = srcNode;
          if (srcParent) delete srcParent.children[srcName];
        }
        break;
      }

      case "touch": {
        const d = this._nowDate();
        for (const t of args.trim().split(/\s+/).filter(Boolean)) {
          const ls    = t.lastIndexOf("/");
          const tName = t.slice(ls + 1);
          const pr    = ls === 0 ? { node: this.fsRoot } : this.resolvePath(ls <= 0 ? "." : t.slice(0, ls));
          if (!pr || pr.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`touch: cannot touch '${t}': No such file or directory` }); continue; }
          if (pr.node.children[tName]) pr.node.children[tName].date = d;
          else pr.node.children[tName] = { type:"file", perms:"-rw-r--r--", size:"   0", date:d, owner:"you" };
        }
        break;
      }

      case "rm": {
        const rmParts   = args.trim().split(/\s+/);
        const rmFlags   = rmParts.filter(p => p.startsWith("-")).join("");
        const rmTargets = rmParts.filter(p => !p.startsWith("-"));
        const hasR      = rmFlags.includes("r") || rmFlags.includes("R");

        rmLoop: for (const target of rmTargets) {
          if (!target) continue;
          const rr = this.resolvePath(target);
          if (!rr) { this.shellLines.push({ kind:"out", text:`rm: cannot remove '${target}': No such file or directory` }); continue; }
          const { node, parent, name } = rr;
          if (node.type === "dir" && !hasR) { this.shellLines.push({ kind:"out", text:`rm: cannot remove '${target}': Is a directory` }); continue; }
          if (node.owner === "root" && !isSudo) {
            this.shellLines.push({ kind:"out", text:`rm: cannot remove '${target}': Permission denied` });
            if (rr.components.length === 0) this.shellLines.push({ kind:"out", text:"hint: try sudo rm -rf /" });
            continue;
          }
          if (rr.components.length === 0 && hasR) {
            const boom = [
              "rm: descending into '/'…", "rm: removing '/usr'… 💥", "rm: removing '/home'… 💥",
              "rm: removing '/etc'… 💥", "rm: removing '/var'… 💥", "rm: removing '/tmp'… 💥",
              "rm: this is fine 🔥", "💥💥💥",
            ];
            boom.forEach((msg, i) => {
              setTimeout(() => {
                this.shellLines.push({ kind:"out", text: msg });
                this.render();
                if (i === boom.length - 1) setTimeout(() => {
                  document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;font-size:50vw;background:#000;margin:0;cursor:pointer" title="refresh to recover" onclick="location.reload()">💀</div>';
                }, 600);
              }, i * 350);
            });
            break rmLoop;
          }
          if (parent) delete parent.children[name];
        }
        break;
      }

      case "grep": {
        const grepParts = args.trim().split(/\s+/).filter(Boolean);
        const grepFlags = grepParts.filter(a => a.startsWith("-")).join("");
        const grepRest  = grepParts.filter(a => !a.startsWith("-"));
        const pattern   = grepRest[0];
        const grepFiles = grepRest.slice(1);
        if (!pattern) { this.shellLines.push({ kind:"out", text:"grep: missing pattern" }); break; }
        if (!grepFiles.length) { this.shellLines.push({ kind:"out", text:"grep: (standard input): not supported in demo" }); break; }
        let re;
        try { re = new RegExp(pattern, grepFlags.includes("i") ? "i" : ""); } catch { re = null; }
        if (!re) { this.shellLines.push({ kind:"out", text:`grep: invalid pattern: ${pattern}` }); break; }
        for (const file of grepFiles) {
          const r = this.resolvePath(file);
          if (!r) { this.shellLines.push({ kind:"out", text:`grep: ${file}: No such file or directory` }); continue; }
          if (r.node.type === "dir") { this.shellLines.push({ kind:"out", text:`grep: ${file}: Is a directory` }); continue; }
          const fname = file.split("/").at(-1);
          const ext   = fname.includes(".") ? fname.split(".").pop() : "";
          const hits  = this._fakeCatContent(fname, ext).filter(l => re.test(l));
          for (const l of hits) this.shellLines.push({ kind:"out", text: grepFiles.length > 1 ? `${file}:${l}` : l });
        }
        break;
      }

      case "wc": {
        const wcParts = args.trim().split(/\s+/).filter(Boolean);
        const wcFlags = wcParts.filter(a => a.startsWith("-")).join("");
        const wcFiles = wcParts.filter(a => !a.startsWith("-"));
        const lOnly = wcFlags.includes("l"), wOnly = wcFlags.includes("w"), cOnly = wcFlags.includes("c");
        const showAll = !lOnly && !wOnly && !cOnly;
        for (const file of wcFiles) {
          const r = this.resolvePath(file);
          if (!r) { this.shellLines.push({ kind:"out", text:`wc: ${file}: No such file or directory` }); continue; }
          if (r.node.type === "dir") { this.shellLines.push({ kind:"out", text:`wc: ${file}: Is a directory` }); continue; }
          const fname = file.split("/").at(-1);
          const ext   = fname.includes(".") ? fname.split(".").pop() : "";
          const lines = this._fakeCatContent(fname, ext);
          const lc = lines.length, wc = lines.join(" ").split(/\s+/).filter(Boolean).length, cc = lines.join("\n").length;
          const parts = [...(showAll || lOnly ? [String(lc).padStart(4)] : []),
                         ...(showAll || wOnly ? [String(wc).padStart(4)] : []),
                         ...(showAll || cOnly ? [String(cc).padStart(5)] : []), file];
          this.shellLines.push({ kind:"out", text: parts.join(" ") });
        }
        break;
      }

      case "find": {
        const findParts  = args.trim().split(/\s+/).filter(Boolean);
        const findPath   = findParts[0] && !findParts[0].startsWith("-") ? findParts[0] : ".";
        const nameIdx    = findParts.indexOf("-name");
        const typeIdx    = findParts.indexOf("-type");
        const nameGlob   = nameIdx !== -1 ? findParts[nameIdx + 1] : null;
        const typeFilter = typeIdx !== -1 ? findParts[typeIdx + 1] : null;
        const findResult = this.resolvePath(findPath);
        if (!findResult || findResult.node.type !== "dir") { this.shellLines.push({ kind:"out", text:`find: '${findPath}': No such file or directory` }); break; }
        const nameRe = nameGlob
          ? new RegExp("^" + nameGlob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$")
          : null;
        this.shellLines.push({ kind:"out", text: findPath });
        const walkFind = (node, base) => {
          for (const [name, child] of Object.entries(node.children)) {
            if (typeFilter === "d" && child.type !== "dir") continue;
            if (typeFilter === "f" && child.type !== "file") continue;
            const p = base + "/" + name;
            if (!nameRe || nameRe.test(name)) this.shellLines.push({ kind:"out", text: p });
            if (child.type === "dir") walkFind(child, p);
          }
        };
        walkFind(findResult.node, findPath === "." ? "." : findPath);
        break;
      }

      case "which": {
        const bins = {
          emojig:"/home/you/.local/bin/emojig", zsh:"/usr/bin/zsh", bash:"/usr/bin/bash",
          git:"/usr/bin/git", ls:"/usr/bin/ls", cat:"/usr/bin/cat", tree:"/usr/bin/tree",
          grep:"/usr/bin/grep", find:"/usr/bin/find", make:"/usr/bin/make",
          zig:"/usr/local/bin/zig", touch:"/usr/bin/touch", rm:"/usr/bin/rm",
          cp:"/usr/bin/cp", mv:"/usr/bin/mv", mkdir:"/usr/bin/mkdir", wc:"/usr/bin/wc",
        };
        for (const bin of args.trim().split(/\s+/).filter(Boolean)) {
          const p = bins[bin] ?? (this.resolvePath(bin) ? bin : null);
          this.shellLines.push({ kind:"out", text: p ?? `${bin} not found` });
        }
        break;
      }

      case "ps":
        this.shellLines.push({ kind: "out", text: "  PID TTY          TIME CMD" });
        this.shellLines.push({ kind: "out", text: " 1234 pts/0    00:00:02 zsh" });
        this.shellLines.push({ kind: "out", text: " 5678 pts/0    00:00:00 emojig" });
        this.shellLines.push({ kind: "out", text: " 9012 pts/0    00:00:00 ps" });
        break;

      case "env":
        for (const [k, v] of Object.entries(this.fakeEnv)) {
          this.shellLines.push({ kind: "out", text: `${k}=${v}` });
        }
        break;

      case "neofetch": {
        const neofetchLines = [
          `${this.shellUser}@${this.shellHost} 🔍`, `──────────────────────────────`,
          `OS:       EmojiOS 6.9 🐧`, `Host:     TerminalBook Pro`,
          `Kernel:   6.9.0-emojig`, `Shell:    zsh 5.9`,
          `Terminal: emojig-tui`, `CPU:      EmojiCore™ @ 4.2 GHz`,
          `Memory:   420 MiB / 6969 MiB 🧠`, `Uptime:   42 mins ⏱️`,
          `Colors:   🟥🟧🟨🟩🟦🟪⬛⬜`,
        ];
        for (const l of neofetchLines) this.shellLines.push({ kind: "out", text: l });
        break;
      }

      case "git": {
        const gitParts = args.trim().split(/\s+/);
        const sub      = gitParts[0];
        const gitRest  = gitParts.slice(1).join(" ");
        if (sub === "status") {
          this.shellLines.push({ kind:"out", text:"On branch main" });
          this.shellLines.push({ kind:"out", text:"Your branch is up to date with 'origin/main'." });
          this.shellLines.push({ kind:"out", text:"" });
          this.shellLines.push({ kind:"out", text:"Changes to be committed:" });
          this.shellLines.push({ kind:"out", text:'  (use "git restore --staged <file>..." to unstage)' });
          this.shellLines.push({ kind:"out", text:"\tmodified:   src/main.zig" });
        } else if (sub === "add") {
          // silent like real git
        } else if (sub === "commit") {
          const m    = args.match(/-m\s+['"](.+)['"]/s);
          const msg  = m ? m[1] : gitRest.trim() || "update";
          const hash = Math.random().toString(16).slice(2, 9);
          this.shellLines.push({ kind:"out", text:`[main ${hash}] ${msg}` });
          this.shellLines.push({ kind:"out", text:" 3 files changed, 42 insertions(+), 7 deletions(-)" });
        } else if (sub === "log") {
          const logs = [
            ["a1b2c3d", "feat: add Ctrl+E shell hook"],
            ["e4f5a6b", "fix: cursor position after emoji insert"],
            ["7c8d9e0", "refactor: tree-based filesystem sim"],
            ["1f2a3b4", "feat: tab completion for relative paths"],
            ["5c6d7e8", "chore: initial commit"],
          ];
          for (const [h, msg] of logs) {
            this.shellLines.push({ kind:"out", text:`commit ${h}...` });
            this.shellLines.push({ kind:"out", text:`Author: ${this.shellUser} <${this.shellUser}@${this.shellHost}>` });
            this.shellLines.push({ kind:"out", text:`Date:   Jun  9 12:00 2026` });
            this.shellLines.push({ kind:"out", text:`    ${msg}` });
            this.shellLines.push({ kind:"out", text:"" });
          }
        } else if (sub === "diff") {
          this.shellLines.push({ kind:"out", text:"diff --git a/src/main.zig b/src/main.zig" });
          this.shellLines.push({ kind:"out", text:"index e4f5a6b..a1b2c3d 100644" });
          this.shellLines.push({ kind:"out", text:"--- a/src/main.zig" });
          this.shellLines.push({ kind:"out", text:"+++ b/src/main.zig" });
          this.shellLines.push({ kind:"out", text:"@@ -1,4 +1,6 @@" });
          this.shellLines.push({ kind:"out", text:' const std = @import("std");' });
          this.shellLines.push({ kind:"out", text:'+const emoji = @import("emoji.zig");' });
          this.shellLines.push({ kind:"out", text:"+" });
          this.shellLines.push({ kind:"out", text:" pub fn main() !void {" });
        } else if (sub === "branch") {
          this.shellLines.push({ kind:"out", text:"* main" });
          this.shellLines.push({ kind:"out", text:"  feat/skin-tones" });
          this.shellLines.push({ kind:"out", text:"  fix/cursor-pos" });
        } else if (sub === "push") {
          this.shellLines.push({ kind:"out", text:"Enumerating objects: 5, done." });
          this.shellLines.push({ kind:"out", text:"Counting objects: 100% (5/5), done." });
          this.shellLines.push({ kind:"out", text:"Writing objects: 100% (3/3), 312 bytes | 312.00 KiB/s, done." });
          this.shellLines.push({ kind:"out", text:"To github.com:you/emojig.git" });
          this.shellLines.push({ kind:"out", text:"   e4f5a6b..a1b2c3d  main -> main" });
        } else if (sub === "pull") {
          this.shellLines.push({ kind:"out", text:"Already up to date." });
        } else if (sub === "clone") {
          const repoName = gitRest.split("/").at(-1).replace(/\.git$/, "").replace(/\s.*/, "");
          this.shellLines.push({ kind:"out", text:`Cloning into '${repoName || "repo"}'...` });
          this.shellLines.push({ kind:"out", text:"remote: Enumerating objects: 42, done." });
          this.shellLines.push({ kind:"out", text:"Receiving objects: 100% (42/42), 18.5 KiB | 1.2 MiB/s, done." });
        } else if (sub === "init") {
          this.shellLines.push({ kind:"out", text:`Initialized empty Git repository in ${this.fakeEnv.PWD}/.git/` });
        } else {
          this.shellLines.push({ kind:"out", text:`git: '${sub}' not supported in demo` });
        }
        break;
      }

      case "help":
        this.shellLines.push({ kind:"out", text:"commands: echo, ls/ll, cd, pwd, tree, cat, mkdir, rmdir, cp, mv, touch, rm, grep, wc, find, which, ps, env, git, neofetch, clear" });
        this.shellLines.push({ kind:"out", text:"Ctrl+E → emoji picker  |  Tab → completion  |  ↑↓ → history  |  Ctrl+K → clear" });
        break;

      default:
        this.shellLines.push({ kind: "out", text: `zsh: command not found: ${cmd}` });
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
  const themeOpt = document.getElementById("sim-opt-theme");
  const focusBadge = document.getElementById("sim-focus-badge");

  // Middle-click paste anchor: a hidden off-screen textarea kept focused in
  // shell mode so Firefox doesn't intercept bare keystrokes (e.g. ' / /) as
  // Quick Find triggers.  Also used as the paste target for X11 PRIMARY paste.
  const pasteEl = document.createElement("textarea");
  pasteEl.setAttribute("aria-hidden", "true");
  pasteEl.style.cssText =
    "position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0;pointer-events:none;";
  document.body.appendChild(pasteEl);

  // Route DOM focus to the right element based on current sim mode.
  function syncFocus() {
    if (!sim.isFocused) return;
    if (sim.mode === "tui") { if (inputEl) inputEl.focus(); }
    else                    { pasteEl.focus(); }
  }

  // Seed the shell and open the picker inline — demonstrating the inline TUI USP.
  sim.seedShell();
  sim.openTui();
  sim.isFocused = true;
  updateFocusBadge(true);
  sim.updateThemeClass();
  syncFocus();

  // When the TUI search input loses focus, hand it to pasteEl if in shell mode
  // (covers Esc/Enter closing the TUI without a click).
  if (inputEl) {
    inputEl.addEventListener("blur", () => {
      setTimeout(() => { if (sim.isFocused && sim.mode === "shell") pasteEl.focus(); }, 0);
    });
  }

  // Event binding: Terminal screen focus
  screenEl.addEventListener("click", () => {
    // Clicking anywhere on the terminal dismisses the TUI if no emoji cell was
    // clicked — cell clicks call selectEmoji() first (child event, bubbles up),
    // so by the time we get here mode is already "shell" in that case.
    if (sim.mode === "tui") sim.closeTui();
    sim.isFocused = true;
    sim.updateThemeClass();
    updateFocusBadge(true);
    syncFocus();
  });

  document.addEventListener("click", (e) => {
    // Use composedPath() instead of contains(e.target): if a TUI cell click
    // triggers a re-render, the cell is detached from the DOM before this
    // handler fires, so contains() returns false even though the click was
    // inside the terminal.
    const path = e.composedPath();
    const insideTerminal = path.includes(screenEl);
    const panelEl = document.getElementById("sim-panel");
    const insidePanel = panelEl ? path.includes(panelEl) : false;
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

  // The badge says "Click here to focus keys" — make the click deliver.
  if (focusBadge) {
    focusBadge.style.cursor = "pointer";
    focusBadge.addEventListener("click", () => {
      sim.isFocused = true;
      sim.updateThemeClass();
      updateFocusBadge(true);
      syncFocus();
    });
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

  // Middle-click paste (X11 PRIMARY selection).
  // pasteEl is already focused in shell mode; on middle-mousedown just clear it
  // so the browser's PRIMARY paste lands cleanly, then the input event picks it up.
  screenEl.addEventListener("mousedown", (e) => {
    if (e.button !== 1 || !sim.isFocused || sim.mode !== "shell") return;
    pasteEl.value = "";
    pasteEl.focus();
  });

  pasteEl.addEventListener("input", () => {
    const text = pasteEl.value;
    pasteEl.value = "";
    // Keep pasteEl focused — don't blur, it's our Quick Find shield.
    if (text) {
      sim.insertAtCursor(text);
      sim.render();
    }
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
    const topCount = Math.min(sim.cols * sim.rows, matches.length);
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
    const topCount = Math.min(sim.cols * sim.rows, matches.length);
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
    const topCount = Math.min(sim.cols * sim.rows, matches.length);
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
    const topCount = Math.min(sim.cols * sim.rows, matches.length);
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
