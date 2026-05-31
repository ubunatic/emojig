# emojig fish integration — source this from ~/.config/fish/config.fish
# Ctrl+E inserts the selected emoji at the cursor position.

function _emojig_widget
    set emoji (emojig </dev/tty)
    if test -n "$emoji"
        commandline --insert $emoji
    end
end
set -q EMOJIG_KEY || set EMOJIG_KEY \ce
bind $EMOJIG_KEY _emojig_widget
