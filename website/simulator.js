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
        this.state = "active"; // "active" | "exited"
        this.copiedEmoji = null;

        this.cols = 6;
        this.rows = 4;
        this.contentWidth = 25;

        this.detectSystemTheme();
        this.setupMediaListeners();
    }

    detectSystemTheme() {
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
            this.systemTheme = "light";
        } else {
            this.systemTheme = "dark";
        }
    }

    setupMediaListeners() {
        if (window.matchMedia) {
            window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', e => {
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
                if (targetIdx === 0 || target[targetIdx - 1] === ' ') {
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
        if (term.length > 3 && term[term.length - 1].toLowerCase() === 's') {
            const last2 = term[term.length - 2].toLowerCase();
            if (last2 !== 's') { // avoid "glass", "grass"
                // If it ends in "ies" and length > 5 (e.g. "cherries" -> "cherry")
                if (term.length > 5 && last2 === 'e' && term[term.length - 3].toLowerCase() === 'i') {
                    const alternate = term.slice(0, term.length - 3) + 'y';
                    const s = this.matchTermDirect(alternate, target);
                    if (s !== null) return s - 5;
                }
                // If it ends in "es" and length > 4 (e.g. "boxes" -> "box")
                if (term.length > 4 && last2 === 'e') {
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
        if (term.length > 4 && term.toLowerCase().endsWith('ing')) {
            const stem = term.slice(0, term.length - 3);
            // try stem directly (e.g. "racing" -> "rac")
            const s = this.matchTermDirect(stem, target);
            if (s !== null) return s - 5;

            // try stem + "e" (e.g. "racing" -> "race")
            const alternate = stem + 'e';
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
        if (term.length > 3 && term[term.length - 1].toLowerCase() === 'e') {
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

    getFilteredMatches() {
        if (typeof EMOJI_DB === 'undefined') return [];
        const db = EMOJI_DB;

        if (this.query.trim() === "") {
            // Return first 24 emojis by default
            return db.slice(0, 24).map((item, idx) => ({
                emoji: item[0],
                description: item[1],
                originalIdx: idx,
                score: 0
            }));
        }

        const matches = [];
        for (let i = 0; i < db.length; i++) {
            const item = db[i];
            const score = this.fuzzyMatch(this.query, item[2]);
            if (score !== null) {
                matches.push({
                    emoji: item[0],
                    description: item[1],
                    originalIdx: i,
                    score: score
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
        return emoji.replace(/[\uFE0E\uFE0F]/g, '');
    }

    formatEmoji(emoji) {
        return this.safeMode ? this.stripVariationSelectors(emoji) : emoji;
    }

    updateThemeClass() {
        const screenEl = document.getElementById("sim-screen");
        if (!screenEl) return;
        screenEl.className = "sim-screen theme-" + this.getEffectiveTheme() + (this.isFocused ? " focused" : "");
    }

    render() {
        const screenEl = document.getElementById("sim-screen");
        if (!screenEl) return;

        if (this.state === "exited") {
            this.renderExitedState(screenEl);
            return;
        }

        const matches = this.getFilteredMatches();
        const totalMatches = matches.length;
        const topCount = Math.min(24, totalMatches);
        const topMatches = matches.slice(0, topCount);

        // Keep selection in bounds
        if (this.selectedIdx !== null) {
            if (totalMatches === 0) {
                this.selectedIdx = null;
            } else if (this.selectedIdx >= topCount) {
                this.selectedIdx = topCount - 1;
            }
        }

        let html = "";

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
                if (ch.codePointAt(0) > 0x1f000 || ch === '🔍') {
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
        // Remaining spacer logic: Total 25. Prompt takes 3. Theme takes 4. Query takes up to 18.
        const maxQueryCols = 18;
        const displayQuery = queryText.length > maxQueryCols ? queryText.slice(0, maxQueryCols) : queryText;
        const padLen = Math.max(0, maxQueryCols - displayQuery.length);

        const themeIcon = this.theme === "dark" ? "🌙" : (this.theme === "light" ? "🌞" : "🔆");

        html += `<div class="sim-row sim-search"> ` +
            `<span class="sim-search-prompt">${searchPrompt}</span>` +
            `<span class="sim-search-query">${displayQuery}</span>` +
            `<span class="sim-cursor">█</span>` +
            `<span>${" ".repeat(padLen)}</span>` +
            `<span class="sim-theme-icon" id="sim-theme-toggle" title="Cycle Theme (Tab)"> ${themeIcon} </span>` +
            `</div>`;

        // 4. Spacer Row
        html += `<div class="sim-row"> </div>`;

        // 5. Grid Rows (4 rows)
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
        const maxDescLen = 24;
        let displayDesc = descText;
        if (descText.length > maxDescLen) {
            displayDesc = descText.slice(0, maxDescLen - 3) + "...";
        }
        html += `<div class="sim-row"> ${padRight(displayDesc, maxDescLen)}</div>`;

        // 8. Status Bar Row
        const statusText = ` ${totalMatches}  ↑↓←→  Tab  ^C`;
        html += `<div class="sim-row sim-status">${padRight(statusText, 25)}</div>`;

        // 9. Bottom Border
        if (this.showBorder) {
            html += `<div class="sim-row sim-border"></div>`;
        }

        screenEl.innerHTML = html;

        // Re-bind click handlers for cells inside the screen
        const cells = screenEl.querySelectorAll(".sim-cell");
        cells.forEach(cell => {
            const idx = parseInt(cell.getAttribute("data-idx"));
            cell.addEventListener("mouseenter", () => {
                this.selectedIdx = idx;
                this.render();
            });
            cell.addEventListener("click", () => {
                const match = topMatches[idx];
                this.selectAndCopy(match.emoji);
            });
        });

        // Theme icon toggle hover
        const toggleEl = document.getElementById("sim-theme-toggle");
        if (toggleEl) {
            toggleEl.addEventListener("mouseenter", () => toggleEl.classList.add("hovered"));
            toggleEl.addEventListener("mouseleave", () => toggleEl.classList.remove("hovered"));
            toggleEl.addEventListener("click", (e) => {
                e.stopPropagation();
                this.cycleTheme();
            });
        }
    }

    renderExitedState(screenEl) {
        const formattedQuery = this.query ? ` "${this.query}"` : "";
        screenEl.innerHTML = `
            <div class="sim-exit-prompt">$ emojig --tui${formattedQuery}</div>
            <div class="sim-exit-copied">${this.copiedEmoji}</div>
            <div class="sim-exit-meta">
                <span>Selected and copied to clipboard!</span><br>
                <span>Process exited with status 0.</span><br><br>
                <a id="sim-restart-btn">[↩ Press Enter or Click to Restart]</a>
            </div>
        `;

        const restartBtn = document.getElementById("sim-restart-btn");
        if (restartBtn) {
            restartBtn.addEventListener("click", () => this.resetTui());
        }
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

    selectAndCopy(emoji) {
        this.copiedEmoji = emoji;
        this.state = "exited";
        this.render();

        // Copy to clipboard
        navigator.clipboard.writeText(emoji).then(() => {
            this.showToast(emoji);
        }).catch(err => {
            console.error("Failed to copy emoji: ", err);
        });
    }

    showToast(emoji) {
        // Remove existing toast if present
        const oldToast = document.querySelector(".sim-toast");
        if (oldToast) oldToast.remove();

        const toast = document.createElement("div");
        toast.className = "sim-toast";
        toast.innerHTML = `<span class="sim-toast-icon">✓</span> Copied ${emoji} to clipboard!`;
        document.body.appendChild(toast);

        // Trigger reflow
        toast.offsetHeight;
        toast.classList.add("show");

        setTimeout(() => {
            toast.classList.remove("show");
            setTimeout(() => toast.remove(), 300);
        }, 2000);
    }

    resetTui() {
        this.state = "active";
        this.query = "";
        this.selectedIdx = null;
        this.copiedEmoji = null;

        // Reset sync elements
        const inputEl = document.getElementById("sim-query-input");
        if (inputEl) inputEl.value = "";

        this.render();
    }

    // --- Keyboard Navigation ---

    handleKeydown(e) {
        if (this.state === "exited") {
            if (e.key === "Enter") {
                e.preventDefault();
                this.resetTui();
            }
            return;
        }

        // If focus is not active, ignore keydown
        if (!this.isFocused) return;

        // Skip modifiers
        if (e.ctrlKey || e.altKey || e.metaKey) {
            // Support Ctrl+C to cancel/clear
            if (e.ctrlKey && e.key.toLowerCase() === 'c') {
                e.preventDefault();
                this.resetTui();
            }
            return;
        }

        const matches = this.getFilteredMatches();
        const topCount = Math.min(24, matches.length);

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
            this.query = "";
            this.selectedIdx = null;
            const inputEl = document.getElementById("sim-query-input");
            if (inputEl) inputEl.value = "";
            this.render();
        } else if (e.key === "Tab") {
            e.preventDefault();
            this.cycleTheme();
        } else if (e.key === "Enter") {
            e.preventDefault();
            if (this.selectedIdx !== null && matches[this.selectedIdx]) {
                this.selectAndCopy(matches[this.selectedIdx].emoji);
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

    // Setup initial theme class
    sim.updateThemeClass();
    sim.render();

    // Auto-focus input on page load
    if (inputEl) {
        inputEl.focus();
        sim.isFocused = true;
        sim.updateThemeClass();
        updateFocusBadge(true);
    }

    // Event binding: Terminal screen focus
    screenEl.addEventListener("click", () => {
        sim.isFocused = true;
        sim.updateThemeClass();
        updateFocusBadge(true);
        if (inputEl) inputEl.focus(); // On touch devices, focuses mobile input automatically
    });

    document.addEventListener("click", (e) => {
        const insideTerminal = screenEl.contains(e.target);
        const insidePanel = document.getElementById("sim-panel")?.contains(e.target);
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

    // Sync search input box
    if (inputEl) {
        inputEl.addEventListener("input", (e) => {
            sim.query = e.target.value;
            // Reset selection to first match
            const matches = sim.getFilteredMatches();
            sim.selectedIdx = matches.length > 0 ? 0 : null;
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
        const matches = sim.getFilteredMatches();
        const topCount = Math.min(24, matches.length);
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
        const matches = sim.getFilteredMatches();
        const topCount = Math.min(24, matches.length);
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
        const matches = sim.getFilteredMatches();
        const topCount = Math.min(24, matches.length);
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
        const matches = sim.getFilteredMatches();
        const topCount = Math.min(24, matches.length);
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
        if (sim.state === "exited") {
            sim.resetTui();
            return;
        }
        const matches = sim.getFilteredMatches();
        if (sim.selectedIdx !== null && matches[sim.selectedIdx]) {
            sim.selectAndCopy(matches[sim.selectedIdx].emoji);
        }
    });
});
