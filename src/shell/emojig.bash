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
bind -x "\"${EMOJIG_KEY:-\\C-e}\": _emojig_widget"
