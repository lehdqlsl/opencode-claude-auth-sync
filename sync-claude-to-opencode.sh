#!/usr/bin/env bash
set -euo pipefail

OPENCODE_AUTH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
REFRESH_THRESHOLD=60000  # 60 seconds

[[ ! -f "$OPENCODE_AUTH" ]] && exit 0
command -v node >/dev/null 2>&1 || { echo "node not found" >&2; exit 1; }

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
    return 1
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%S.000Z) token expiring soon, refreshing via claude CLI..." >&2
  timeout 60 claude -p . --model claude-haiku-4-5-20250514 </dev/null >/dev/null 2>&1 || true
}

# --- Main ---

CLAUDE_JSON=$(read_claude_creds)

if [[ -z "$CLAUDE_JSON" ]]; then
  echo "No Claude credentials found" >&2
  exit 0
fi

export OPENCODE_AUTH_FILE="$OPENCODE_AUTH"
export REFRESH_THRESHOLD

NEED_REFRESH=$(echo "$CLAUDE_JSON" | node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const raw = JSON.parse(input);
  const creds = raw.claudeAiOauth ?? raw;
  const remaining = (creds.expiresAt || 0) - Date.now();
  console.log(remaining <= Number(process.env.REFRESH_THRESHOLD) ? 'yes' : 'no');
} catch { console.log('no'); }
" 2>/dev/null || echo "no")

if [[ "$NEED_REFRESH" == "yes" ]]; then
  refresh_via_cli
  CLAUDE_JSON=$(read_claude_creds)
  if [[ -z "$CLAUDE_JSON" ]]; then
    echo "No Claude credentials found after refresh" >&2
    exit 1
  fi
fi

echo "$CLAUDE_JSON" | node --input-type=module -e "
import fs from 'node:fs';

let input = '';
for await (const chunk of process.stdin) input += chunk;

let creds;
try {
  const raw = JSON.parse(input);
  creds = raw.claudeAiOauth ?? raw;
} catch (e) {
  console.error('Failed to parse Claude credentials: ' + e.message);
  process.exit(1);
}

if (!creds.accessToken || !creds.refreshToken || !creds.expiresAt) {
  console.error('Claude credentials incomplete');
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
  console.log(new Date().toISOString() + ' already in sync (' + status + ')');
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
console.log(new Date().toISOString() + ' synced (' + status + ')');
"
