# opencode-claude-auth-sync

Sync your existing Claude CLI credentials to [OpenCode](https://opencode.ai) — no separate Anthropic login needed.

## Problem

OpenCode requires its own Anthropic authentication, even if you're already logged into Claude CLI. This tool bridges that gap by syncing your Claude CLI credentials (`~/.claude/.credentials.json`) to OpenCode's auth store (`~/.local/share/opencode/auth.json`).

It also removes `opencode-claude-auth` if present — that package is known to break OpenCode's auth UI and delete Anthropic credentials on startup.

## Prerequisites

- [OpenCode](https://opencode.ai) v1.2.27+
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) authenticated (`claude` command)
- Node.js (bundled with OpenCode, or standalone)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash
```

This will:
1. Install the sync script to `~/.local/bin/sync-claude-to-opencode.sh`
2. Run an initial credential sync
3. Remove `opencode-claude-auth` from your OpenCode config if present
4. Set up a cron job to sync every 30 minutes

## Verify

```bash
opencode providers list    # Should show: Anthropic oauth
opencode models anthropic  # Should list Claude models
```

## Manual Usage

```bash
~/.local/bin/sync-claude-to-opencode.sh
```

The script only writes when credentials have actually changed.

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `CLAUDE_CREDENTIALS_PATH` | `~/.claude/.credentials.json` | Path to Claude CLI credentials |
| `OPENCODE_AUTH_PATH` | `~/.local/share/opencode/auth.json` | Path to OpenCode auth store |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/uninstall.sh | bash
```

Or manually:

```bash
crontab -l | grep -v sync-claude-to-opencode | crontab -
rm ~/.local/bin/sync-claude-to-opencode.sh
```

## How It Works

```
~/.claude/.credentials.json  →  sync script  →  ~/.local/share/opencode/auth.json
       (Claude CLI)              (cron 30m)              (OpenCode)
```

1. Reads `claudeAiOauth` from Claude CLI's credential file
2. Compares with the current Anthropic entry in OpenCode's auth store
3. Updates only if the token has changed
4. OpenCode's built-in `opencode-anthropic-auth` plugin handles the rest (token refresh, request signing)

## Known Issues

### `opencode-claude-auth` package

Do **not** use the `opencode-claude-auth` npm package alongside this tool. That package:
- Sets `auth.methods: []` which crashes OpenCode's login UI (`TypeError: undefined is not an object (evaluating 'method.type')`)
- Calls `clearOpencodeAuth()` on startup, which deletes the Anthropic entry from `auth.json`

The installer automatically removes it from your OpenCode config.

## License

MIT
