# opencode-claude-auth-sync

Sync your existing [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) credentials to [OpenCode](https://opencode.ai) — no separate Anthropic login needed.

> **Heads up (March 2026):** Anthropic is tightening server-side enforcement — billing header injection, endpoint migration (`platform.claude.com`), and User-Agent checks are being rolled out. Token sync alone may stop working in a future OpenCode release. We're tracking this and plan to ship a self-contained `plugin.mjs` (no npm) in v0.5.0. For now, everything works on OpenCode v1.2.27 and below.

> **Why not an npm plugin?** When auth breaks, npm packages pop up fast — but installing unknown packages that handle your OAuth tokens is a risk. This tool is a plain shell script you can read in full before running. No `node_modules`, no dependency tree, no trust required.

## Quick Start

### Linux / macOS / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash
```

### Windows (PowerShell as Administrator)

```powershell
irm https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.ps1 | iex
```

**Don't want a scheduler?** Install without automatic syncing:

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash -s -- --no-scheduler

# Windows (PowerShell)
& { irm https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.ps1 -OutFile $env:TEMP\install.ps1; & $env:TEMP\install.ps1 --no-scheduler }
```

Then just run the sync manually whenever you need it:
```bash
claude-sync                                     # Linux / macOS (after install)
~/.local/bin/sync-claude-to-opencode.sh         # Linux / macOS direct path
claude-sync                                     # Windows (after install)
& "$HOME\.local\bin\sync-claude-to-opencode.ps1"  # Windows direct path
```

### Verify

```bash
opencode providers list    # Should show: Anthropic  oauth
opencode models anthropic  # Should list Claude models (e.g. claude-opus-4-6)
```

### Usage

```bash
# Normal sync (default, also runs via scheduler)
~/.local/bin/sync-claude-to-opencode.sh

# Check token status without syncing
~/.local/bin/sync-claude-to-opencode.sh --status

# Force refresh token via Claude CLI regardless of expiry
~/.local/bin/sync-claude-to-opencode.sh --force
```

## Multi-Account

v0.4.0 adds local multi-account storage for people rotating between 2-3 Claude Max accounts.

Important: Claude CLI itself only supports one logged-in account at a time. Multi-account here means this tool stores multiple credential sets in its own account store, then switches which one is written into OpenCode's `auth.json`.

Account store:

```text
~/.config/opencode-claude-auth-sync/accounts.json
```

### Add accounts

Use `--login` — it handles logout, login, and save in one command:

```bash
~/.local/bin/sync-claude-to-opencode.sh --login personal
~/.local/bin/sync-claude-to-opencode.sh --login work
~/.local/bin/sync-claude-to-opencode.sh --login backup
```

Windows:

```powershell
& "$HOME\.local\bin\sync-claude-to-opencode.ps1" --login personal
& "$HOME\.local\bin\sync-claude-to-opencode.ps1" --login work
```

Each `--login` logs out the current Claude session, opens the login flow, then saves the credentials under the given label.

If you've already logged in via `claude` and just want to capture the current session without re-logging in:

```bash
~/.local/bin/sync-claude-to-opencode.sh --add personal
```

### Manage accounts

```bash
# List stored accounts
~/.local/bin/sync-claude-to-opencode.sh --list

# Show active account status
~/.local/bin/sync-claude-to-opencode.sh --status

# Switch active account immediately
~/.local/bin/sync-claude-to-opencode.sh --switch work

# Rotate to the next account (round-robin)
~/.local/bin/sync-claude-to-opencode.sh --rotate

# Remove a stored account
~/.local/bin/sync-claude-to-opencode.sh --remove backup
```

### Rotation behavior

- OpenCode still uses a single Anthropic entry in `auth.json`
- This tool switches which stored account is written into that slot
- If the active account is expired, the script first tries another non-expired stored account
- If all stored accounts are expired, it falls back to Claude CLI refresh for the currently logged-in Claude account
- 429 rate limits are not auto-detected in v0.4.0; if one account is rate-limited, run `--rotate` manually

### Store format

```json
{
  "accounts": {
    "personal": {
      "accessToken": "...",
      "refreshToken": "...",
      "expiresAt": 1774027458398,
      "subscriptionType": "max",
      "rateLimitTier": "default_claude_max_20x",
      "addedAt": "2026-03-20T09:55:32.366Z"
    }
  },
  "active": "personal",
  "rotationIndex": 0
}
```

## Platform Support

| Platform | Claude credentials | Scheduler | Install command |
|---|---|---|---|
| **Linux / WSL** | `~/.claude/.credentials.json` | cron | `curl \| bash` |
| **macOS** | macOS Keychain → file fallback | LaunchAgent | `curl \| bash` |
| **Windows** (native) | `%USERPROFILE%\.claude\.credentials.json` | Task Scheduler | PowerShell |

## Security

This tool is **not an npm package** — it's a plain shell script you can read before running.

- No `node_modules`, no dependency tree, no supply chain risk
- Single-file scripts: [`sync-claude-to-opencode.sh`](sync-claude-to-opencode.sh) (bash) / [`.ps1`](sync-claude-to-opencode.ps1) (PowerShell)
- Credentials are passed via stdin, never exposed in process arguments
- All JSON writes are atomic (temp file + rename) to prevent corruption
- Review the source before installing: it's ~100 lines per script

```bash
# Inspect before running
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/sync-claude-to-opencode.sh | less
```

## Prerequisites

- [OpenCode](https://opencode.ai) v1.2.27+
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) — authenticated (run `claude` at least once)
- Node.js (bundled with OpenCode, or standalone)

## Why?

OpenCode no longer provides built-in Anthropic login. If you want to use Claude models (Opus, Sonnet, Haiku, etc.) in OpenCode, you need to bring your own credentials.

This tool bridges the gap: it reads your existing Claude CLI OAuth tokens and writes them into OpenCode's auth store, letting OpenCode's bundled `opencode-anthropic-auth` plugin handle the rest.

## How It Works

```
┌─────────────────────────┐      sync script      ┌─────────────────────────────┐
│  ~/.claude/              │  (launchd/cron/task)   │  ~/.local/share/opencode/   │
│  .credentials.json       │ ──────────────────▶   │  auth.json                  │
│                          │                       │                             │
│  claudeAiOauth {         │   reads & compares    │  anthropic {                │
│    accessToken,          │   ─────────────────▶  │    type: "oauth",           │
│    refreshToken,         │   writes if changed   │    access: <accessToken>,   │
│    expiresAt             │                       │    refresh: <refreshToken>, │
│  }                       │                       │    expires: <expiresAt>     │
│                          │                       │  }                         │
└─────────────────────────┘                       └─────────────────────────────┘
                                                             │
                                                             ▼
                                                   OpenCode built-in plugin
                                                   (opencode-anthropic-auth)
                                                   handles token refresh,
                                                   request signing, OAuth beta
                                                   headers, and API routing.
```

**Credential sources (platform-aware):**

| Platform | Claude CLI stores credentials in | How this script reads them |
|---|---|---|
| **macOS** | macOS Keychain (service: `Claude Code-credentials`) | `security find-generic-password` |
| **Linux / WSL / Windows** | `~/.claude/.credentials.json` | Direct file read |

**Step by step:**

1. Claude CLI stores OAuth credentials after you run `claude` and authenticate (Keychain on macOS, file on Linux/Windows)
2. This sync script detects the platform and reads the `claudeAiOauth` object from the appropriate source
3. **If the token is already expired**, it automatically runs `claude` CLI to refresh the token before syncing
4. It compares the `accessToken`, `refreshToken`, and `expiresAt` with what's currently in OpenCode's `auth.json`
5. If they differ (or the Anthropic entry doesn't exist), it writes the new credentials
6. If they're identical, it logs the remaining token lifetime and exits (no unnecessary writes)
7. Once the credentials are in `auth.json`, OpenCode's built-in `opencode-anthropic-auth` plugin handles everything else: token refresh, request signing, OAuth beta headers, and user-agent

Claude CLI tokens are valid for approximately **5–6 hours**. The sync job runs every **15 minutes** (LaunchAgent on macOS, cron on Linux, Task Scheduler on Windows). Once a token has expired, the script uses Claude CLI to refresh it and then re-syncs `auth.json`. On macOS, LaunchAgent catches up on missed runs after sleep/wake.

## Install (detailed)

### Automatic (with AI agent)

Paste this to your AI coding agent (Claude Code, OpenCode, Cursor, etc.):

```
Install opencode-claude-auth-sync from https://github.com/lehdqlsl/opencode-claude-auth-sync

1. Run the install script:
   # Linux / macOS
   curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash

   # Windows (PowerShell as Admin)
   irm https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.ps1 | iex

2. Check the sync output. If it says "EXPIRED", the stored token is stale.
   The script will try to refresh it automatically via Claude CLI. If that still fails, run `claude` manually, then re-run the sync:
   # Linux / macOS
   ~/.local/bin/sync-claude-to-opencode.sh
   # Windows
   & "$HOME\.local\bin\sync-claude-to-opencode.ps1"

3. Verify — the output should show remaining time, not EXPIRED:
   opencode providers list    # Should show: Anthropic oauth
   opencode models anthropic  # Should list Claude models

4. If you see "Token refresh failed: 429", that means expired tokens were used.
   Re-authenticate with `claude` first, then sync again.

5. If already installed and just need to refresh tokens (no reinstall needed):
   Run `claude` to re-authenticate, then sync:
   # Linux / macOS
   ~/.local/bin/sync-claude-to-opencode.sh
   # Windows
   & "$HOME\.local\bin\sync-claude-to-opencode.ps1"

6. If the user doesn't want a background scheduler, install with --no-scheduler:
   # Linux / macOS
   curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash -s -- --no-scheduler
   # Windows
   Download and run install.ps1 with --no-scheduler flag
   Then sync manually whenever needed.
```

### Linux / macOS (manual)

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/sync-claude-to-opencode.sh \
  -o ~/.local/bin/sync-claude-to-opencode.sh
chmod +x ~/.local/bin/sync-claude-to-opencode.sh

~/.local/bin/sync-claude-to-opencode.sh
```

(Optional) Set up automatic syncing (every 15 minutes):

```bash
# macOS — LaunchAgent (recommended, catches up after sleep)
# Use the install script: curl ... | bash

# Linux — cron
(crontab -l 2>/dev/null; echo "*/15 * * * * \$HOME/.local/bin/sync-claude-to-opencode.sh >> \$HOME/.local/share/opencode/sync-claude.log 2>&1") | crontab -
```

### Windows (manual)

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.local\bin" | Out-Null
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/sync-claude-to-opencode.ps1" `
  -OutFile "$HOME\.local\bin\sync-claude-to-opencode.ps1"

& "$HOME\.local\bin\sync-claude-to-opencode.ps1"
```

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `CLAUDE_CREDENTIALS_PATH` | `~/.claude/.credentials.json` (Linux/Win) or Keychain (macOS) | Path to Claude CLI credentials |
| `OPENCODE_AUTH_PATH` | `~/.local/share/opencode/auth.json` | Path to OpenCode auth store |

## Uninstall

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/uninstall.sh | bash
```

### Windows (PowerShell as Administrator)

```powershell
irm https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/uninstall.ps1 | iex
```

## Known Issues

### Using alongside `opencode-claude-auth` npm plugin

If you're using [`opencode-claude-auth`](https://github.com/griffinmartin/opencode-claude-auth) (v0.5+), you don't need this tool — that plugin syncs credentials in-process. Choose one or the other, not both.

Early versions (v0.2.x) had issues that have since been fixed. If you're on an old version, update or remove it.

### Token expiration / "EXPIRED" status

The sync script attempts an automatic refresh via Claude CLI once the token is expired. If Claude CLI can refresh successfully, the next sync writes fresh credentials back to OpenCode.

> **Note:** If the token expired while OpenCode was running, you may need to restart OpenCode after the sync to pick up the new credentials. This is rare — normally Claude CLI refreshes tokens before they expire, so OpenCode reads them seamlessly.

If auto-refresh fails (e.g. `claude` CLI not in PATH, or network issues):

1. Re-authenticate manually:
   ```bash
   claude
   ```
2. Re-run the sync:
   ```bash
   # Linux / macOS
   ~/.local/bin/sync-claude-to-opencode.sh

   # Windows
   & "$HOME\.local\bin\sync-claude-to-opencode.ps1"
   ```

### Token refresh failed: 429

This means OpenCode tried to use an expired token. The sync script's auto-refresh should prevent this, but if it occurs, re-authenticate with `claude` and sync again.

### Sync log

Check the sync history:

```bash
cat ~/.local/share/opencode/sync-claude.log
```

### OpenCode v1.3+ compatibility

OpenCode v1.3 removes the built-in `opencode-anthropic-auth` plugin ([PR #18186](https://github.com/anomalyco/opencode/pull/18186)) per Anthropic's legal request. This tool depends on that plugin to handle token refresh and request signing.

**While the npm package is still available**, you can manually register it in your `opencode.json`:

```json
{
  "plugin": ["opencode-anthropic-auth@0.0.13"]
}
```

**If the npm package gets unpublished**, back up the package locally before it disappears:

```bash
npm pack opencode-anthropic-auth@0.0.13
```

This downloads `opencode-anthropic-auth-0.0.13.tgz` to your current directory. Extract it and reference the local file in your `opencode.json`:

```json
{
  "plugin": ["/path/to/index.mjs"]
}
```

This tool (`opencode-claude-auth-sync`) itself only copies credentials and has no legal concerns. The compatibility risk is with the auth plugin that actually uses them.

## License

MIT
