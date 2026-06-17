# Fast Multi-Select calls wl-clipboard as visible desktop app

## Effects
1. An app appears in the Dock for a few ms.
   And closed instantly before the icon (default app unknown icon) appears
   This just lets the Bin/Trash icon below it wiggle a bit
2. Fast Multi-Select also calls wl-clipboard rapidly
   and Wayland decides to show a Desktop notifiation "wl-clipboard is ready"
   
## Expected Behavior
- no app ison for called tools
- no Bin/Trash wiggle
- no Desktop notifiation

## Idea
- debounce wl-clipboard calls
- and manage the called process ridigly (kill if it has issues or is too slow and does not behave as expected)
- check wl-clipboard (wl-copy?) docs and web docs for why this might happen and how to avoid
 


