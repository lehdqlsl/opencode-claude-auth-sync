#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"
ALIAS_NAME="claude-sync"
REPO_RAW="https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main"
CRON_MARKER="# opencode-claude-auth-sync"
SYSTEMD_SERVICE_NAME="opencode-claude-sync.service"
SYSTEMD_TIMER_NAME="opencode-claude-sync.timer"

CLAUDE_CREDS="${HOME}/.claude/.credentials.json"
OPENCODE_AUTH="${HOME}/.local/share/opencode/auth.json"

echo "==> Checking prerequisites..."

command -v node >/dev/null 2>&1 || { echo "ERROR: node is required but not found"; exit 1; }

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
  echo "Run OpenCode CLI or OpenCode Desktop at least once first."
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
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${ALIAS_NAME}"

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

NO_SCHEDULER="${NO_SCHEDULER:-false}"
if [[ "${1:-}" == "--no-scheduler" ]]; then
  NO_SCHEDULER=true
fi

# Resolve minimal PATH from required binaries instead of injecting full PATH
SYNC_PATH="/usr/local/bin:/usr/bin:/bin"
for bin in node claude; do
  bin_path=$(type -P "$bin" 2>/dev/null || true)
  if [[ -n "$bin_path" && "$bin_path" == /* ]]; then
    bin_dir=$(dirname "$bin_path")
    case ":${SYNC_PATH}:" in
      *":${bin_dir}:"*) ;;
      *) SYNC_PATH="${bin_dir}:${SYNC_PATH}" ;;
    esac
  fi
done

if ! PATH="$SYNC_PATH" type -P node >/dev/null 2>&1; then
  echo "    WARNING: node may not be found by the scheduled job. Re-run installer after fixing your node setup." >&2
fi

if [[ "$NO_SCHEDULER" == "true" ]]; then
  echo "==> Skipping scheduler setup (--no-scheduler)."
  echo "    Run manually when needed: ${INSTALL_DIR}/${ALIAS_NAME}"

elif [[ "$(uname)" == "Darwin" ]]; then
  echo "==> Setting up LaunchAgent (every 15 minutes)..."
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
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${SYNC_PATH}</string>
  </dict>
  <key>StartInterval</key>
  <integer>900</integer>
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
  echo "    Runs every 15 minutes + on login + catches up after sleep."

else
  # systemd user timer is the Linux equivalent of the macOS LaunchAgent above:
  # Persistent=true catches up missed runs after sleep/resume and reboot.
  # Cron is the fallback for systems without user systemd.
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    echo "==> Setting up systemd user timer (every 15 minutes, catches up after sleep/reboot)..."
    SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
    LOG_PATH="${HOME}/.local/share/opencode/sync-claude.log"

    mkdir -p "$SYSTEMD_USER_DIR"
    mkdir -p "$(dirname "$LOG_PATH")"

    cat > "${SYSTEMD_USER_DIR}/${SYSTEMD_SERVICE_NAME}" <<SERVICE
[Unit]
Description=Sync Claude credentials to OpenCode
Documentation=https://github.com/lehdqlsl/opencode-claude-auth-sync

[Service]
Type=oneshot
Environment=PATH=${SYNC_PATH}
ExecStart=/bin/sh -c 'exec "${INSTALL_DIR}/${SCRIPT_NAME}" >> "${LOG_PATH}" 2>&1'
SERVICE

    cat > "${SYSTEMD_USER_DIR}/${SYSTEMD_TIMER_NAME}" <<TIMER
[Unit]
Description=Periodic Claude -> OpenCode credential sync
Documentation=https://github.com/lehdqlsl/opencode-claude-auth-sync

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min
Persistent=true
Unit=${SYSTEMD_SERVICE_NAME}

[Install]
WantedBy=timers.target
TIMER

    systemctl --user daemon-reload
    systemctl --user enable --now "$SYSTEMD_TIMER_NAME" >/dev/null

    if command -v crontab >/dev/null 2>&1; then
      EXISTING=$(crontab -l 2>/dev/null || true)
      if echo "$EXISTING" | grep -qF "$CRON_MARKER"; then
        FILTERED=$(echo "$EXISTING" | grep -vF "$CRON_MARKER" || true)
        if [[ -z "$FILTERED" ]]; then
          crontab -r 2>/dev/null || true
        else
          echo "$FILTERED" | crontab -
        fi
        echo "    Migrated legacy cron entry to systemd timer."
      fi
    fi

    echo "    Timer registered: $SYSTEMD_TIMER_NAME"
    echo "    Runs every 15 minutes + at boot + catches up after sleep/reboot (Persistent=true)."

  elif command -v crontab >/dev/null 2>&1; then
    echo "==> Setting up cron (every 15 minutes + @reboot)..."
    echo "    NOTE: cron does not run while the system is suspended. On laptops, prefer systemd --user."
    CRON_PERIODIC="*/15 * * * * PATH=\"${SYNC_PATH}\" ${INSTALL_DIR}/${SCRIPT_NAME} >> ${HOME}/.local/share/opencode/sync-claude.log 2>&1 ${CRON_MARKER}"
    CRON_BOOT="@reboot sleep 30 && PATH=\"${SYNC_PATH}\" ${INSTALL_DIR}/${SCRIPT_NAME} >> ${HOME}/.local/share/opencode/sync-claude.log 2>&1 ${CRON_MARKER}"

    EXISTING=$(crontab -l 2>/dev/null || true)
    FILTERED=$(echo "$EXISTING" | grep -vF "$CRON_MARKER" || true)
    if [[ -z "$FILTERED" ]]; then
      printf '%s\n%s\n' "$CRON_PERIODIC" "$CRON_BOOT" | crontab -
    else
      printf '%s\n%s\n%s\n' "$FILTERED" "$CRON_PERIODIC" "$CRON_BOOT" | crontab -
    fi
    echo "    Cron registered (periodic every 15 min + @reboot catch-up)."

  else
    echo "    WARNING: neither systemd --user nor crontab available. Set up a periodic job manually:"
    echo "      ${INSTALL_DIR}/${SCRIPT_NAME}"
  fi
fi

echo ""
echo "Done! Verify with:"
echo "  ${ALIAS_NAME} --status         # Check token + quota status"
echo "  ${ALIAS_NAME}                 # Sync active account"
echo "  opencode providers list    # Should show: Anthropic oauth"
echo "  opencode models anthropic  # Should list Claude models"
