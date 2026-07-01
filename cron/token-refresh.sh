#!/usr/bin/env bash
# Runs every 2h via launchd. Mirrors the current Keychain credential blob into
# ~/.claude/.claude_token for diagnostics and logs token expiry.
#
# This script intentionally does NOT perform an OAuth refresh. Refresh tokens
# rotate (single-use); when this job rotated them independently it desynced the
# Claude CLI's own rotating refresh token and produced HTTP 400 invalid_grant
# (observed 2026-06-27/29). The CLI is now the sole refresher — cron jobs
# authenticate straight from Keychain (see cron-env.sh) and the CLI's token
# manager refreshes with correct rotation. This job is just a mirror + monitor.
# See memory/auth_token_gap.md.

set -uo pipefail
KEYCHAIN_SERVICE="Claude Code-credentials"
TOKEN_FILE="$HOME/.claude/.claude_token"
REPORTS_DIR="$HOME/.claude/_reports"
SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"
JOB="token-refresh"
mkdir -p "$REPORTS_DIR"

log_cron() {
  printf '{"ts":"%s","job":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$JOB" "$1" "$2" >> "$REPORTS_DIR/cron.log"
}
notify_slack() {
  [[ -f "$SLACK_WEBHOOK_FILE" ]] || return 0
  local u; u=$(cat "$SLACK_WEBHOOK_FILE")
  [[ -n "$u" ]] || return 0
  curl -s -X POST "$u" -H 'Content-type: application/json' \
    -d "{\"text\": $(printf '%s' "$1" | jq -Rs .)}" >/dev/null 2>&1 || true
}

FRESH=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$(whoami)" -w 2>/dev/null)
if [[ -z "$FRESH" ]]; then
  log_cron "error" "keychain extraction failed"
  notify_slack "🔑 token-refresh: Keychain extraction failed — is Claude Code still signed in?"
  exit 0
fi
printf '%s' "$FRESH" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

read -r EXPIRES IS_EXPIRED < <(python3 -c "
import json, sys, time, datetime
try:
    d = json.loads(sys.argv[1]).get('claudeAiOauth', {})
    ts = d.get('expiresAt', 0) / 1000
    print(datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%dT%H:%M'), ts < time.time())
except Exception:
    print('unknown', True)
" "$FRESH" 2>/dev/null || echo "unknown True")

if [[ "$IS_EXPIRED" == "True" ]]; then
  # Keychain token is past expiry. The CLI refreshes it on the next job run; if
  # Joe is away long enough that the refresh token is also dead, jobs fail until
  # he opens Claude Code. Logged (no Slack) to avoid every-2h alert spam.
  log_cron "warn" "token_expired expires=$EXPIRES (CLI refreshes on next use)"
else
  log_cron "ok" "expires=$EXPIRES"
fi
