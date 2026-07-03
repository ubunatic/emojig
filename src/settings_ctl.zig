// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Settings-screen controller (issue 44 item 3): owns the mutable state of
//! the settings screen (list scroll, choice dropdown, keybind text editor,
//! grid-dim typing/hover) and applies setting changes. Dispatch is by option
//! *id* from spec/settings.yaml — never by row index — so the spec stays
//! reorderable. The only side effect the event loop must run itself is
//! `Effect.theme_changed` (terminal-color reapplication needs the TTY fds).

const std = @import("std");
const emojig = @import("emojig");
const mru = emojig.mru;
const input_mod = @import("input.zig");
const spec_mod = @import("spec.zig");
const config = @import("config.zig");
const defaults = @import("defaults.zig");
const term = @import("term.zig");
const tui_draw = @import("tui_draw.zig");
const integration = @import("integration.zig");

pub const Theme = term.Theme;
pub const ScrollbarStyle = config.ScrollbarStyle;

/// Mutable settings-screen state, owned by main()'s event loop.
pub const State = struct {
    scroll_top: usize = 0,
    /// Keybind text editor (shell_key_binding "custom" choice). While
    /// editing, the live binding points into `keybind_input_buf`; Esc
    /// reverts to `keybind_committed_buf`.
    keybind_editing: bool = false,
    keybind_input_buf: [32]u8 = undefined,
    keybind_input_len: usize = 0,
    keybind_committed_buf: [32]u8 = undefined,
    keybind_committed_len: usize = 0,
    /// Open choice dropdown (settings option index) and its highlighted row.
    dropdown_opt_idx: ?usize = null,
    dropdown_sel: usize = 0,
    /// Grid-dim rows: digit-typing run and the "applies on next launch" hints.
    griddim_typing: bool = false,
    griddim_changed: bool = false,
    colors_changed: bool = false,
    /// Hovered ‹/› halves of the selected grid-dim row.
    hover_left: bool = false,
    hover_right: bool = false,
};

/// Pointers to the app-wide setting values living in main(), plus the
/// context needed to persist them. Constructed once before the event loop.
pub const Env = struct {
    io: std.Io,
    spec: *const spec_mod.Spec,
    theme: *Theme,
    shell_integration: *bool,
    show_all_categories: *bool,
    ambiguous_chars: *[]const u8,
    scrollbar_style: *ScrollbarStyle,
    grid_cols: *usize,
    grid_rows: *usize,
    grid_compact: *bool,
    gui_decorated: *bool,
    shell_key_binding: *[]const u8,
    app_bg_choice: *[]const u8,
    title_bg_choice: *[]const u8,
    popup_title: *[]const u8,
    popup_msg: *?[]const u8,
    home: []const u8,
    shell_name: []const u8,
};

/// Side effect the event loop must run after a settings change; everything
/// else (config persistence, popups, state flags) is already applied here.
pub const Effect = enum { none, theme_changed };

fn optIs(opt: spec_mod.SettingOption, id: []const u8) bool {
    return std.mem.eql(u8, opt.id, id);
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// If option `idx` is a grid-dimension row, return whether it is the cols
/// row (`true`) or the rows row (`false`); null for every other option.
pub fn gridDimAt(spec: *const spec_mod.Spec, idx: usize) ?bool {
    if (idx >= spec.settings.options.len) return null;
    const opt = spec.settings.options[idx];
    if (optIs(opt, "cols")) return true;
    if (optIs(opt, "rows")) return false;
    return null;
}

/// Context-sensitive help for a settings row (`?`/`h`/F1 modal). Texts live
/// in spec/settings.yaml (`help` per option, `help_fallback` otherwise).
pub fn settingHelp(spec: *const spec_mod.Spec, idx: usize) []const u8 {
    const settings = &spec.settings;
    if (idx < settings.options.len) {
        if (settings.options[idx].help) |h| return h;
    }
    return settings.help_fallback;
}

/// Cycle the theme enum forward (dark → light → system) or backward.
pub fn cycleTheme(t: Theme, forward: bool) Theme {
    if (forward) return switch (t) {
        .dark => .light,
        .light => .system,
        .system => .dark,
    };
    return switch (t) {
        .dark => .system,
        .system => .light,
        .light => .dark,
    };
}

/// Discards installShellIntegration output; the rc-sourcing reminder lives
/// in the settings help modal instead of a popup.
const BufferWriter = struct {
    buf: []u8,
    pos: *usize,

    pub fn writeAll(self: BufferWriter, bytes: []const u8) !void {
        if (self.pos.* + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos.*..][0..bytes.len], bytes);
        self.pos.* += bytes.len;
    }
};

/// Apply a non-text settings change (booleans and 2-state enums) without a
/// confirmation popup — the per-setting help modal explains each option.
fn toggleSetting(st: *State, env: Env, opt: spec_mod.SettingOption) void {
    if (optIs(opt, "shell_integration")) {
        env.shell_integration.* = !env.shell_integration.*;
        config.saveKeyToConfig(env.io, opt.id, boolStr(env.shell_integration.*));
        if (env.shell_integration.*) {
            var scratch: [1024]u8 = undefined;
            var pos: usize = 0;
            integration.installShellIntegration(env.io, env.home, env.shell_name, null, BufferWriter{ .buf = &scratch, .pos = &pos });
        }
    } else if (optIs(opt, "show_all_categories")) {
        env.show_all_categories.* = !env.show_all_categories.*;
        config.saveKeyToConfig(env.io, opt.id, boolStr(env.show_all_categories.*));
    } else if (optIs(opt, "scrollbar_style")) {
        env.scrollbar_style.* = switch (env.scrollbar_style.*) {
            .expand => .bar,
            .bar => .expand,
        };
        config.saveKeyToConfig(env.io, opt.id, @tagName(env.scrollbar_style.*));
    } else if (optIs(opt, "compact")) {
        env.grid_compact.* = !env.grid_compact.*;
        config.saveKeyToConfig(env.io, opt.id, boolStr(env.grid_compact.*));
        st.griddim_changed = true;
    } else if (optIs(opt, "decorated")) {
        env.gui_decorated.* = !env.gui_decorated.*;
        config.saveKeyToConfig(env.io, opt.id, boolStr(env.gui_decorated.*));
        st.colors_changed = true;
    }
}

/// Persist a chosen value and update its live counterpart. app_bg/title_bg
/// mark colors_changed so the status hint shows "applies on next launch".
fn saveChoice(st: *State, env: Env, opt_id: []const u8, choice: []const u8) void {
    config.saveKeyToConfig(env.io, opt_id, choice);
    if (std.mem.eql(u8, opt_id, "shell_key_binding")) {
        env.shell_key_binding.* = choice;
    } else if (std.mem.eql(u8, opt_id, "ambiguous_chars")) {
        env.ambiguous_chars.* = choice;
        tui_draw.g_wide_ambiguous = !std.mem.eql(u8, choice, "narrow");
    } else if (std.mem.eql(u8, opt_id, "app_bg")) {
        env.app_bg_choice.* = choice;
        st.colors_changed = true;
    } else if (std.mem.eql(u8, opt_id, "title_bg")) {
        env.title_bg_choice.* = choice;
        st.colors_changed = true;
    }
}

/// Live value of a choice option, used to preselect its dropdown row.
fn currentChoiceValue(env: Env, opt: spec_mod.SettingOption) []const u8 {
    if (optIs(opt, "theme")) return term.themeName(env.theme.*);
    if (optIs(opt, "shell_key_binding")) return env.shell_key_binding.*;
    if (optIs(opt, "ambiguous_chars")) return env.ambiguous_chars.*;
    if (optIs(opt, "app_bg")) return env.app_bg_choice.*;
    if (optIs(opt, "title_bg")) return env.title_bg_choice.*;
    return "";
}

/// Index of `val` in the option's choices. A value not present in the list
/// (e.g. a hand-edited keybinding) selects the "custom" choice when one
/// exists, else the first row.
fn choiceIndex(opt: spec_mod.SettingOption, val: []const u8) usize {
    const choices = opt.choices orelse return 0;
    for (choices, 0..) |choice, ci| {
        if (std.mem.eql(u8, choice, val)) return ci;
    }
    for (choices, 0..) |choice, ci| {
        if (std.mem.eql(u8, choice, "custom")) return ci;
    }
    return 0;
}

/// Open the choice dropdown for a settings row, highlighting the current value.
pub fn openDropdown(st: *State, env: Env, opt_idx: usize) void {
    const opt = env.spec.settings.options[opt_idx];
    st.dropdown_opt_idx = opt_idx;
    st.dropdown_sel = choiceIndex(opt, currentChoiceValue(env, opt));
}

/// Enter the inline keybind editor, seeding it with the current binding and
/// remembering the committed value for Esc-revert.
fn startKeybindEditing(st: *State, env: Env) void {
    st.dropdown_opt_idx = null;
    env.popup_msg.* = null;
    st.keybind_editing = true;
    const cur = env.shell_key_binding.*;
    st.keybind_committed_len = @min(cur.len, st.keybind_committed_buf.len);
    @memcpy(st.keybind_committed_buf[0..st.keybind_committed_len], cur[0..st.keybind_committed_len]);
    st.keybind_input_len = st.keybind_committed_len;
    @memcpy(st.keybind_input_buf[0..st.keybind_input_len], st.keybind_committed_buf[0..st.keybind_input_len]);
    env.shell_key_binding.* = st.keybind_input_buf[0..st.keybind_input_len];
}

/// Commit a chosen dropdown value: theme applies live, "custom" on the
/// keybinding opens the inline text editor, everything else saves directly.
fn applyChoice(st: *State, env: Env, opt: spec_mod.SettingOption, choice: []const u8) Effect {
    if (optIs(opt, "theme")) {
        if (std.meta.stringToEnum(Theme, choice)) |t| {
            env.theme.* = t;
            config.saveThemeToConfig(env.io, t);
            return .theme_changed;
        }
        return .none;
    }
    if (optIs(opt, "shell_key_binding") and std.mem.eql(u8, choice, "custom")) {
        startKeybindEditing(st, env);
        return .none;
    }
    saveChoice(st, env, opt.id, choice);
    return .none;
}

fn commitDropdown(st: *State, env: Env, opt: spec_mod.SettingOption, choice: []const u8) Effect {
    st.dropdown_opt_idx = null;
    env.popup_msg.* = null;
    return applyChoice(st, env, opt, choice);
}

/// A digit typed while the dropdown is open picks that choice directly.
pub fn dropdownPrintable(st: *State, env: Env, b: u8) Effect {
    const opt_idx = st.dropdown_opt_idx orelse return .none;
    const opt = env.spec.settings.options[opt_idx];
    const choices = opt.choices orelse return .none;
    if (b < '1' or b > '0' + @as(u8, @intCast(choices.len))) return .none;
    return commitDropdown(st, env, opt, choices[b - '1']);
}

/// Key dispatch while the dropdown modal is open.
pub fn dropdownKey(st: *State, env: Env, key: input_mod.Key, action: input_mod.Action) Effect {
    const opt_idx = st.dropdown_opt_idx orelse return .none;
    const opt = env.spec.settings.options[opt_idx];
    if (key == .esc or action == .quit) {
        st.dropdown_opt_idx = null;
        env.popup_msg.* = null;
    } else if (key == .up or action == .nav_up) {
        if (opt.choices) |choices| {
            st.dropdown_sel = if (st.dropdown_sel > 0) st.dropdown_sel - 1 else choices.len - 1;
        }
    } else if (key == .down or action == .nav_down) {
        if (opt.choices) |choices| st.dropdown_sel = (st.dropdown_sel + 1) % choices.len;
    } else if (key == .enter or key == .space or action == .select) {
        if (opt.choices) |choices| return commitDropdown(st, env, opt, choices[st.dropdown_sel]);
    }
    return .none;
}

/// Build the dropdown modal body into `buf` and point the popup at it.
/// Choice captions come from spec/settings.yaml `choice_help`
/// (index-aligned with `choices`).
pub fn dropdownPopup(st: *State, env: Env, buf: []u8) void {
    const opt_idx = st.dropdown_opt_idx orelse return;
    const opt = env.spec.settings.options[opt_idx];
    env.popup_title.* = opt.label;
    var pos: usize = 0;
    if (opt.choices) |choices| {
        for (choices, 0..) |choice, ci| {
            const is_selected = (ci == st.dropdown_sel);
            const prefix = if (is_selected) "> " else "  ";
            const bold_start = if (is_selected) term.BOLD else "";
            const bold_end = if (is_selected) term.BOLD_OFF else "";
            const caption: ?[]const u8 = if (opt.choice_help) |ch|
                (if (ci < ch.len) ch[ci] else null)
            else
                null;
            const line = if (caption) |cap|
                std.fmt.bufPrint(buf[pos..], "{s}{s}{s}: {s}{s}\n", .{ prefix, bold_start, choice, cap, bold_end }) catch break
            else
                std.fmt.bufPrint(buf[pos..], "{s}{s}{s}{s}\n", .{ prefix, bold_start, choice, bold_end }) catch break;
            pos += line.len;
        }
    }
    env.popup_msg.* = if (pos > 0) buf[0 .. pos - 1] else "";
}

/// Printable char while the keybind editor is active.
pub fn keybindPrintable(st: *State, env: Env, b: u8) void {
    if (b >= 32 and b <= 126 and st.keybind_input_len < st.keybind_input_buf.len) {
        st.keybind_input_buf[st.keybind_input_len] = b;
        st.keybind_input_len += 1;
        env.shell_key_binding.* = st.keybind_input_buf[0..st.keybind_input_len];
    }
}

/// Key dispatch while the keybind editor is active: Backspace deletes,
/// Enter commits + persists, Esc reverts to the committed value.
pub fn keybindKey(st: *State, env: Env, key: input_mod.Key) void {
    switch (key) {
        .backspace => if (st.keybind_input_len > 0) {
            st.keybind_input_len -= 1;
            env.shell_key_binding.* = st.keybind_input_buf[0..st.keybind_input_len];
        },
        .enter => {
            st.keybind_editing = false;
            st.keybind_committed_len = @min(st.keybind_input_len, st.keybind_committed_buf.len);
            @memcpy(st.keybind_committed_buf[0..st.keybind_committed_len], st.keybind_input_buf[0..st.keybind_committed_len]);
            env.shell_key_binding.* = st.keybind_committed_buf[0..st.keybind_committed_len];
            config.saveKeyToConfig(env.io, "shell_key_binding", env.shell_key_binding.*);
        },
        .esc => {
            st.keybind_editing = false;
            env.shell_key_binding.* = st.keybind_committed_buf[0..st.keybind_committed_len];
        },
        else => {},
    }
}

/// Toggle the context-sensitive help modal for the selected row — the same
/// key closes it again.
pub fn toggleHelp(env: Env, idx: usize) void {
    env.popup_title.* = env.spec.strings.setting_help_title;
    env.popup_msg.* = if (env.popup_msg.* == null) settingHelp(env.spec, idx) else null;
}

/// F1 opens the help modal (closing an open one is handled by the shared
/// popup-dismiss keys before dispatch reaches the settings screen).
pub fn openHelp(env: Env, idx: usize) void {
    env.popup_title.* = env.spec.strings.setting_help_title;
    env.popup_msg.* = settingHelp(env.spec, idx);
}

/// Printable char on the settings screen (no dropdown/editor active):
/// `?`/`h` toggle the help modal, digits type into a selected grid-dim row.
pub fn printable(st: *State, env: Env, selected_idx: ?usize, b: u8) void {
    if (b == '?' or b == 'h') {
        toggleHelp(env, selected_idx orelse 0);
        return;
    }
    if (b < '0' or b > '9') return;
    const sel = selected_idx orelse return;
    const is_cols = gridDimAt(env.spec, sel) orelse return;
    const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
    const v = if (is_cols) env.grid_cols else env.grid_rows;
    config.typeGridDim(v, b, st.griddim_typing, max);
    st.griddim_typing = true;
    st.griddim_changed = true;
    config.saveUsizeToConfig(env.io, if (is_cols) "cols" else "rows", v.*);
}

/// Activate a settings row (mouse click or Enter/Space). `local_col` is the
/// click column for the grid-dim ‹/› hit-zones; null means keyboard, which
/// steps the value coarsely (`grid_dim_step`, wrapping at the max) instead.
pub fn activate(st: *State, env: Env, opt_idx: usize, local_col: ?i32) Effect {
    const opt = env.spec.settings.options[opt_idx];
    if (std.mem.eql(u8, opt.type, "choice")) {
        openDropdown(st, env, opt_idx);
    } else if (gridDimAt(env.spec, opt_idx)) |is_cols| {
        st.griddim_typing = false;
        const v = if (is_cols) env.grid_cols else env.grid_rows;
        if (local_col) |lc| {
            if (config.applyGridDimClick(env.io, is_cols, lc, v)) st.griddim_changed = true;
        } else {
            const step_n = env.spec.layout.interaction.grid_dim_step;
            const min = if (is_cols) defaults.MIN_COLS else defaults.MIN_ROWS;
            const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
            v.* = config.cycleGridDim(v.*, step_n, min, max);
            config.saveUsizeToConfig(env.io, opt.id, v.*);
            st.griddim_changed = true;
        }
    } else if (optIs(opt, "clear_mru")) {
        mru.clear();
        env.popup_title.* = env.spec.strings.done_title;
        env.popup_msg.* = env.spec.strings.mru_cleared;
    } else {
        toggleSetting(st, env, opt);
    }
    return .none;
}

/// Left/Right on a settings row: ±1 on grid dims, forward/back cycle on
/// choices (theme applies live), plain toggle on booleans. Text and action
/// rows ignore the keys.
pub fn step(st: *State, env: Env, opt_idx: usize, increase: bool) Effect {
    const opt = env.spec.settings.options[opt_idx];
    st.griddim_typing = false;
    if (gridDimAt(env.spec, opt_idx)) |is_cols| {
        const v = if (is_cols) env.grid_cols else env.grid_rows;
        const min = if (is_cols) defaults.MIN_COLS else defaults.MIN_ROWS;
        const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
        v.* = config.stepGridDim(v.*, increase, min, max);
        config.saveUsizeToConfig(env.io, opt.id, v.*);
        st.griddim_changed = true;
    } else if (std.mem.eql(u8, opt.type, "choice")) {
        if (opt.choices) |choices| {
            const cur = choiceIndex(opt, currentChoiceValue(env, opt));
            const next = if (increase) (cur + 1) % choices.len else (cur + choices.len - 1) % choices.len;
            return applyChoice(st, env, opt, choices[next]);
        }
    } else if (std.mem.eql(u8, opt.type, "boolean")) {
        toggleSetting(st, env, opt);
    }
    return .none;
}

/// Backspace on a grid-dim row resets it to the spec default and ends the
/// typing run, so the next digit starts a fresh number.
pub fn resetGridDim(st: *State, env: Env, opt_idx: usize) void {
    const is_cols = gridDimAt(env.spec, opt_idx) orelse return;
    const v = if (is_cols) env.grid_cols else env.grid_rows;
    const spec_default = if (is_cols) env.spec.layout.tui.cols else env.spec.layout.tui.rows;
    const min = if (is_cols) defaults.MIN_COLS else defaults.MIN_ROWS;
    const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
    v.* = config.clampGridDim(spec_default, min, max);
    config.saveUsizeToConfig(env.io, if (is_cols) "cols" else "rows", v.*);
    st.griddim_changed = true;
    st.griddim_typing = false;
}

/// Clear transient edit state when leaving a row or the screen: finalize a
/// digit-typing run (min clamp on commit) and drop hover/editing flags.
pub fn endNav(st: *State, env: Env, selected_idx: ?usize) void {
    st.keybind_editing = false;
    if (st.griddim_typing) {
        const is_cols = if (selected_idx) |sel| gridDimAt(env.spec, sel) else null;
        config.finalizeGridTyping(env.io, is_cols, env.grid_cols, env.grid_rows);
    }
    st.griddim_typing = false;
    st.hover_left = false;
    st.hover_right = false;
}

/// Motion event over the settings list: select the row under the cursor and
/// highlight the ‹/› halves of a grid-dim row (same hit-zones as
/// config.applyGridDimClick: cols 3–5 ‹, 8–10 ›).
pub fn hover(st: *State, env: Env, selected_idx: *?usize, list_row: ?usize, local_col: i32) void {
    st.hover_left = false;
    st.hover_right = false;
    const ri = list_row orelse return;
    const opt_idx = st.scroll_top + ri;
    if (opt_idx >= env.spec.settings.options.len) return;
    selected_idx.* = opt_idx;
    if (gridDimAt(env.spec, opt_idx) != null) {
        st.hover_left = local_col >= 3 and local_col <= 5;
        st.hover_right = local_col >= 8 and local_col <= 10;
    }
}

// ---------------------------------------------------------------------------
// Tests (pure parts only — nothing here touches the config file)
// ---------------------------------------------------------------------------

const test_options = [_]spec_mod.SettingOption{
    .{ .id = "shell_integration", .type = "boolean", .label = "shell integration", .default = "false" },
    .{ .id = "shell_key_binding", .type = "choice", .label = "shell key binding", .default = "C-o", .choices = &.{ "C-o", "C-e", "custom" }, .choice_help = &.{ "leaves C-e free", "blocks end-line" } },
    .{ .id = "theme", .type = "choice", .label = "theme", .default = "dark", .choices = &.{ "dark", "light", "system" }, .help = "theme help" },
    .{ .id = "cols", .type = "integer", .label = "grid width (cols)", .default = "8" },
    .{ .id = "rows", .type = "integer", .label = "grid height (rows)", .default = "10" },
};

fn testSpec() spec_mod.Spec {
    var s: spec_mod.Spec = undefined;
    s.settings = .{ .title = "settings", .help_fallback = "fallback", .options = &test_options };
    return s;
}

test "gridDimAt maps ids, not indices" {
    const s = testSpec();
    try std.testing.expectEqual(@as(?bool, null), gridDimAt(&s, 0));
    try std.testing.expectEqual(@as(?bool, true), gridDimAt(&s, 3));
    try std.testing.expectEqual(@as(?bool, false), gridDimAt(&s, 4));
    try std.testing.expectEqual(@as(?bool, null), gridDimAt(&s, 99));
}

test "settingHelp prefers per-option text, falls back otherwise" {
    const s = testSpec();
    try std.testing.expectEqualStrings("theme help", settingHelp(&s, 2));
    try std.testing.expectEqualStrings("fallback", settingHelp(&s, 0));
    try std.testing.expectEqualStrings("fallback", settingHelp(&s, 99));
}

test "cycleTheme round-trips forward and backward" {
    try std.testing.expectEqual(Theme.light, cycleTheme(.dark, true));
    try std.testing.expectEqual(Theme.system, cycleTheme(.light, true));
    try std.testing.expectEqual(Theme.dark, cycleTheme(.system, true));
    inline for (.{ Theme.dark, Theme.light, Theme.system }) |t| {
        try std.testing.expectEqual(t, cycleTheme(cycleTheme(t, true), false));
    }
}

test "choiceIndex finds exact value, falls back to custom, else first" {
    const s = testSpec();
    const keybind = s.settings.options[1];
    try std.testing.expectEqual(@as(usize, 1), choiceIndex(keybind, "C-e"));
    // A hand-edited binding not in the list selects the "custom" row.
    try std.testing.expectEqual(@as(usize, 2), choiceIndex(keybind, "C-x q"));
    const theme_opt = s.settings.options[2];
    try std.testing.expectEqual(@as(usize, 0), choiceIndex(theme_opt, "nonsense"));
}

test "openDropdown preselects the live theme value" {
    const s = testSpec();
    var st = State{};
    var theme_val: Theme = .system;
    var env: Env = undefined;
    env.spec = &s;
    env.theme = &theme_val;
    openDropdown(&st, env, 2);
    try std.testing.expectEqual(@as(?usize, 2), st.dropdown_opt_idx);
    try std.testing.expectEqual(@as(usize, 2), st.dropdown_sel);
}

test "dropdownKey navigates with wrap and esc closes" {
    const s = testSpec();
    var st = State{};
    var popup: ?[]const u8 = "open";
    var env: Env = undefined;
    env.spec = &s;
    env.popup_msg = &popup;
    st.dropdown_opt_idx = 2;
    st.dropdown_sel = 0;
    _ = dropdownKey(&st, env, .up, .none);
    try std.testing.expectEqual(@as(usize, 2), st.dropdown_sel); // wraps to last
    _ = dropdownKey(&st, env, .down, .none);
    try std.testing.expectEqual(@as(usize, 0), st.dropdown_sel);
    _ = dropdownKey(&st, env, .esc, .none);
    try std.testing.expectEqual(@as(?usize, null), st.dropdown_opt_idx);
    try std.testing.expectEqual(@as(?[]const u8, null), popup);
}

test "dropdownPopup lists choices with spec captions and bold cursor" {
    const s = testSpec();
    var st = State{};
    st.dropdown_opt_idx = 1;
    st.dropdown_sel = 0;
    var popup: ?[]const u8 = null;
    var title: []const u8 = "";
    var env: Env = undefined;
    env.spec = &s;
    env.popup_msg = &popup;
    env.popup_title = &title;
    var buf: [512]u8 = undefined;
    dropdownPopup(&st, env, &buf);
    try std.testing.expectEqualStrings("shell key binding", title);
    const expected = "> " ++ term.BOLD ++ "C-o: leaves C-e free" ++ term.BOLD_OFF ++ "\n" ++
        "  C-e: blocks end-line\n" ++
        "  custom";
    try std.testing.expectEqualStrings(expected, popup.?);
}

test "keybind editor buffers: type, backspace, esc reverts" {
    const s = testSpec();
    var st = State{};
    var binding: []const u8 = "C-o";
    var popup: ?[]const u8 = null;
    var env: Env = undefined;
    env.spec = &s;
    env.shell_key_binding = &binding;
    env.popup_msg = &popup;
    startKeybindEditing(&st, env);
    try std.testing.expect(st.keybind_editing);
    try std.testing.expectEqualStrings("C-o", binding);
    keybindPrintable(&st, env, ' ');
    keybindPrintable(&st, env, 'x');
    try std.testing.expectEqualStrings("C-o x", binding);
    keybindKey(&st, env, .backspace);
    try std.testing.expectEqualStrings("C-o ", binding);
    keybindKey(&st, env, .esc);
    try std.testing.expect(!st.keybind_editing);
    try std.testing.expectEqualStrings("C-o", binding);
}

test "hover selects row under cursor and flags grid-dim arrows" {
    const s = testSpec();
    var st = State{};
    var env: Env = undefined;
    env.spec = &s;
    var sel: ?usize = null;
    hover(&st, env, &sel, 3, 4); // row 3 = "cols", col 4 in ‹ zone
    try std.testing.expectEqual(@as(?usize, 3), sel);
    try std.testing.expect(st.hover_left);
    try std.testing.expect(!st.hover_right);
    hover(&st, env, &sel, 0, 4); // boolean row: no arrow zones
    try std.testing.expectEqual(@as(?usize, 0), sel);
    try std.testing.expect(!st.hover_left);
    hover(&st, env, &sel, null, 4); // off the list: selection untouched
    try std.testing.expectEqual(@as(?usize, 0), sel);
}
