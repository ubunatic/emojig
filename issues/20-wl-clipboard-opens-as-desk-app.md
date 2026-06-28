---
status: open
priority: p2
---

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
 
# Gemini Research
This issue stems from a classic conflict between how **`wl-clipboard`** handles state and how modern Wayland compositors (specifically **GNOME Shell / Mutter**) prevent background focus stealing.

---

## 1. Why This Happens

Unlike traditional X11 copy utilities (`xclip` / `xsel`) that push data into a global buffer and exit instantly, **Wayland clipboard operations are lazy**.

* When `wl-copy` is executed, it establishes a Wayland client connection, advertises its MIME types, and **must remain alive** in the background to serve data whenever another app requests a paste.
* When you call `wl-copy` rapidly during a "Fast Multi-Select" action, you are spawning a flurry of ephemeral Wayland clients in milliseconds.
* GNOME Shell detects these incoming Wayland connections as application startup events. Because `wl-copy` has no `.desktop` file or mapping window, GNOME's **Focus Stealing Prevention** mechanism drops a generic "Unknown" application icon onto the Dock and triggers the infamous **`"<Unknown> is ready"`** desktop notification because a background process requested window/system-level attention without explicit user focus context.

---

## 2. Step-by-Step Improvements

To fix the dock wiggling and notifications within `emojig`, implement the following tactical updates:

### Step 1: Implement a Debounce Mechanism

Do not call `wl-copy` on every individual selection toggle or cursor movement during multi-select.

* **Action:** Introduce a **150ms–300ms debounce timer**.
* **Logic:** When an item is toggled, start/reset a timer. Only invoke the external `wl-copy` process when the user stops navigating or has finalized their batch operation.

### Step 2: Cleanly Manage the Lifecycle of the Previous Process

Because each `wl-copy` run spawns a persistent background instance, spawning a new one without cleaning up the previous one can clog the process list before they auto-terminate on clipboard eviction.

* **Action:** Before spawning a new `wl-copy` process, explicitly send a termination signal (`SIGTERM`) to the previous execution instance managed by `emojig`.

### Step 3: Strip Workspace/Startup Tracking from the Command

When launching `wl-copy` from your code, ensure it is completely decoupled from any environment-inherited startup tracking. You can clear the startup notification env variable context when executing the command:

```bash
# Clear the activation/startup token from the child environment
env -u XDG_ACTIVATION_TOKEN -u DESKTOP_STARTUP_ID wl-copy "your-emoji-string"

```

---

## 3. Alternative Perspectives & Long-Term Fixes

Depending on how deeply you want to refactor the terminal clipboard architecture of `emojig`, consider these alternative paths:

### Perspective A: Leverage OSC 52 (The Terminal Native Approach)

The absolute cleanest approach for a TUI app is to completely bypass external CLI utilities like `wl-copy` and use **OSC 52 ANSI escape sequences**.

* **How it works:** Your TUI prints a specific escape sequence directly to `stdout`:

$$\text{ESC } ] \ 52 \ ; \ c \ ; \ \text{Base64(text)} \ \backslash a$$


* **Pros:** Bypasses `wl-copy` entirely. Modern terminal emulators process this sequence instantly, updating the system clipboard cleanly without sparking GNOME’s background application tracker or wiggling the dock.
* **Cons:** Requires the user's terminal emulator to have OSC 52 support enabled (though almost all major ones do).

### Perspective B: Batch Operations over Streamed Data

If you prefer sticking to `wl-copy`, avoid running it inside a loop. Collect the final multi-select array entirely within memory inside your TUI state, and pipe the complete newline-separated string to a single standalone invocation of `wl-copy` once the multi-select session concludes or gets explicitly confirmed.

---

## 4. Practical Action Plan

1. **Quick Fix:** Wrap the `wl-copy` execution thread in your codebase with a **debounce filter** to ensure it fires at most once per multi-select pause.
2. **Robust Cleanup:** Keep a handle on the spawned child process PID inside `emojig`. If a new copy event fires before the debounce timer finishes, kill the older pending process first.
3. **Best Practice Upgrade:** Evaluate adding **OSC 52** support to `emojig`. It will provide a lightning-fast, zero-dependency experience for terminal power-users that avoids Wayland compositor notification edge-cases completely.

