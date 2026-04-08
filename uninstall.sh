#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"
CRON_MARKER="# opencode-claude-auth-sync"
PLIST_NAME="com.opencode.claude-sync"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SERVICE_NAME="opencode-claude-sync.service"
SYSTEMD_TIMER_NAME="opencode-claude-sync.timer"

if [[ "$(uname)" == "Darwin" ]]; then
  echo "==> Removing LaunchAgent..."
  if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo "    LaunchAgent removed."
  else
    echo "    No LaunchAgent found. Skipping."
  fi
else
  if command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1 \
    && [[ -f "${SYSTEMD_USER_DIR}/${SYSTEMD_TIMER_NAME}" || -f "${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}" ]]; then
    echo "==> Removing systemd user timer..."
    systemctl --user disable --now "$SYSTEMD_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_USER_DIR}/${SYSTEMD_TIMER_NAME}" "${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "    Timer removed."
  fi

  echo "==> Removing cron job..."
  if command -v crontab >/dev/null 2>&1; then
    EXISTING=$(crontab -l 2>/dev/null || true)
    if echo "$EXISTING" | grep -qF "$CRON_MARKER"; then
      FILTERED=$(echo "$EXISTING" | grep -vF "$CRON_MARKER" || true)
      if [[ -z "$FILTERED" ]]; then
        crontab -r 2>/dev/null || true
      else
        echo "$FILTERED" | crontab -
      fi
      echo "    Cron removed."
    else
      echo "    No cron found. Skipping."
    fi
  else
    echo "    crontab not found. Skipping."
  fi
fi

echo "==> Removing sync script..."
if [[ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]]; then
  rm "${INSTALL_DIR}/${SCRIPT_NAME}"
  echo "    Script removed."
else
  echo "    Script not found. Skipping."
fi

echo ""
echo "Done. OpenCode auth.json was not modified."
echo "To remove the Anthropic entry manually:"
echo "  node -e \"const fs=require('fs'),p=process.env.HOME+'/.local/share/opencode/auth.json',a=JSON.parse(fs.readFileSync(p,'utf8'));delete a.anthropic;fs.writeFileSync(p,JSON.stringify(a,null,2))\""
