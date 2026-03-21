#!/usr/bin/env bash
set -euo pipefail

OPENCODE_AUTH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
ACCOUNTS_DIR="${HOME}/.config/opencode-claude-auth-sync"
ACCOUNTS_FILE="${ACCOUNTS_DIR}/accounts.json"
ACCOUNTS_LOCK_DIR="${ACCOUNTS_DIR}/accounts.lock"

MODE="sync"
ARG_LABEL=""
case "${1:-}" in
  --status)  MODE="status" ;;
  --force)   MODE="force" ;;
  --add)     MODE="add";    ARG_LABEL="${2:-}" ;;
  --login)   MODE="login";  ARG_LABEL="${2:-}" ;;
  --remove)  MODE="remove"; ARG_LABEL="${2:-}" ;;
  --list)    MODE="list" ;;
  --switch)  MODE="switch"; ARG_LABEL="${2:-}" ;;
  --rotate)  MODE="rotate" ;;
  --help|-h) MODE="help" ;;
esac

if [[ "$MODE" == "help" ]]; then
  cat <<'EOF'
Usage: sync-claude-to-opencode.sh [command]

Sync:
  (no args)           Sync active account to OpenCode
  --status            Show current token status
  --force             Force refresh via Claude CLI

Multi-account:
  --add <label>       Save current Claude CLI credentials as named account
  --login <label>     Log into Claude CLI, then save it as named account
  --remove <label>    Remove a stored account
  --list              List all stored accounts with status
  --switch <label>    Switch active account and sync
  --rotate            Rotate to next account (round-robin) and sync

  --help              Show this help

Multi-account setup:
  1. sync-claude-to-opencode.sh --login personal
  2. sync-claude-to-opencode.sh --login work
  3. sync-claude-to-opencode.sh --switch personal
EOF
  exit 0
fi

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

# --- Accounts store helpers ---

has_accounts() {
  [[ -f "$ACCOUNTS_FILE" ]]
}

ensure_accounts_dir() {
  mkdir -p "$ACCOUNTS_DIR"
  chmod 700 "$ACCOUNTS_DIR"
}

acquire_accounts_lock() {
  ensure_accounts_dir
  local attempts=0
  while ! mkdir "$ACCOUNTS_LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts >= 300 )); then
      echo "Timed out waiting for accounts lock" >&2
      return 1
    fi
    sleep 0.1
  done
}

release_accounts_lock() {
  rmdir "$ACCOUNTS_LOCK_DIR" 2>/dev/null || true
}

write_accounts_json() {
  # Reads JSON from stdin, writes atomically to ACCOUNTS_FILE
  local tmp="${ACCOUNTS_FILE}.tmp.$$"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ACCOUNTS_FILE"
}

# ==========================================================================
#  Multi-account commands
# ==========================================================================

cmd_add() {
  local label="$1"
  if [[ -z "$label" ]]; then
    echo "Usage: --add <label>" >&2
    echo "Example: sync-claude-to-opencode.sh --add personal" >&2
    exit 1
  fi

  ensure_accounts_dir
  acquire_accounts_lock
  trap 'release_accounts_lock' RETURN

  local CLAUDE_JSON
  CLAUDE_JSON=$(read_claude_creds)
  if [[ -z "$CLAUDE_JSON" ]]; then
    echo "No Claude credentials found. Run 'claude' first to authenticate." >&2
    exit 1
  fi

  local EXISTING=""
  if has_accounts; then
    EXISTING=$(cat "$ACCOUNTS_FILE")
  fi

  echo "$CLAUDE_JSON" | LABEL="$label" EXISTING="$EXISTING" node --input-type=module -e "
let input = '';
for await (const chunk of process.stdin) input += chunk;

const raw = JSON.parse(input);
const creds = raw.claudeAiOauth ?? raw;

if (!creds.accessToken || !creds.refreshToken || !creds.expiresAt) {
  console.error('Claude credentials incomplete');
  process.exit(1);
}

const label = process.env.LABEL;
let store;
try {
  store = JSON.parse(process.env.EXISTING || '');
} catch {
  store = { accounts: {}, active: null, rotationIndex: 0 };
}

const isUpdate = !!store.accounts[label];
store.accounts[label] = {
  accessToken: creds.accessToken,
  refreshToken: creds.refreshToken,
  expiresAt: creds.expiresAt,
  subscriptionType: creds.subscriptionType || null,
  rateLimitTier: creds.rateLimitTier || null,
  addedAt: new Date().toISOString(),
};

if (!store.active || !store.accounts[store.active]) {
  store.active = label;
}

console.log(JSON.stringify(store, null, 2));

const remaining = creds.expiresAt - Date.now();
const hours = Math.floor(remaining / 3600000);
const mins = Math.floor((remaining % 3600000) / 60000);
const timeStr = remaining > 0 ? hours + 'h ' + mins + 'm remaining' : 'EXPIRED';
const count = Object.keys(store.accounts).length;
const activeTag = store.active === label ? ' (active)' : '';

const verb = isUpdate ? 'Updated' : 'Added';
console.error(verb + ': ' + label + activeTag + ' — ' + timeStr);
console.error(count + ' account(s) total.');
" 2>&2 | write_accounts_json

  trap - RETURN
  release_accounts_lock
}

cmd_login() {
  local label="$1"
  if [[ -z "$label" ]]; then
    echo "Usage: --login <label>" >&2
    echo "Example: sync-claude-to-opencode.sh --login max2" >&2
    exit 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude CLI not found" >&2
    exit 1
  fi

  claude auth logout >/dev/null 2>&1 || true

  echo "==> Log in with the account you want to save as '$label'" >&2
  claude auth login --claudeai

  cmd_add "$label"
}

cmd_remove() {
  local label="$1"
  if [[ -z "$label" ]]; then
    echo "Usage: --remove <label>" >&2
    exit 1
  fi
  if ! has_accounts; then
    echo "No accounts stored." >&2
    exit 1
  fi

  acquire_accounts_lock
  trap 'release_accounts_lock' RETURN

  LABEL="$label" node --input-type=module -e "
import fs from 'node:fs';

const accountsPath = '${ACCOUNTS_FILE}';
const label = process.env.LABEL;
const store = JSON.parse(fs.readFileSync(accountsPath, 'utf8'));

if (!store.accounts[label]) {
  console.error('Account not found: ' + label);
  const available = Object.keys(store.accounts);
  if (available.length > 0) console.error('Available: ' + available.join(', '));
  process.exit(1);
}

const count = Object.keys(store.accounts).length;

if (store.active === label && count > 1) {
  const others = Object.keys(store.accounts).filter(k => k !== label);
  store.active = others[0];
  store.rotationIndex = 0;
  console.error('Active switched to: ' + store.active);
} else if (count === 1) {
  store.active = null;
  store.rotationIndex = 0;
}

delete store.accounts[label];

console.log(JSON.stringify(store, null, 2));
console.error('Removed: ' + label + '. ' + Object.keys(store.accounts).length + ' account(s) remaining.');
" 2>&2 | write_accounts_json

  trap - RETURN
  release_accounts_lock
}

cmd_list() {
  if ! has_accounts; then
    echo "No accounts stored. Use --add <label> to add one." >&2
    exit 0
  fi

  node --input-type=module -e "
import fs from 'node:fs';

const store = JSON.parse(fs.readFileSync('${ACCOUNTS_FILE}', 'utf8'));
const labels = Object.keys(store.accounts);

if (labels.length === 0) {
  console.log('No accounts stored.');
  process.exit(0);
}

const now = Date.now();
console.log('');
console.log('  Label            Status     Remaining    Subscription');
console.log('  ───────────────  ─────────  ───────────  ────────────');

for (const label of labels) {
  const acc = store.accounts[label];
  const remaining = acc.expiresAt - now;
  const hours = Math.floor(remaining / 3600000);
  const mins = Math.floor((remaining % 3600000) / 60000);
  const status = remaining > 0 ? 'valid' : 'EXPIRED';
  const timeStr = remaining > 0 ? hours + 'h ' + mins + 'm' : '—';
  const marker = store.active === label ? ' *' : '';
  const sub = acc.subscriptionType || '—';
  console.log(
    '  ' +
    (label + marker).padEnd(17) +
    status.padEnd(11) +
    timeStr.padEnd(13) +
    sub
  );
}
console.log('');
console.log('  * = active');
console.log('');
"
}

cmd_switch() {
  local label="$1"
  if [[ -z "$label" ]]; then
    echo "Usage: --switch <label>" >&2
    exit 1
  fi
  if ! has_accounts; then
    echo "No accounts stored." >&2
    exit 1
  fi

  acquire_accounts_lock
  trap 'release_accounts_lock' RETURN

  LABEL="$label" node --input-type=module -e "
import fs from 'node:fs';

const accountsPath = '${ACCOUNTS_FILE}';
const label = process.env.LABEL;
const store = JSON.parse(fs.readFileSync(accountsPath, 'utf8'));

if (!store.accounts[label]) {
  console.error('Account not found: ' + label);
  console.error('Available: ' + Object.keys(store.accounts).join(', '));
  process.exit(1);
}

if (store.active === label) {
  console.error('Already active: ' + label);
  process.exit(0);
}

store.active = label;
const labels = Object.keys(store.accounts);
store.rotationIndex = labels.indexOf(label);

console.log(JSON.stringify(store, null, 2));
console.error('Switched to: ' + label);
" 2>&2 | write_accounts_json

  trap - RETURN
  release_accounts_lock

  do_sync
}

cmd_rotate() {
  if ! has_accounts; then
    echo "No accounts stored." >&2
    exit 1
  fi

  acquire_accounts_lock
  trap 'release_accounts_lock' RETURN

  node --input-type=module -e "
import fs from 'node:fs';

const accountsPath = '${ACCOUNTS_FILE}';
const store = JSON.parse(fs.readFileSync(accountsPath, 'utf8'));
const labels = Object.keys(store.accounts);

if (labels.length < 2) {
  console.error('Need at least 2 accounts to rotate. Have: ' + labels.length);
  process.exit(1);
}

const currentIndex = store.rotationIndex || 0;
const nextIndex = (currentIndex + 1) % labels.length;
store.rotationIndex = nextIndex;
store.active = labels[nextIndex];

console.log(JSON.stringify(store, null, 2));
console.error('Rotated to: ' + store.active + ' (' + (nextIndex + 1) + '/' + labels.length + ')');
" 2>&2 | write_accounts_json

  trap - RETURN
  release_accounts_lock

  do_sync
}

# ==========================================================================
#  Status
# ==========================================================================

cmd_status() {
  if has_accounts; then
    local status_output
    status_output=$(node --input-type=module -e "
import fs from 'node:fs';

const store = JSON.parse(fs.readFileSync('${ACCOUNTS_FILE}', 'utf8'));
const labels = Object.keys(store.accounts);
const active = store.active;
const acc = store.accounts[active];

if (!acc) {
  console.log('No active account');
  process.exit(1);
}

const now = Date.now();
const remaining = acc.expiresAt - now;
const hours = Math.floor(remaining / 3600000);
const mins = Math.floor((remaining % 3600000) / 60000);

console.log('Account: ' + active + ' (' + labels.length + ' total)');
if (remaining <= 0) {
  console.log('Status:  EXPIRED');
  console.log('Expired: ' + new Date(acc.expiresAt).toISOString());
} else {
  console.log('Status:  valid (' + hours + 'h ' + mins + 'm remaining)');
  console.log('Expires: ' + new Date(acc.expiresAt).toISOString());
}
if (acc.subscriptionType) console.log('Plan:    ' + acc.subscriptionType);
")
    local active_access
    active_access=$(node --input-type=module -e "
import fs from 'node:fs';

const store = JSON.parse(fs.readFileSync('${ACCOUNTS_FILE}', 'utf8'));
const acc = store.accounts[store.active];
if (acc?.accessToken) console.log(acc.accessToken);
" 2>/dev/null)
    printf '%s\n' "$status_output"
    print_usage_status "$active_access"
    return
  fi

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

get_active_creds_json() {
  # Returns JSON string of active account credentials.
  # If accounts store exists, use it. Otherwise, read Claude CLI creds directly.
  if has_accounts; then
    node --input-type=module -e "
import fs from 'node:fs';

const store = JSON.parse(fs.readFileSync('${ACCOUNTS_FILE}', 'utf8'));
if (!store.active || !store.accounts[store.active]) {
  process.exit(1);
}
const acc = store.accounts[store.active];
// Output in claudeAiOauth-compatible format
console.log(JSON.stringify({
  accessToken: acc.accessToken,
  refreshToken: acc.refreshToken,
  expiresAt: acc.expiresAt,
}));
" 2>/dev/null
  else
    local creds
    creds=$(read_claude_creds)
    if [[ -n "$creds" ]]; then
      echo "$creds"
    fi
  fi
}

auto_rotate_to_valid() {
  # Try to find a non-expired account and rotate to it.
  # Returns 0 if found, 1 if all expired.
  if ! has_accounts; then return 1; fi

  acquire_accounts_lock || return 1
  trap 'release_accounts_lock' RETURN

  local result
  result=$(node --input-type=module -e "
import fs from 'node:fs';

const accountsPath = '${ACCOUNTS_FILE}';
const store = JSON.parse(fs.readFileSync(accountsPath, 'utf8'));
const labels = Object.keys(store.accounts);
const now = Date.now();

// Try each account starting from next
const startIdx = ((store.rotationIndex || 0) + 1) % labels.length;
for (let i = 0; i < labels.length; i++) {
  const idx = (startIdx + i) % labels.length;
  const label = labels[idx];
  const acc = store.accounts[label];
  if (acc.expiresAt > now) {
    store.active = label;
    store.rotationIndex = idx;
    fs.writeFileSync(
      accountsPath + '.tmp.' + process.pid,
      JSON.stringify(store, null, 2),
      { mode: 0o600 }
    );
    fs.renameSync(accountsPath + '.tmp.' + process.pid, accountsPath);
    console.log(label);
    process.exit(0);
  }
}
// All expired
process.exit(1);
" 2>/dev/null) || {
    trap - RETURN
    release_accounts_lock
    return 1
  }

  echo "$(date -u +%Y-%m-%dT%H:%M:%S.000Z) auto-rotated to: ${result}" >&2
  trap - RETURN
  release_accounts_lock
  return 0
}

update_account_in_store() {
  # After CLI refresh, update the active account's tokens in the store
  local new_creds="$1"
  if ! has_accounts; then return; fi

  acquire_accounts_lock || return
  trap 'release_accounts_lock' RETURN

  echo "$new_creds" | node --input-type=module -e "
import fs from 'node:fs';

let input = '';
for await (const chunk of process.stdin) input += chunk;

const raw = JSON.parse(input);
const creds = raw.claudeAiOauth ?? raw;
if (!creds.accessToken) process.exit(0);

const accountsPath = '${ACCOUNTS_FILE}';
const store = JSON.parse(fs.readFileSync(accountsPath, 'utf8'));
if (!store.active || !store.accounts[store.active]) process.exit(0);

const acc = store.accounts[store.active];
acc.accessToken = creds.accessToken;
acc.refreshToken = creds.refreshToken;
acc.expiresAt = creds.expiresAt;
if (creds.subscriptionType) acc.subscriptionType = creds.subscriptionType;
if (creds.rateLimitTier) acc.rateLimitTier = creds.rateLimitTier;

const tmpPath = accountsPath + '.tmp.' + process.pid;
fs.writeFileSync(tmpPath, JSON.stringify(store, null, 2), { mode: 0o600 });
fs.renameSync(tmpPath, accountsPath);
" 2>/dev/null || true

  trap - RETURN
  release_accounts_lock
}

do_sync() {
  local CREDS_JSON
  CREDS_JSON=$(get_active_creds_json)

  if [[ -z "$CREDS_JSON" ]]; then
    echo "No credentials available" >&2
    exit 0
  fi

  local NEED_REFRESH
  NEED_REFRESH=$(echo "$CREDS_JSON" | node --input-type=module -e "
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
    # Multi-account: try rotating to a valid account first
    if has_accounts && auto_rotate_to_valid; then
      CREDS_JSON=$(get_active_creds_json)
    else
      # Single account or all expired: try CLI refresh
      refresh_via_cli
      local NEW_CLAUDE_JSON
      NEW_CLAUDE_JSON=$(read_claude_creds)
      if [[ -n "$NEW_CLAUDE_JSON" ]]; then
        update_account_in_store "$NEW_CLAUDE_JSON"
        CREDS_JSON=$(get_active_creds_json)
        if [[ -z "$CREDS_JSON" ]]; then
          CREDS_JSON="$NEW_CLAUDE_JSON"
        fi
      else
        echo "No credentials found after refresh" >&2
        exit 1
      fi
    fi
  fi

  export OPENCODE_AUTH_FILE="$OPENCODE_AUTH"
  echo "$CREDS_JSON" | node --input-type=module -e "
import fs from 'node:fs';

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
}

# ==========================================================================
#  Dispatch
# ==========================================================================

case "$MODE" in
  add)     cmd_add "$ARG_LABEL" ;;
  login)   cmd_login "$ARG_LABEL" ;;
  remove)  cmd_remove "$ARG_LABEL" ;;
  list)    cmd_list ;;
  switch)  cmd_switch "$ARG_LABEL" ;;
  rotate)  cmd_rotate ;;
  status)  cmd_status ;;
  force)
    refresh_via_cli
    NEW_CREDS=$(read_claude_creds)
    if [[ -n "$NEW_CREDS" ]]; then
      update_account_in_store "$NEW_CREDS"
    fi
    do_sync
    ;;
  sync)    do_sync ;;
esac
