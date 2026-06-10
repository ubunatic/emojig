# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig zsh integration — source this from ~/.zshrc
# Ctrl+E inserts the selected emoji at the cursor position.

emojig() {
   if test $# -eq 0 && test -t 1
   then local emoji
        emoji=$(command emojig)
        if test -n "$emoji"
        then print -z -n "$emoji"
        fi
   else command emojig "$@"
   fi
}

_emojig_widget() {
   local emoji
   zle -I
   emoji=$(emojig)
   test -n "$emoji" && LBUFFER+="$emoji"
   zle reset-prompt
}

zle -N _emojig_widget
bindkey -- "${EMOJIG_KEY:-^E}" _emojig_widget
