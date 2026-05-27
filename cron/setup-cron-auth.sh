#!/usr/bin/env bash
# One-time setup: extracts Claude OAuth token from macOS Keychain and stores
# it in ~/.claude/.claude_token for use by headless cron jobs.
set -euo pipefail

TOKEN_FILE="$HOME/.claude/.claude_token"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude)}"

echo "Claude Cron Auth Setup"
echo "======================"

extract_from_keychain() {
  local service="$1"
  security find-generic-password -s "$service" -w 2>/dev/null || true
}

TOKEN=""

echo "Trying macOS Keychain..."
for service in \
  "Claude Code-credentials" \
  "Claude Code" \
  "claude-code" \
  "Anthropic Claude Code" \
  "anthropic-claude-code" \
  "Claude"; do
  TOKEN=$(security find-generic-password -s "$service" -a "$(whoami)" -w 2>/dev/null || \
          extract_from_keychain "$service")
  if [[ -n "$TOKEN" ]]; then
    echo "  Found token under service: \"$service\""
    break
  fi
done

if [[ -z "$TOKEN" ]]; then
  echo "  Keychain extraction failed — trying credentials file..."
  CREDS_FILE="$HOME/.claude/.credentials.json"
  if [[ -f "$CREDS_FILE" ]]; then
    TOKEN=$(jq -r '.oauth_token // .access_token // .token // empty' "$CREDS_FILE" 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
      echo "  Found token in $CREDS_FILE"
    fi
  fi
fi

if [[ -z "$TOKEN" ]]; then
  echo ""
  echo "Automatic extraction failed. To get your token manually:"
  echo "  1. Open a new terminal"
  echo "  2. Run: claude -p 'echo hi' --output-format json"
  echo "  3. If that works, look for the bearer token in:"
  echo "     Keychain Access.app → search 'claude'"
  echo "  4. Or check: ls ~/.claude/"
  echo ""
  read -rp "Paste your CLAUDE_CODE_OAUTH_TOKEN here (or press Enter to abort): " TOKEN
  if [[ -z "$TOKEN" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo ""
echo "Verifying token with live claude -p call..."
export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"

VERIFY_OUT=$(claude -p "Reply with just the word: verified" \
  --output-format json \
  --no-session-persistence \
  --allowedTools "" \
  --max-budget-usd 0.01 \
  2>&1) || {
    echo "ERROR: claude -p verification failed. Output:"
    echo "$VERIFY_OUT"
    echo ""
    echo "Token may be invalid or claude CLI not found at: $CLAUDE_BIN"
    exit 1
  }

echo "  Verification response: $(echo "$VERIFY_OUT" | jq -r '.result // "ok"' 2>/dev/null || echo "ok")"

mkdir -p "$(dirname "$TOKEN_FILE")"
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

echo ""
echo "Auth OK. Token stored at: $TOKEN_FILE"
echo ""
echo "Next: set your Slack webhook (optional):"
echo "  echo 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL' > ~/.claude/.slack_webhook"
echo "  chmod 600 ~/.claude/.slack_webhook"
