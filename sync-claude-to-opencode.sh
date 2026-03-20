#!/usr/bin/env bash
set -euo pipefail

CLAUDE_CREDS="${CLAUDE_CREDENTIALS_PATH:-$HOME/.claude/.credentials.json}"
OPENCODE_AUTH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"

[[ ! -f "$CLAUDE_CREDS" ]] && exit 0
[[ ! -f "$OPENCODE_AUTH" ]] && exit 0

command -v node >/dev/null 2>&1 || { echo "node not found" >&2; exit 1; }

node --input-type=module -e "
import fs from 'node:fs';

const claudeRaw = JSON.parse(fs.readFileSync('${CLAUDE_CREDS}', 'utf8'));
const creds = claudeRaw.claudeAiOauth ?? claudeRaw;

if (!creds.accessToken || !creds.refreshToken || !creds.expiresAt) {
  console.error('Claude credentials incomplete');
  process.exit(1);
}

const auth = JSON.parse(fs.readFileSync('${OPENCODE_AUTH}', 'utf8'));

if (
  auth.anthropic &&
  auth.anthropic.access === creds.accessToken &&
  auth.anthropic.refresh === creds.refreshToken
) {
  process.exit(0);
}

auth.anthropic = {
  type: 'oauth',
  access: creds.accessToken,
  refresh: creds.refreshToken,
  expires: creds.expiresAt,
};

fs.writeFileSync('${OPENCODE_AUTH}', JSON.stringify(auth, null, 2));
console.log(new Date().toISOString() + ' synced claude credentials to opencode');
"
