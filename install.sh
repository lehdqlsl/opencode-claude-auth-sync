#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"
REPO_RAW="https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main"
CRON_MARKER="# opencode-claude-auth-sync"

CLAUDE_CREDS="${HOME}/.claude/.credentials.json"
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"

echo "==> Checking prerequisites..."

command -v node >/dev/null 2>&1 || { echo "ERROR: node is required but not found"; exit 1; }
command -v opencode >/dev/null 2>&1 || { echo "ERROR: opencode is required but not found"; exit 1; }

CLAUDE_FOUND=false

if [[ -f "$CLAUDE_CREDS" ]]; then
  CLAUDE_FOUND=true
elif [[ "$(uname)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
  if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
    CLAUDE_FOUND=true
  fi
fi

if [[ "$CLAUDE_FOUND" == "false" ]]; then
  echo "ERROR: Claude credentials not found."
  echo ""
  echo "  macOS:         Not in Keychain (service: 'Claude Code-credentials')"
  echo "  Linux/Windows: Not at $CLAUDE_CREDS"
  echo ""
  echo "Run 'claude' first to authenticate, then re-run this installer."
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
if "${INSTALL_DIR}/${SCRIPT_NAME}"; then
  echo "    Initial sync complete."
else
  rc=$?
  echo "    WARNING: Initial sync failed (exit code $rc)." >&2
  # Non-fatal: continue with install so cron can retry later
fi

echo "==> Checking opencode-claude-auth in opencode.json..."
OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.json"
if [[ -f "$OPENCODE_CONFIG" ]] && grep -q "opencode-claude-auth" "$OPENCODE_CONFIG"; then
  echo "    WARNING: 'opencode-claude-auth' found in $OPENCODE_CONFIG"
  echo "    This package is incompatible. Please remove it manually from the 'plugin' array."
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "==> Setting up LaunchAgent (every hour)..."
  PLIST_DIR="${HOME}/Library/LaunchAgents"
  PLIST_NAME="com.opencode.claude-sync"
  PLIST_PATH="${PLIST_DIR}/${PLIST_NAME}.plist"
  LOG_PATH="${HOME}/.local/share/opencode/sync-claude.log"

  mkdir -p "$PLIST_DIR"

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/${SCRIPT_NAME}</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  echo "    LaunchAgent registered: $PLIST_NAME"
  echo "    Runs every hour + on login + catches up after sleep."

else
  echo "==> Setting up cron (every hour)..."
  CRON_CMD="0 * * * * ${INSTALL_DIR}/${SCRIPT_NAME} >> ${HOME}/.local/share/opencode/sync-claude.log 2>&1 ${CRON_MARKER}"

  if command -v crontab >/dev/null 2>&1; then
    if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
      echo "    Cron already registered. Skipping."
    else
      (crontab -l 2>/dev/null || true; echo "$CRON_CMD") | crontab -
      echo "    Cron registered."
    fi
  else
    echo "    WARNING: crontab not found. Set up a periodic job manually:"
    echo "      ${INSTALL_DIR}/${SCRIPT_NAME}"
  fi
fi

echo ""
echo "Done! Verify with:"
echo "  opencode providers list    # Should show: Anthropic oauth"
echo "  opencode models anthropic  # Should list Claude models"
