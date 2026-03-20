# opencode-claude-auth-sync

Sync your existing [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) credentials to [OpenCode](https://opencode.ai) — no separate Anthropic login needed.

> **Note:** OpenCode has officially dropped native Anthropic authentication support. This tool is the recommended way to use Claude models with OpenCode if you have a Claude CLI subscription.

## Why?

OpenCode no longer provides built-in Anthropic login. If you want to use Claude models (Opus, Sonnet, Haiku, etc.) in OpenCode, you need to bring your own credentials.

This tool bridges the gap: it reads your existing Claude CLI OAuth tokens (`~/.claude/.credentials.json`) and writes them into OpenCode's auth store (`~/.local/share/opencode/auth.json`), letting OpenCode's bundled `opencode-anthropic-auth` plugin handle the rest.

## How It Works

```
┌─────────────────────────┐      sync script      ┌─────────────────────────────┐
│  ~/.claude/              │      (cron 30m)       │  ~/.local/share/opencode/   │
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

**Step by step:**

1. Claude CLI stores OAuth credentials at `~/.claude/.credentials.json` after you run `claude` and authenticate
2. This sync script reads the `claudeAiOauth` object from that file
3. It compares the `accessToken` and `refreshToken` with what's currently in OpenCode's `auth.json`
4. If they differ (or the Anthropic entry doesn't exist), it writes the new credentials
5. If they're identical, it exits silently (no unnecessary writes)
6. Once the credentials are in `auth.json`, OpenCode's built-in `opencode-anthropic-auth@0.0.13` plugin handles everything else: token refresh, request signing, OAuth beta headers, and user-agent

The cron job runs every 30 minutes, so if you re-authenticate with Claude CLI, OpenCode picks up the new tokens automatically.

## Prerequisites

- [OpenCode](https://opencode.ai) v1.2.27+
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) — authenticated (run `claude` at least once)
- Node.js (bundled with OpenCode, or standalone)

## Install

### Automatic (with AI agent)

Paste this to your AI coding agent (Claude Code, OpenCode, Cursor, etc.):

```
Install opencode-claude-auth-sync from https://github.com/lehdqlsl/opencode-claude-auth-sync

Run the install script:
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash

Then verify with:
opencode providers list
opencode models anthropic
```

### Automatic (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash
```

The installer will:
1. Install the sync script to `~/.local/bin/sync-claude-to-opencode.sh`
2. Run an initial credential sync
3. Remove `opencode-claude-auth` from your OpenCode config if present (see [Known Issues](#known-issues))
4. Set up a cron job to sync every 30 minutes

### Manual

**Step 1.** Download the sync script:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/sync-claude-to-opencode.sh \
  -o ~/.local/bin/sync-claude-to-opencode.sh
chmod +x ~/.local/bin/sync-claude-to-opencode.sh
```

**Step 2.** Run the initial sync:

```bash
~/.local/bin/sync-claude-to-opencode.sh
```

**Step 3.** (Optional) Remove `opencode-claude-auth` from `~/.config/opencode/opencode.json` if present:

```bash
# Check if it's there
grep "opencode-claude-auth" ~/.config/opencode/opencode.json

# If found, remove it manually from the "plugin" array
```

**Step 4.** (Optional) Set up cron for automatic syncing:

```bash
(crontab -l 2>/dev/null; echo "*/30 * * * * \$HOME/.local/bin/sync-claude-to-opencode.sh >> \$HOME/.local/share/opencode/sync-claude.log 2>&1") | crontab -
```

## Verify

```bash
opencode providers list    # Should show: Anthropic  oauth
opencode models anthropic  # Should list Claude models (e.g. claude-opus-4-6)
```

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `CLAUDE_CREDENTIALS_PATH` | `~/.claude/.credentials.json` | Path to Claude CLI credentials |
| `OPENCODE_AUTH_PATH` | `~/.local/share/opencode/auth.json` | Path to OpenCode auth store |

Example with custom paths:

```bash
CLAUDE_CREDENTIALS_PATH=/custom/path/.credentials.json \
OPENCODE_AUTH_PATH=/custom/path/auth.json \
~/.local/bin/sync-claude-to-opencode.sh
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/uninstall.sh | bash
```

Or manually:

```bash
crontab -l | grep -v sync-claude-to-opencode | crontab -
rm ~/.local/bin/sync-claude-to-opencode.sh
```

## Known Issues

### Do NOT use `opencode-claude-auth` npm package

The `opencode-claude-auth` npm package is **incompatible** with this tool and with OpenCode v1.2.27+. That package:

- Exports `auth.methods: []` (empty array), which crashes OpenCode's login UI with `TypeError: undefined is not an object (evaluating 'method.type')`
- Calls `clearOpencodeAuth()` on startup, which **deletes** the Anthropic entry from `auth.json` — making the provider disappear entirely

The installer automatically removes it from your OpenCode plugin config if detected.

### Token expiration

When your Claude CLI token expires, re-authenticate by running `claude` in your terminal. The cron job will pick up the new credentials within 30 minutes. For immediate sync, run:

```bash
~/.local/bin/sync-claude-to-opencode.sh
```

## License

MIT
