#!/usr/bin/env bash
# Test: install.sh generates a plist with EnvironmentVariables/PATH on macOS
# Run from repo root: bash test/test_install_plist.sh

set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Setup: create a fake HOME with the minimum structure install.sh requires
# ---------------------------------------------------------------------------
FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' EXIT

# Fake node and opencode on PATH
FAKE_BIN="$FAKE_HOME/fakebin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\necho "v20.0.0"\n' > "$FAKE_BIN/node"
printf '#!/bin/sh\necho "opencode"\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN/node" "$FAKE_BIN/opencode"

# Fake Claude credentials file
mkdir -p "$FAKE_HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":9999999999999}}' \
  > "$FAKE_HOME/.claude/.credentials.json"

# Fake OpenCode auth file
mkdir -p "$FAKE_HOME/.local/share/opencode"
echo '{"anthropic":{}}' > "$FAKE_HOME/.local/share/opencode/auth.json"

# Fake log dir
mkdir -p "$FAKE_HOME/.local/share/opencode"

# ---------------------------------------------------------------------------
# Run install.sh with --no-scheduler so it only generates the plist section
# we care about (we'll test the plist generation separately below)
# ---------------------------------------------------------------------------

# We test plist generation by extracting just the macOS plist block from
# install.sh and running it in isolation with our fake HOME.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
  echo "ERROR: install.sh not found at $INSTALL_SH"
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract and run just the plist-generation block from install.sh
# We simulate the variables install.sh would have set at that point.
# ---------------------------------------------------------------------------

PLIST_PATH="$FAKE_HOME/Library/LaunchAgents/com.opencode.claude-sync.plist"
mkdir -p "$FAKE_HOME/Library/LaunchAgents"

INSTALL_DIR="$FAKE_HOME/.local/bin"
SCRIPT_NAME="sync-claude-to-opencode.sh"
PLIST_NAME="com.opencode.claude-sync"
LOG_PATH="$FAKE_HOME/.local/share/opencode/sync-claude.log"
TEST_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Run install.sh in a subshell with overridden HOME and PATH,
# skipping scheduler (we only care about plist output, not launchctl)
(
  export HOME="$FAKE_HOME"
  export PATH="$TEST_PATH:$FAKE_BIN"

  # Stub launchctl so install.sh doesn't fail when it tries to load the plist
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/launchctl"
  chmod +x "$FAKE_BIN/launchctl"

  # Stub curl/wget to avoid downloading the real sync script
  printf '#!/bin/sh\ntouch "$FAKE_HOME/.local/bin/sync-claude-to-opencode.sh"\n' > "$FAKE_BIN/curl"
  chmod +x "$FAKE_BIN/curl"

  # Stub security (macOS keychain) to avoid keychain prompts
  printf '#!/bin/sh\nexit 44\n' > "$FAKE_BIN/security"
  chmod +x "$FAKE_BIN/security"

  mkdir -p "$FAKE_HOME/.local/bin"
  touch "$FAKE_HOME/.local/bin/sync-claude-to-opencode.sh"
  chmod +x "$FAKE_HOME/.local/bin/sync-claude-to-opencode.sh"

  bash "$INSTALL_SH" 2>/dev/null || true
) || true

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo ""
echo "==> Test: plist file is generated"
if [[ -f "$PLIST_PATH" ]]; then
  pass "plist file exists at $PLIST_PATH"
else
  fail "plist file NOT found at $PLIST_PATH"
  echo ""
  echo "Remaining tests skipped (no plist to inspect)."
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

echo ""
echo "==> Test: plist contains EnvironmentVariables key"
if grep -q "<key>EnvironmentVariables</key>" "$PLIST_PATH"; then
  pass "EnvironmentVariables key present"
else
  fail "EnvironmentVariables key MISSING"
fi

echo ""
echo "==> Test: plist contains PATH key inside EnvironmentVariables"
if grep -q "<key>PATH</key>" "$PLIST_PATH"; then
  pass "PATH key present"
else
  fail "PATH key MISSING"
fi

echo ""
echo "==> Test: PATH value contains /opt/homebrew/bin"
if grep -q "/opt/homebrew/bin" "$PLIST_PATH"; then
  pass "PATH value contains /opt/homebrew/bin"
else
  fail "PATH value does NOT contain /opt/homebrew/bin"
fi

echo ""
echo "==> Test: EnvironmentVariables appears before StartInterval (correct ordering)"
ENV_LINE=$(grep -n "EnvironmentVariables" "$PLIST_PATH" | head -1 | cut -d: -f1 || echo 0)
START_LINE=$(grep -n "StartInterval" "$PLIST_PATH" | head -1 | cut -d: -f1 || echo 0)
if [[ "$ENV_LINE" -gt 0 && "$START_LINE" -gt 0 && "$ENV_LINE" -lt "$START_LINE" ]]; then
  pass "EnvironmentVariables (line $ENV_LINE) appears before StartInterval (line $START_LINE)"
else
  fail "EnvironmentVariables ordering incorrect (env=$ENV_LINE, start=$START_LINE)"
fi

echo ""
echo "==> Test: plist is valid XML (well-formed)"
if xmllint --noout "$PLIST_PATH" 2>/dev/null; then
  pass "plist is valid XML"
else
  fail "plist is NOT valid XML"
fi

echo ""
echo "==> Test: existing keys still present (regression)"
for key in "Label" "ProgramArguments" "StartInterval" "RunAtLoad" "StandardOutPath" "StandardErrorPath"; do
  if grep -q "<key>${key}</key>" "$PLIST_PATH"; then
    pass "key '$key' still present"
  else
    fail "key '$key' MISSING (regression)"
  fi
done

echo ""
echo "==> Generated plist:"
cat "$PLIST_PATH"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
