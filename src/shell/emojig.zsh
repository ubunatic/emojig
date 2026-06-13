# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig zsh integration — source this from ~/.zshrc

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

_emojig_integration="true"
_emojig_key="^E"

if test -f ~/.config/emojig/config; then
  _cfg_int=$(grep "^shell_integration=" ~/.config/emojig/config | cut -d= -f2)
  if test "$_cfg_int" = "false" || test "$_cfg_int" = "0"; then
    _emojig_integration="false"
  fi
  _cfg_key=$(grep "^shell_key_binding=" ~/.config/emojig/config | cut -d= -f2)
  if test "$_cfg_key" = "none"; then
    _emojig_key="none"
  elif test -n "$_cfg_key"; then
    if test "$_cfg_key" = "C-e"; then
      _emojig_key="^E"
    else
      _emojig_key="$_cfg_key"
    fi
  fi
fi

if test "$_emojig_integration" = "true" && test "$_emojig_key" != "none"; then
  zle -N _emojig_widget
  bindkey -- "$_emojig_key" _emojig_widget
fi

unset _emojig_integration
unset _emojig_key
