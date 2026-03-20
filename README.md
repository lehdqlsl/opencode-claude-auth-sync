# opencode-claude-auth-sync

Sync your existing [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) credentials to [OpenCode](https://opencode.ai) — no separate Anthropic login needed.

> **Note:** OpenCode has officially dropped native Anthropic authentication support. This tool is the recommended way to use Claude models with OpenCode if you have a Claude CLI subscription.

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
~/.local/bin/sync-claude-to-opencode.sh          # Linux / macOS
& "$HOME\.local\bin\sync-claude-to-opencode.ps1"  # Windows
```

### Verify

```bash
opencode providers list    # Should show: Anthropic  oauth
opencode models anthropic  # Should list Claude models (e.g. claude-opus-4-6)
```

## Platform Support

| Platform | Claude credentials | Scheduler | Install command |
|---|---|---|---|
| **Linux / WSL** | `~/.claude/.credentials.json` | cron | `curl \| bash` |
| **macOS** | macOS Keychain → file fallback | LaunchAgent | `curl \| bash` |
| **Windows** (native) | `%USERPROFILE%\.claude\.credentials.json` | Task Scheduler | PowerShell |

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
3. It compares the `accessToken` and `refreshToken` with what's currently in OpenCode's `auth.json`
4. If they differ (or the Anthropic entry doesn't exist), it writes the new credentials
5. If they're identical, it logs the remaining token lifetime and exits (no unnecessary writes)
6. Once the credentials are in `auth.json`, OpenCode's built-in `opencode-anthropic-auth` plugin handles everything else: token refresh, request signing, OAuth beta headers, and user-agent

Claude CLI tokens are valid for approximately **5–6 hours**. The sync job runs every hour (LaunchAgent on macOS, cron on Linux, Task Scheduler on Windows), so if you re-authenticate with Claude CLI, OpenCode picks up the new tokens automatically. On macOS, LaunchAgent catches up on missed runs after sleep/wake — no missed syncs even with the lid closed.

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

2. Check the sync output. If it says "EXPIRED", the Claude CLI token is stale.
   Fix: run `claude` in the terminal to re-authenticate, then re-run the sync:
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

(Optional) Set up automatic hourly syncing:

```bash
# macOS — LaunchAgent (recommended, catches up after sleep)
# Use the install script: curl ... | bash

# Linux — cron
(crontab -l 2>/dev/null; echo "0 * * * * \$HOME/.local/bin/sync-claude-to-opencode.sh >> \$HOME/.local/share/opencode/sync-claude.log 2>&1") | crontab -
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

### Do NOT use `opencode-claude-auth` npm package

The `opencode-claude-auth` npm package is **incompatible** with this tool and with OpenCode v1.2.27+. That package:

- Exports `auth.methods: []` (empty array), which crashes OpenCode's login UI with `TypeError: undefined is not an object (evaluating 'method.type')`
- Calls `clearOpencodeAuth()` on startup, which **deletes** the Anthropic entry from `auth.json` — making the provider disappear entirely

The installer warns if detected. Remove it manually from the `plugin` array in your `opencode.json`.

### Token expiration / "EXPIRED" status

Claude CLI tokens are valid for approximately **5–6 hours**. If you see `EXPIRED` in the sync output or `Token refresh failed: 429` when using Claude models:

1. Re-authenticate with Claude CLI:
   ```bash
   claude
   ```
2. Re-run the sync immediately:
   ```bash
   # Linux / macOS
   ~/.local/bin/sync-claude-to-opencode.sh

   # Windows
   & "$HOME\.local\bin\sync-claude-to-opencode.ps1"
   ```
3. Verify the output shows remaining time (e.g. `5h 30m remaining`), not `EXPIRED`

The scheduled sync job (LaunchAgent / cron / Task Scheduler) will also pick up new credentials automatically within an hour.

### Token refresh failed: 429

This means OpenCode tried to use an expired token. It's not a rate limit — it's Anthropic rejecting a stale refresh token. Fix by re-authenticating with `claude` and syncing again (see above).

### Sync log

Check the sync history:

```bash
cat ~/.local/share/opencode/sync-claude.log
```

## License

MIT
