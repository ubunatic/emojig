# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig bash integration — source this from ~/.bashrc
# Ctrl+E inserts the selected emoji at the cursor position.

_emojig_widget() {
  local emoji
  emoji=$(emojig </dev/tty)
  if test -n "$emoji"
  then
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${emoji}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$(( READLINE_POINT + ${#emoji} ))
  fi
}
_emojig_key="${EMOJIG_KEY:-\\C-e}"
case "$_emojig_key" in
  *'"'*|*':'*|*$'\n'*) echo "emojig: unsafe EMOJIG_KEY value ignored, using default" >&2
    _emojig_key="\\C-e" ;;
esac
bind -x "\"${_emojig_key}\": _emojig_widget"
unset _emojig_key
