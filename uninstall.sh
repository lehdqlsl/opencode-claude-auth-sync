#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"

echo "==> Removing cron job..."
if crontab -l 2>/dev/null | grep -qF "$SCRIPT_NAME"; then
  crontab -l 2>/dev/null | grep -vF "$SCRIPT_NAME" | crontab -
  echo "    Cron removed."
else
  echo "    No cron found. Skipping."
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
echo "  node -e \"const fs=require('fs'),p='${HOME}/.local/share/opencode/auth.json',a=JSON.parse(fs.readFileSync(p,'utf8'));delete a.anthropic;fs.writeFileSync(p,JSON.stringify(a,null,2))\""
