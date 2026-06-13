# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig bash integration — source this from ~/.bashrc

_emojig_widget() {
  local emoji
  emoji=$(emojig </dev/tty)
  if test -n "$emoji"
  then
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${emoji}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$(( READLINE_POINT + ${#emoji} ))
  fi
}

_emojig_integration="true"
_emojig_key="\\C-e"

if test -f ~/.config/emojig/config; then
  _cfg_int=$(grep "^shell_integration=" ~/.config/emojig/config | cut -d= -f2)
  if test "$_cfg_int" = "false" || test "$_cfg_int" = "0"; then
    _emojig_integration="false"
  fi
  _cfg_key=$(grep "^shell_key_binding=" ~/.config/emojig/config | cut -d= -f2)
  if test "$_cfg_key" = "none"; then
    _emojig_key="none"
  elif test -n "$_cfg_key"; then
    _emojig_key="$_cfg_key"
  fi
fi

if test "$_emojig_integration" = "true" && test "$_emojig_key" != "none"; then
  if test "$_emojig_key" = "C-e"; then
    _emojig_key="\\C-e"
  fi
  bind -x "\"${_emojig_key}\": _emojig_widget"
fi

unset _emojig_key
unset _emojig_integration
