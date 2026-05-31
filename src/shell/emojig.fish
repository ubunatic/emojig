# emojig fish integration — source this from ~/.config/fish/config.fish
# Ctrl+E inserts the selected emoji at the cursor position.

function _emojig_widget
    set emoji (emojig </dev/tty)
    if test -n "$emoji"
        commandline --insert $emoji
    end
end
bind \ce _emojig_widget
