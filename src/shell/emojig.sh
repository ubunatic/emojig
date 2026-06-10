# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: AGPL-3.0-or-later
# emojig shell integration — source from ~/.zshrc, ~/.bashrc, or any POSIX rc file
# Ctrl+E inserts the selected emoji at the cursor position.

if test -n "$ZSH_VERSION"
then source ~/.local/share/emojig/shell/emojig.zsh
elif test -n "$BASH_VERSION"
then source ~/.local/share/emojig/shell/emojig.bash
fi
