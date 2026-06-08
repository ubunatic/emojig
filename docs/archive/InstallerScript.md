
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [TerminalIntegration.md](file:///home/uwe/projects/emojig/docs/TerminalIntegration.md)
> - **Extra Content Covered Here:** Walkthrough of installer script logic (`scripts/install.sh`), POSIX shell check command formatting, directory permission settings, and dependency checks.
> - **Outdated Information:** None.

---
# Managing the Installer Script (install.sh)

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Outlines the installation script architecture, Codeberg API dynamic resolution, and hosting strategies for **Emojig v0.1.5**.

This document outlines the architecture, implementation details, and hosting workflow for the **Emojig** lightweight POSIX installer script. The primary goal is to maintain a frictionless one-liner installation:

```sh
curl -sSf https://ubunatic.com/emojig/install.sh | sh
```

---

## 1. Design & Core Objectives

To ensure long-term stability and eliminate release friction, the installer script satisfies three core constraints:

1. **Zero Hardcoded Versions**: The script itself never changes when a new version of Emojig is cut. It dynamically resolves the latest tagged release at runtime.
2. **Zero Runtime Dependencies**: It relies purely on POSIX-compliant shell syntax and standard system utilities (`curl`, `tar`, `grep`, `cut`, `tr`, `uname`) pre-installed on Unix platforms. It does not require `jq`, Go, or compiler toolchains.
3. **Relocatable, Native Installation**: Automatically detects OS and CPU architecture, downloads the correct prebuilt musl-static `.tar.gz` archive, installs it into `~/.local/bin/`, and automatically triggers standard shell autocompletion setups.

---

## 2. Dynamic Version Resolution

The script resides in the Git repository at [scripts/install.sh](file:///home/uwe/projects/emojig/scripts/install.sh). 

Instead of hardcoding version numbers inside the script, it queries the **Codeberg API** dynamically at execution time to fetch the latest published tag:

```sh
# Fetch latest release tags from Codeberg API
API_RESP=$(curl -sSf "https://codeberg.org/api/v1/repos/ubunatic/emojig/releases")

# Clean POSIX sh extraction of the first "tag_name" field
TAG=$(echo "$API_RESP" | grep -o '"tag_name":"[^"]*"' | head -n 1 | cut -d':' -f2 | tr -d '"')
```

Once the tag (e.g. `v0.1.1`) is extracted, the script constructs the exact Codeberg release asset URL matching the host's platform:

```sh
ASSET_NAME="emojig-${TAG}-${TARGET_ARCH}-linux-musl.tar.gz"
DOWNLOAD_URL="https://codeberg.org/ubunatic/emojig/releases/download/${TAG}/${ASSET_NAME}"
```

This guarantees that the installer always downloads the absolute latest version of the binary with **zero manual changes** to the script.

---

## 3. Recommended Hosting Strategies

Since the installer script is fully dynamic, we do not need complex CI file uploads or server SSH credentials in our pipeline. We can employ one of two hosting strategies:

### Option A: HTTP Redirection (Highly Recommended & 100% Automated)
Instead of copying the physical `install.sh` file onto your web hosting server:
1. Maintain `install.sh` in the master Git repository under `scripts/install.sh`.
2. Configure a standard **HTTP 302/307 Redirect** on your website `ubunatic.com` (via Cloudflare Page Rules, Nginx, Apache, or Caddy):
   * **Source URL**: `https://ubunatic.com/emojig/install.sh`
   * **Target URL**: `https://codeberg.org/ubunatic/emojig/raw/branch/main/scripts/install.sh`

#### Advantages
* **Git-Driven**: Any changes or fixes you make to `install.sh` inside your repo are immediately active on your website upon pushing to Codeberg.
* **No Secrets in CI**: Eliminates the security risk of storing server SSH passwords or FTP keys inside your Woodpecker CI pipeline.

---

### Option B: Local Static Hosting (Set-and-Forget)
If you prefer your web server to serve the static file natively without external redirections:
1. Upload the `scripts/install.sh` file to your server once via `scp` or `rsync`:
   ```sh
   scp scripts/install.sh user@ubunatic.com:/var/www/ubunatic/emojig/install.sh
   ```
2. **Because the script dynamically queries the latest Codeberg release at runtime, you never have to touch or re-upload this file again.** It remains permanently static on your server.
