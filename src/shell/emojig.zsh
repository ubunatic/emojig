# emojig zsh integration — source this from ~/.zshrc
# Ctrl+E inserts the selected emoji at the cursor position.

_emojig_widget() {
  local emoji
  zle -I
  emoji=$(emojig)
  test -n "$emoji" && LBUFFER+="$emoji"
  zle reset-prompt
}
zle -N _emojig_widget
bindkey -- "${EMOJIG_KEY:-^E}" _emojig_widget
