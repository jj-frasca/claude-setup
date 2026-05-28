#!/bin/bash
# StopFailure hook — fires when a session ends with an API error.
# Matchers: rate_limit, authentication_failed, etc.
# Posts to Slack so errors surface without tailing logs.

INPUT=$(cat)
REASON=$(echo "$INPUT" | jq -r '.stop_reason // "unknown"' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | head -c 8)
TIMESTAMP=$(date "+%Y-%m-%d %I:%M %p")

REPORTS_DIR="$HOME/.claude/_reports"
mkdir -p "$REPORTS_DIR"

# Log to cron.log always
printf '{"ts":"%s","job":"stop-failure","status":"error","detail":"reason=%s session=%s"}\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$REASON" "$SESSION" \
  >> "$REPORTS_DIR/cron.log"

# Don't send Slack for unknown edge cases
if [[ "$REASON" == "unknown" ]]; then exit 0; fi

SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"
if [[ ! -f "$SLACK_WEBHOOK_FILE" ]]; then exit 0; fi
WEBHOOK=$(cat "$SLACK_WEBHOOK_FILE")

case "$REASON" in
  rate_limit)
    ICON="⏳"
    MSG="Rate limit hit — session $SESSION paused at $TIMESTAMP. Resume when quota resets."
    ;;
  authentication_failed)
    ICON="🔑"
    MSG="Auth failed — session $SESSION at $TIMESTAMP. Run cron/setup-cron-auth.sh to refresh token."
    ;;
  *)
    ICON="⚠️"
    MSG="Session $SESSION ended with error: $REASON at $TIMESTAMP."
    ;;
esac

curl -s -X POST "$WEBHOOK" \
  -H 'Content-type: application/json' \
  -d "{\"text\":\"$ICON $MSG\"}" \
  >/dev/null 2>&1 || true

exit 0
