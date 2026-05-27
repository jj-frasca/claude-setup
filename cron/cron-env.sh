#!/usr/bin/env bash
# Sourced by all cron scripts. Sets PATH, loads secrets, exports common vars.

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CLAUDE_TOKEN_FILE="$HOME/.claude/.claude_token"
SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"

if [[ ! -f "$CLAUDE_TOKEN_FILE" ]]; then
  echo "[cron-env] ERROR: $CLAUDE_TOKEN_FILE not found. Run cron/setup-cron-auth.sh first." >&2
  exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN=$(cat "$CLAUDE_TOKEN_FILE")

SLACK_WEBHOOK_URL=""
if [[ -f "$SLACK_WEBHOOK_FILE" ]]; then
  SLACK_WEBHOOK_URL=$(cat "$SLACK_WEBHOOK_FILE")
fi

export REPORTS_DIR="$HOME/.claude/_reports"
export CLAUDE_WORK="$HOME/claude-work/.claude"
export TODAY
TODAY=$(date +"%Y-%m-%d")

mkdir -p "$REPORTS_DIR"

notify_slack() {
  local message="$1"
  if [[ -z "$SLACK_WEBHOOK_URL" ]]; then return 0; fi
  curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-type: application/json' \
    -d "{\"text\": $(printf '%s' "$message" | jq -Rs .)}" \
    >/dev/null 2>&1 || true
}

log_cron() {
  local job="$1"
  local status="$2"
  local detail="$3"
  printf '{"ts":"%s","job":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$job" "$status" "$detail" \
    >> "$REPORTS_DIR/cron.log"
}
