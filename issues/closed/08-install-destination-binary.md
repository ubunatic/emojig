# Issue: `--install` copies binary to `~/.local/bin` even when running from system-wide paths

> [!NOTE]
> **Currency Status:** Resolved June 1, 2026. Fixed in `src/main.zig` via `isSystemPath()` auto-detection in `modeInstallLocal`, plus new `--install-shell`, `--install-system`, `--install-check` flags.

## Problem

When `emojig` is installed globally via a system package manager (e.g., `.deb` or `.rpm` packages which place the executable at `/usr/bin/emojig`), running `/usr/bin/emojig --install` (which is typically done to generate and register shell integration scripts under `~/.local/share/emojig/shell/`) still copies the executing binary to `~/.local/bin/emojig`.

This behavior leads to:
1. **Unnecessary File Duplication**: Storing identical copies of the small static binary on the same system.
2. **Version Skew / Shadowing**: When a package manager updates `/usr/bin/emojig`, the user's local shell or prompt will continue invoking the older, shadowed binary at `~/.local/bin/emojig` because `~/.local/bin` is usually prioritized before `/usr/bin` in the user's `PATH`.

---

## Cause

In `src/main.zig` within the `copyBinary` function (lines 471–472):

```zig
// Skip copy if already running from the destination.
if (std.mem.eql(u8, src_path, dst_path)) return true;
```

The logic only skips the copy operation if the executing binary (`src_path`) is *exactly* equal to the user's local installation destination (`dst_path`, i.e., `~/.local/bin/emojig`). Any execution from a system-wide folder (such as `/usr/bin`, `/usr/local/bin`, or `/opt`) fails this equality check and proceeds to copy itself into the user's home directory.

---

## Suggested Solutions

To resolve this issue, the installation sequence can be made more intelligent:

### Option A: Skip Binary Copy for Standard System Paths (Recommended)
Add a check in `copyBinary` or `installShellIntegration` to inspect if the active binary is already residing in standard system executable paths. If so, it should skip copying the binary and output a message indicating that the system-wide executable is being used, while still installing the shell integration scripts:

```zig
const is_system_path = std.mem.startsWith(u8, src_path, "/usr/bin/") or
                       std.mem.startsWith(u8, src_path, "/usr/local/bin/") or
                       std.mem.startsWith(u8, src_path, "/bin/");
if (is_system_path) {
    // Only install shell integration, skip copying binary
    return true; 
}
```

### Option B: Introduce Separate Flags
Split the installation steps or add a `--only-shell` / `--install-shell` flag so system packages or users can invoke:
```sh
emojig --install-shell
```
to exclusively setup shell rc sourcing without duplicating the binary.
