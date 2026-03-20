#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"
REPO_RAW="https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main"

CLAUDE_CREDS="${HOME}/.claude/.credentials.json"
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"

echo "==> Checking prerequisites..."

command -v node >/dev/null 2>&1 || { echo "ERROR: node is required but not found"; exit 1; }
command -v opencode >/dev/null 2>&1 || { echo "ERROR: opencode is required but not found"; exit 1; }

if [[ ! -f "$CLAUDE_CREDS" ]]; then
  echo "ERROR: Claude credentials not found at $CLAUDE_CREDS"
  echo "Run 'claude' first to authenticate."
  exit 1
fi

if [[ ! -f "$OPENCODE_AUTH" ]]; then
  echo "ERROR: OpenCode auth file not found at $OPENCODE_AUTH"
  echo "Run 'opencode' at least once first."
  exit 1
fi

echo "==> Installing sync script to ${INSTALL_DIR}/${SCRIPT_NAME}..."
mkdir -p "$INSTALL_DIR"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${REPO_RAW}/${SCRIPT_NAME}" -o "${INSTALL_DIR}/${SCRIPT_NAME}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${INSTALL_DIR}/${SCRIPT_NAME}" "${REPO_RAW}/${SCRIPT_NAME}"
else
  echo "ERROR: curl or wget is required"; exit 1
fi

chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

echo "==> Running initial sync..."
"${INSTALL_DIR}/${SCRIPT_NAME}" && echo "    Initial sync complete." || echo "    Initial sync skipped (already up to date)."

echo "==> Removing opencode-claude-auth from opencode.json if present..."
OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.json"
if [[ -f "$OPENCODE_CONFIG" ]] && grep -q "opencode-claude-auth" "$OPENCODE_CONFIG"; then
  node -e "
    const fs = require('fs');
    const config = JSON.parse(fs.readFileSync('${OPENCODE_CONFIG}', 'utf8'));
    if (Array.isArray(config.plugin)) {
      config.plugin = config.plugin.filter(p => !p.includes('opencode-claude-auth'));
      fs.writeFileSync('${OPENCODE_CONFIG}', JSON.stringify(config, null, 2));
      console.log('    Removed opencode-claude-auth from plugin list.');
    }
  "
fi

echo "==> Setting up cron (every 30 minutes)..."
CRON_CMD="*/30 * * * * ${INSTALL_DIR}/${SCRIPT_NAME} >> ${HOME}/.local/share/opencode/sync-claude.log 2>&1"

if crontab -l 2>/dev/null | grep -qF "$SCRIPT_NAME"; then
  echo "    Cron already registered. Skipping."
else
  (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
  echo "    Cron registered."
fi

echo ""
echo "Done! Verify with:"
echo "  opencode providers list    # Should show: Anthropic oauth"
echo "  opencode models anthropic  # Should list Claude models"
