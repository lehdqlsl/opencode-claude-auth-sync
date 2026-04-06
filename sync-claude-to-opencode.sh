#!/usr/bin/env bash
set -euo pipefail

OPENCODE_AUTH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"

VERSION="0.6.0"

# Suppress normal output when not running in a terminal (e.g. LaunchAgent/cron).
# Errors and warnings always go to stderr regardless.
if [[ -t 1 ]]; then
  QUIET=0
else
  QUIET=1
fi

MODE="sync"
case "${1:-}" in
  --status)  MODE="status" ;;
  --help|-h) MODE="help" ;;
  --version|-v) echo "opencode-claude-auth-sync v${VERSION}"; exit 0 ;;
  "") ;;
  *) echo "Unknown command: ${1}" >&2; echo "Run --help for usage." >&2; exit 1 ;;
esac

if [[ "$MODE" == "help" ]]; then
  cat <<'EOF'
Usage: sync-claude-to-opencode.sh [command]

  (no args)           Sync Claude credentials to OpenCode
  --status            Show current token status and usage
  --help              Show this help
  --version           Show version
EOF
  exit 0
fi

[[ ! -f "$OPENCODE_AUTH" ]] && exit 0
command -v node >/dev/null 2>&1 || { echo "node not found" >&2; exit 1; }

# --- Warn about deprecated cached plugin ---
DEPRECATED_PLUGIN="$HOME/.cache/opencode/node_modules/opencode-anthropic-auth"
if [[ -d "$DEPRECATED_PLUGIN" ]]; then
  echo "⚠️  Deprecated opencode-anthropic-auth plugin detected in cache." >&2
  echo "   This may cause 429 errors. Remove it with:" >&2
  echo "   rm -rf $DEPRECATED_PLUGIN" >&2
fi

# --- Read Claude credentials (platform-aware) ---

read_claude_creds() {
  if [[ -n "${CLAUDE_CREDENTIALS_PATH:-}" ]] && [[ -f "$CLAUDE_CREDENTIALS_PATH" ]]; then
    cat "$CLAUDE_CREDENTIALS_PATH"
    return
  fi

  if [[ "$(uname)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    local keychain_result=""
    local exit_code=0
    keychain_result=$(security find-generic-password -s "Claude Code-credentials" -w 2>&1) || exit_code=$?

    case $exit_code in
      0)   echo "$keychain_result"; return ;;
      44)  ;; # item not found, fall through to file
      36)  echo "macOS Keychain is locked. Run: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2; exit 1 ;;
      128) echo "macOS Keychain access denied. Grant access when prompted." >&2; exit 1 ;;
      *)
        if [[ $exit_code -eq 143 ]] || echo "$keychain_result" | grep -qi "timeout"; then
          echo "macOS Keychain read timed out. Try restarting Keychain Access." >&2; exit 1
        fi
        ;; # unknown error, fall through to file
    esac

    if [[ -f "$HOME/.claude/.credentials.json" ]]; then
      cat "$HOME/.claude/.credentials.json"
      return
    fi
    return
  fi

  if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    cat "$HOME/.claude/.credentials.json"
  fi
}

# --- CLI auto-refresh ---

refresh_via_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude CLI not found, cannot auto-refresh" >&2
    return 1
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%S.000Z) refreshing via claude CLI..." >&2
  timeout 60 claude -p . --model claude-haiku-4-5 </dev/null >/dev/null 2>&1 || true
}

print_usage_status() {
  local access_token="$1"
  [[ -z "$access_token" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0

  curl -fsS \
    -H "Authorization: Bearer $access_token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null | node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;
if (!input) process.exit(0);

const usage = JSON.parse(input);

const formatReset = (value) => {
  if (!value) return '?';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toISOString();
};

const formatUtil = (value) => {
  if (value == null) return '?';
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(1)));
};

console.log('Usage:   5h ' + formatUtil(usage.five_hour?.utilization) + '% (reset: ' + formatReset(usage.five_hour?.resets_at) + ')');
console.log('         7d ' + formatUtil(usage.seven_day?.utilization) + '% (reset: ' + formatReset(usage.seven_day?.resets_at) + ')');
if (usage.seven_day_sonnet?.utilization != null) {
  console.log('         sonnet ' + formatUtil(usage.seven_day_sonnet.utilization) + '%');
}
" 2>/dev/null || true
}

# ==========================================================================
#  Status
# ==========================================================================

cmd_status() {
  local CLAUDE_JSON
  CLAUDE_JSON=$(read_claude_creds)
  if [[ -z "$CLAUDE_JSON" ]]; then
    echo "No Claude credentials found" >&2
    exit 0
  fi

  local status_output
  status_output=$(echo "$CLAUDE_JSON" | node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const raw = JSON.parse(input);
  const creds = raw.claudeAiOauth ?? raw;
  const remaining = (creds.expiresAt || 0) - Date.now();
  const hours = Math.floor(remaining / 3600000);
  const mins = Math.floor((remaining % 3600000) / 60000);
  const expires = new Date(creds.expiresAt).toISOString();
  if (remaining <= 0) {
    console.log('Status:  EXPIRED');
    console.log('Expired: ' + expires);
  } else {
    console.log('Status:  valid (' + hours + 'h ' + mins + 'm remaining)');
    console.log('Expires: ' + expires);
  }
  if (creds.subscriptionType) {
    const tier = creds.rateLimitTier ? ' (' + creds.rateLimitTier + ')' : '';
    console.log('Plan:    ' + creds.subscriptionType + tier);
  }
} catch (e) {
  console.error('Failed to parse credentials: ' + e.message);
  process.exit(1);
}
")
  local active_access
  active_access=$(echo "$CLAUDE_JSON" | node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;
const raw = JSON.parse(input);
const creds = raw.claudeAiOauth ?? raw;
if (creds.accessToken) console.log(creds.accessToken);
" 2>/dev/null)
  printf '%s\n' "$status_output"
  print_usage_status "$active_access"
}

# ==========================================================================
#  Core sync logic
# ==========================================================================

do_sync() {
  local CLAUDE_JSON
  CLAUDE_JSON=$(read_claude_creds)

  if [[ -z "$CLAUDE_JSON" ]]; then
    echo "No credentials available" >&2
    exit 0
  fi

  local NEED_REFRESH
  NEED_REFRESH=$(echo "$CLAUDE_JSON" | node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const raw = JSON.parse(input);
  const creds = raw.claudeAiOauth ?? raw;
  const remaining = (creds.expiresAt || 0) - Date.now();
  console.log(remaining <= 0 ? 'yes' : 'no');
} catch { console.log('no'); }
" 2>/dev/null || echo "no")

  if [[ "$NEED_REFRESH" == "yes" ]]; then
    refresh_via_cli
    CLAUDE_JSON=$(read_claude_creds)
    if [[ -z "$CLAUDE_JSON" ]]; then
      echo "No credentials found after refresh" >&2
      exit 1
    fi
  fi

  export OPENCODE_AUTH_FILE="$OPENCODE_AUTH"
  export SYNC_QUIET="$QUIET"
  echo "$CLAUDE_JSON" | node --input-type=module -e "
import fs from 'node:fs';

const quiet = process.env.SYNC_QUIET === '1';
let input = '';
for await (const chunk of process.stdin) input += chunk;

let creds;
try {
  const raw = JSON.parse(input);
  creds = raw.claudeAiOauth ?? raw;
} catch (e) {
  console.error('Failed to parse credentials: ' + e.message);
  process.exit(1);
}

if (!creds.accessToken || !creds.refreshToken || !creds.expiresAt) {
  console.error('Credentials incomplete');
  process.exit(1);
}

const authPath = process.env.OPENCODE_AUTH_FILE;

let auth;
try {
  auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
} catch (e) {
  console.error('Failed to parse ' + authPath + ': ' + e.message);
  process.exit(1);
}

const remaining = creds.expiresAt - Date.now();
const hours = Math.floor(remaining / 3600000);
const mins = Math.floor((remaining % 3600000) / 60000);
const status = remaining > 0 ? hours + 'h ' + mins + 'm remaining' : 'EXPIRED';

if (
  auth.anthropic &&
  auth.anthropic.access === creds.accessToken &&
  auth.anthropic.refresh === creds.refreshToken &&
  auth.anthropic.expires === creds.expiresAt
) {
  if (!quiet) console.log(new Date().toISOString() + ' already in sync (' + status + ')');
  process.exit(0);
}

auth.anthropic = {
  type: 'oauth',
  access: creds.accessToken,
  refresh: creds.refreshToken,
  expires: creds.expiresAt,
};

const tmpPath = authPath + '.tmp.' + process.pid;
try {
  fs.writeFileSync(tmpPath, JSON.stringify(auth, null, 2), { mode: 0o600 });
  fs.renameSync(tmpPath, authPath);
} catch (e) {
  try { fs.unlinkSync(tmpPath); } catch {}
  throw e;
}
if (!quiet) console.log(new Date().toISOString() + ' synced (' + status + ')');
"
}

# ==========================================================================
#  Dispatch
# ==========================================================================

case "$MODE" in
  status) cmd_status ;;
  sync)   do_sync ;;
esac
