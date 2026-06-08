#!/bin/sh
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Emojig: Terminal state diagnostic tool (issue #13).
# Prints a human-readable snapshot of active terminal modes so you can
# confirm whether emojig (or any other TUI) left the terminal dirty.
#
# Usage:
#   scripts/termstate.sh            # print current terminal state
#   scripts/termstate.sh --watch    # re-run every 2 s (Ctrl-C to stop)
#
# Typical workflow for debugging issue #12 (cleanup / scroll-region leak):
#   scripts/termstate.sh      # baseline -- all modes should show OK
#   emojig --tui              # run and exit (or Ctrl-E, subshell, etc.)
#   scripts/termstate.sh      # compare -- leaked modes appear as LEAKED
#
# Supported terminals: foot, kitty, alacritty, xterm, wezterm.
#
# How replies are consumed:
#   DECRQM / DECRQSS replies end with $y / ESC-backslash, NOT a newline.
#   Plain `read -t` reads until newline so it always times out and leaves
#   the reply bytes sitting in the tty buffer, which the shell then reads
#   as a spurious command (causing the beep you heard).
#   Instead we switch the tty to raw mode (stty raw -echo min 0 time N)
#   and drain it with `dd`, which returns after the timeout regardless of
#   line endings, cleanly consuming every reply byte before restoring state.

# ── helpers ──────────────────────────────────────────────────────────────────

ok()      { printf '  \033[1;32mOK\033[0m      %s\n' "$*"; }
leaked()  { printf '  \033[1;31mLEAKED\033[0m  %s\n' "$*"; }
unknown() { printf '  \033[1;33m??\033[0m      %s (terminal did not reply)\n' "$*"; }
header()  { printf '\n\033[1;34m── %s\033[0m\n' "$*"; }
die()     { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

# ── tty query engine ─────────────────────────────────────────────────────────

# Saved terminal state -- restored by trap on any exit / signal.
_TTY_SAVED=""

_restore_tty() {
    if test -n "$_TTY_SAVED"
    then
        stty -F /dev/tty "$_TTY_SAVED" 2>/dev/null
        _TTY_SAVED=""
    fi
}
trap '_restore_tty' INT TERM EXIT

# query_tty TIMEOUT_TENTHS SEQUENCE
#   Send SEQUENCE (printf %b) to /dev/tty and read the terminal's reply.
#   TIMEOUT_TENTHS is in 1/10 s units (stty 'time=' value): 3 = 0.3 s.
#   Switches the tty to raw mode so dd returns after the timeout without
#   waiting for a newline -- this is what prevents replies from leaking
#   into the shell's stdin buffer.
#   Sets global $REPLY to the raw reply bytes (may contain ESC characters).
query_tty() {
    _timeout=$1
    _seq=$2
    REPLY=""
    # Save state; bail safely if /dev/tty is not a real terminal.
    _TTY_SAVED=$(stty -F /dev/tty -g 2>/dev/null) || return 1
    # raw: no line discipline; -echo: suppress local echo of reply;
    # min 0: don't require any minimum bytes; time N: return after N/10 s.
    stty -F /dev/tty raw -echo min 0 time "$_timeout" 2>/dev/null || {
        _restore_tty; return 1
    }
    printf '%b' "$_seq" >/dev/tty
    # dd reads up to bs bytes in one syscall; returns on timeout with whatever arrived.
    REPLY=$(dd if=/dev/tty bs=64 count=1 2>/dev/null)
    _restore_tty
}

# decrqm MODE  -- DEC Request Mode: CSI ? Ps $ p
decrqm() {
    query_tty 3 "\\033[?${1}\$p"
}

# decrqm_status -- extract Pm from DECRQM reply "ESC [ ? Ps ; Pm $ y"
#   Strip everything except digits / semicolons / $ / y, then sed out Pm.
#   Returns: "1"=set "2"=reset "3"=perm-set "4"=perm-reset "" =no reply
decrqm_status() {
    printf '%s' "$REPLY" \
        | tr -cd '0-9;$y' \
        | sed 's/[0-9]*;\([0-9]*\)\$y.*/\1/'
}

# decrqss PARAM -- DEC Request Status String: DCS $ q Param ST
decrqss() {
    query_tty 3 "\\033P\$q${1}\\033\\\\"
}

# decrqss_param -- extract Pt from DECRQSS reply "ESC P 1 $ r Pt ST"
#   Strip everything except digits / semicolons / $ / r, then sed out Pt.
decrqss_param() {
    printf '%s' "$REPLY" \
        | tr -cd '0-9;$r' \
        | sed 's/.*1\$r\([0-9;]*r\).*/\1/'
}

# ── checks ────────────────────────────────────────────────────────────────────

check_stty() {
    header "Raw mode / cooked mode (stty)"
    _stty=$(stty -F /dev/tty -a 2>/dev/null || stty -a 2>/dev/null)
    printf '  %s\n' "$(printf '%s' "$_stty" | tr ';' '\n' \
        | grep -E '(^| )-?icanon|(^| )-?echo|(^| )-?raw|(^| )-?isig' | xargs)"
    if printf '%s' "$_stty" | grep -q ' icanon'
    then ok "icanon set (cooked mode -- normal)"
    else leaked "icanon NOT set -- terminal may be stuck in raw mode"
    fi
    if printf '%s' "$_stty" | grep -q ' echo'
    then ok "echo set (normal)"
    else leaked "echo NOT set -- keystrokes will be invisible"
    fi
}

check_scroll_region() {
    header "Scroll region (DECSTBM)"
    decrqss "r"
    _p=$(decrqss_param)
    _rows=$(stty -F /dev/tty size 2>/dev/null | cut -d' ' -f1)
    if test -z "$_rows"
    then _rows=$(tput lines 2>/dev/null)
    fi
    if test -z "$_p"
    then
        unknown "scroll region (DECRQSS)"
    else
        printf '  Current:  %s\n' "$_p"
        printf '  Terminal: %s rows\n' "${_rows:-unknown}"
        _top=$(printf '%s' "$_p" | cut -d';' -f1 | tr -d 'r ')
        _bot=$(printf '%s' "$_p" | cut -d';' -f2 | tr -d 'r ')
        if test "$_top" = "1" && { test "$_bot" = "$_rows" || test "$_bot" = "0"; }
        then ok "scroll region covers full terminal (normal)"
        elif test "$_top" = "1" && test -z "$_bot"
        then ok "scroll region covers full terminal (normal)"
        else leaked "scroll region is ${_p} -- does NOT cover full ${_rows} rows (emojig forgot \\x1b[r)"
        fi
    fi
}

check_cursor_vis() {
    header "Cursor visibility (mode ?25)"
    decrqm 25
    _s=$(decrqm_status)
    if test -z "$_s"
    then unknown "?25"
    elif test "$_s" = "1" || test "$_s" = "3"
    then ok "?25 SET (cursor visible -- normal)"
    else leaked "?25 RESET -- cursor is hidden (emojig forgot \\x1b[?25h)"
    fi
}

check_mouse_1003() {
    header "Mouse any-event tracking (mode ?1003)"
    decrqm 1003
    _s=$(decrqm_status)
    if test -z "$_s"
    then unknown "?1003"
    elif test "$_s" = "2" || test "$_s" = "4"
    then ok "?1003 RESET (not tracking)"
    else leaked "?1003 SET -- mouse tracking still active (emojig forgot \\x1b[?1003l)"
    fi
}

check_mouse_1006() {
    header "Mouse SGR coordinate encoding (mode ?1006)"
    decrqm 1006
    _s=$(decrqm_status)
    if test -z "$_s"
    then unknown "?1006"
    elif test "$_s" = "2" || test "$_s" = "4"
    then ok "?1006 RESET (normal)"
    else leaked "?1006 SET -- SGR mouse encoding still active (emojig forgot \\x1b[?1006l)"
    fi
}

check_alt_screen() {
    header "Alternate screen buffer (mode ?1049)"
    decrqm 1049
    _s=$(decrqm_status)
    if test -z "$_s"
    then unknown "?1049"
    elif test "$_s" = "2" || test "$_s" = "4"
    then ok "?1049 RESET (normal screen -- correct for inline TUI)"
    else leaked "?1049 SET -- alternate screen still active"
    fi
}

check_bracketed_paste() {
    header "Bracketed paste mode (mode ?2004)"
    decrqm 2004
    _s=$(decrqm_status)
    if test -z "$_s"
    then unknown "?2004"
    elif test "$_s" = "1" || test "$_s" = "3"
    then ok "?2004 SET (bracketed paste active -- normal for most shells)"
    else ok "?2004 RESET (bracketed paste off)"
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

if ! test -c /dev/tty
then die "/dev/tty is not available -- cannot query terminal state"
fi

run_all() {
    printf '\033[1mTerminal State Snapshot\033[0m  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    check_stty
    check_scroll_region
    check_cursor_vis
    check_mouse_1003
    check_mouse_1006
    check_alt_screen
    check_bracketed_paste
    printf '\n'
}

if test "$1" = "--watch"
then
    while true
    do
        clear
        run_all
        sleep 2
    done
else
    run_all
fi
