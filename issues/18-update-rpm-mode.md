# Issue 18 — `:update` command: RPM install mode

**Priority:** P3
**Status:** Open

## Summary

The `:update` command (added alongside `make update`) cannot self-update when emojig was installed via `.rpm`. The current implementation detects dev-mode (`~/projects/emojig`), deb (`dpkg`), and curl-install (`~/.local/bin/emojig`) — RPM falls through to the "unknown install mode" message.

## Detection

An RPM-installed emojig can be detected via:

```sh
rpm -q emojig >/dev/null 2>&1          # package present
# or by presence of the rpm database entry:
test -f /var/lib/rpm/Packages           # rpm db exists
```

A tighter check from Zig would be:
```zig
fileExistsAbs("/var/lib/rpm/Packages") and !fileExistsAbs("/var/lib/dpkg/info/emojig.list")
```

## Update Command

If emojig is available in the configured DNF/YUM repo:
```sh
sudo dnf upgrade emojig
# or
sudo yum update emojig
```

If not in a repo (manual .rpm install from Codeberg Releases), the update must download the latest `.rpm` and install it:
```sh
# detect arch
ARCH=$(uname -m)
TAG=$(curl -sSf https://codeberg.org/api/v1/repos/ubunatic/emojig/releases/latest \
      | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
VERSION=${TAG#v}
curl -Lo /tmp/emojig.rpm \
  "https://codeberg.org/ubunatic/emojig/releases/download/${TAG}/emojig-${VERSION}-${ARCH}-linux.rpm"
sudo rpm -U /tmp/emojig.rpm
```

## Implementation Notes

- `captureShellCmd` (in `src/main.zig`) already handles running a shell command and capturing output to `/tmp/emojig-update.log` — just add an RPM branch in `runUpdate`.
- Add detection before the curl-install fallback in `runUpdate`.
- The `popup_buf` is 1024 bytes; rpm output fits easily.
- `sudo` prompts will not be visible in the popup (they write to `/dev/tty` directly). Consider a `pkexec` or `sudo -A` wrapper if passwordless sudo is not configured.

## GoReleaser Config

GoReleaser already produces `.rpm` artifacts (`dist/*.rpm`). Ensure the RPM `name` field matches `emojig` (not `emojig-picker` or similar) so `rpm -q emojig` detects it.
