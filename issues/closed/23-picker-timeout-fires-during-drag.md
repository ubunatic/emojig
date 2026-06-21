# 23 — Picker Timeout Fires During Scrollbar Drag

## Bug

In GUI mode (`emojig --gui`), `EMOJIG_PICKER_TIMEOUT` (default 60 s) closes
the app while the user is still interacting via scrollbar drag.

## Root Cause

The inactivity timeout is implemented as a `poll(timeout_ms)` deadline
recomputed each loop iteration from the raw `active_timeout` value (seconds).
This gives each call to `poll()` a fresh full-length countdown.

The scrollbar drag generates SGR motion events (`?1003h`) only while the mouse
is *moving*. If the user holds the button still at the bottom of the track for
more than `active_timeout` seconds without any other input, no events arrive,
the poll deadline fires, and the app exits.

From the user's perspective this is surprising: the pick session is "active"
(they have the mouse button held down) but the app disappears.

## Expected Behaviour

The timeout should measure *time since last user input event* (any `.tty`
event), not *time since start of the current poll call*.

## Fix Approach

Track `last_input_ms = getMonotonicMs()` and update it in the `.tty` branch.
Compute `timeout_ms` as `max(0, deadline_ms - now_ms)` where
`deadline_ms = last_input_ms + active_timeout_ms`. This way the countdown only
advances during genuine idle time.

```zig
// Near variable init (before while loop):
var last_input_ms: i64 = getMonotonicMs();

// In the timeout_ms calculation:
var timeout_ms: i32 = if (active_timeout) |t_sec| blk: {
    const deadline = last_input_ms + @as(i64, t_sec) * 1_000;
    const remaining = deadline - getMonotonicMs();
    break :blk if (remaining <= 0) 0 else @intCast(@min(remaining, 2_147_000));
} else -1;

// In the .tty branch (after readStdin):
last_input_ms = getMonotonicMs();
```
