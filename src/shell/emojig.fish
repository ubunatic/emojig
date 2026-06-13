# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig fish integration — source this from ~/.config/fish/config.fish

function _emojig_widget
    set emoji (emojig </dev/tty)
    if test -n "$emoji"
        commandline --insert $emoji
    end
end

set -l _emojig_integration "true"
set -l _emojig_key "\ce"

if test -f ~/.config/emojig/config
    set -l _cfg_int (grep "^shell_integration=" ~/.config/emojig/config | cut -d= -f2)
    if test "$_cfg_int" = "false" -o "$_cfg_int" = "0"
        set _emojig_integration "false"
    end
    set -l _cfg_key (grep "^shell_key_binding=" ~/.config/emojig/config | cut -d= -f2)
    if test "$_cfg_key" = "none"
        set _emojig_key "none"
    else if test "$_cfg_key" = "C-e"
        set _emojig_key \ce
    else if test -n "$_cfg_key"
        set _emojig_key $_cfg_key
    end
end

if test "$_emojig_integration" = "true" -a "$_emojig_key" != "none"
    bind $_emojig_key _emojig_widget
end
