# opencode-claude-auth-sync

Sync your existing [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) credentials to [OpenCode](https://opencode.ai) — cross-platform, zero dependencies.

### Key Features

- **Quota visibility** — See your 5h / 7d usage at a glance with `claude-sync --status`
- **Zero dependencies** — Plain shell scripts. No npm, no node_modules, no supply chain risk. Read the source before you run it.
- **Auto-refresh** — Expired tokens are refreshed via Claude CLI automatically

---

> ⚠️ **OpenCode 1.3.0+ users:** This tool only syncs credentials. You must also install a separate Anthropic auth plugin. See [v1.3+ compatibility](#opencode-v13-compatibility).

---

<details>
<summary>🔧 <strong>Getting 429 errors?</strong></summary>

The old built-in `opencode-anthropic-auth@0.0.13` plugin may still be cached. Remove it:

```bash
rm -rf ~/.cache/opencode/node_modules/opencode-anthropic-auth
```

If it keeps coming back, also remove `opencode-anthropic-auth` from `~/.cache/opencode/package.json`. Then restart OpenCode.

</details>

<details>
<summary>🤔 <strong>Why not an npm plugin?</strong></summary>

When auth breaks, npm packages pop up fast — but installing unknown packages that handle your OAuth tokens is a risk. This tool is a plain shell script you can read in full before running. No `node_modules`, no dependency tree, no trust required.

npm-based alternatives like [`opencode-claude-auth`](https://github.com/griffinmartin/opencode-claude-auth) work well too. This tool is for those who prefer auditable shell scripts over npm packages.

</details>

## Quick Start

### Linux / macOS / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash
```

### Windows (PowerShell as Administrator)

```powershell
irm https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.ps1 | iex
```

Recent Windows installs register the background sync task through a hidden script runner, so the scheduler should stay silent. If an older install still pops a console window every 15 minutes, reinstall once to refresh the scheduled task.

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
claude-sync

# Check token status and usage
claude-sync --status
```

## Platform Support

| Platform | Claude credentials | Scheduler | Install command |
|---|---|---|---|
| **Linux / WSL** | `~/.claude/.credentials.json` | systemd user timer *(cron fallback)* | `curl \| bash` |
| **macOS** | macOS Keychain → file fallback | LaunchAgent | `curl \| bash` |
| **Windows** (native) | `%USERPROFILE%\.claude\.credentials.json` | Task Scheduler | PowerShell |

On Linux, the installer prefers a **systemd user timer** with `Persistent=true`, so it catches up missed runs after suspend/resume and reboot — the same feature parity the macOS LaunchAgent already provides. Systems without user systemd fall back to cron (`*/15` + `@reboot`). Plain cron does not run during suspend, so laptops should prefer the systemd path.

## Security

This tool is **not an npm package** — it's a plain shell script you can read before running.

- No `node_modules`, no dependency tree, no supply chain risk
- Single-file scripts: [`sync-claude-to-opencode.sh`](sync-claude-to-opencode.sh) (bash) / [`.ps1`](sync-claude-to-opencode.ps1) (PowerShell)
- Credentials are passed via stdin, never exposed in process arguments
- All JSON writes are atomic (temp file + rename) to prevent corruption
- Review the source before installing: [`sync-claude-to-opencode.sh`](sync-claude-to-opencode.sh) (bash) / [`.ps1`](sync-claude-to-opencode.ps1) (PowerShell)

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

This tool bridges the gap: it reads your existing Claude CLI OAuth tokens and writes them into OpenCode's auth store, letting an `opencode-anthropic-auth` plugin handle the rest (see [v1.3+ compatibility](#opencode-v13-compatibility)).

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
   claude-sync
   # Windows
   claude-sync

3. Verify — the output should show remaining time, not EXPIRED:
   opencode providers list    # Should show: Anthropic oauth
   opencode models anthropic  # Should list Claude models

4. If you see "Token refresh failed: 429", that means expired tokens were used.
   Re-authenticate with `claude` first, then sync again.

5. If already installed and just need to refresh tokens (no reinstall needed):
   Run `claude` to re-authenticate, then sync:
   # Linux / macOS
   claude-sync
   # Windows
   claude-sync

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
ln -sf ~/.local/bin/sync-claude-to-opencode.sh ~/.local/bin/claude-sync

claude-sync
```

(Optional) Set up automatic syncing (every 15 minutes):

```bash
# macOS — LaunchAgent (recommended, catches up after sleep)
# Use the install script: curl ... | bash

# Linux — systemd user timer (recommended, catches up after sleep/reboot)
# Use the install script: curl ... | bash

# Linux — cron fallback (does not run during suspend)
(crontab -l 2>/dev/null; echo "*/15 * * * * \$HOME/.local/bin/sync-claude-to-opencode.sh >> \$HOME/.local/share/opencode/sync-claude.log 2>&1") | crontab -
```

### Windows (manual)

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.local\bin" | Out-Null
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/sync-claude-to-opencode.ps1" `
  -OutFile "$HOME\.local\bin\sync-claude-to-opencode.ps1"

@"
@echo off
setlocal
powershell.exe -ExecutionPolicy Bypass -File "%~dp0sync-claude-to-opencode.ps1" %*
"@ | Set-Content -Path "$HOME\.local\bin\claude-sync.cmd"

claude-sync
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
   claude-sync

   # Windows
   claude-sync
   ```

### Token refresh failed: 429

This means OpenCode tried to use an expired token. The sync script's auto-refresh should prevent this, but if it occurs, re-authenticate with `claude` and sync again.

If the deprecated built-in plugin keeps being reinstalled, remove both:

```bash
rm -rf ~/.cache/opencode/node_modules/opencode-anthropic-auth
```

and the `opencode-anthropic-auth` dependency entry from `~/.cache/opencode/package.json`, then restart OpenCode.

If you're on OpenCode `v1.2.27` and the deprecated plugin keeps coming back on every startup, that's an upstream built-in plugin issue. A practical CLI-side workaround is:

1. Start OpenCode with `OPENCODE_DISABLE_DEFAULT_PLUGINS=true`
2. Explicitly register `opencode-claude-auth@latest` in `opencode.json`

Example:

```json
{
  "plugin": [
    "opencode-claude-auth@latest"
  ]
}
```

This disables the old built-in plugin injection while still loading a Claude auth provider explicitly.

### Sync log

Check the sync history:

```bash
cat ~/.local/share/opencode/sync-claude.log
```

### OpenCode v1.3+ compatibility

OpenCode v1.3 removes the built-in `opencode-anthropic-auth` plugin ([PR #18186](https://github.com/anomalyco/opencode/pull/18186)) per Anthropic's legal request.

This tool only syncs credentials into `auth.json`. On OpenCode `1.3.0+`, synced credentials alone are no longer enough because the Anthropic provider is no longer built in.

If you're on OpenCode `1.3.0+`, you need to register a separate Anthropic auth plugin manually in your `opencode.json`. Pick one:

The original plugin is still available on npm (deprecated):

```json
{
  "plugin": ["opencode-anthropic-auth@0.0.13"]
}
```

**If the npm packages get unpublished**, this repo includes a bundled copy of the original plugin (`opencode-anthropic-auth-0.0.13.tgz`). Extract it and reference the local file:

```json
{
  "plugin": ["/path/to/index.mjs"]
}
```

**Important:** This tool only handles credential sync (copying OAuth tokens into `auth.json`). It does not handle Anthropic API request transformation (headers, User-Agent, beta flags, etc.). If Anthropic changes how requests must be sent, this tool alone will not be enough — you will need an auth plugin that also handles request-level changes.

This tool itself only copies credentials and has no legal concerns. The compatibility risk is with the auth plugin that actually uses them.

## License

MIT
