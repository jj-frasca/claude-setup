#!/bin/bash
# SessionStart hook — injects daily context into each session.
# Outputs additionalContext with: date, last cron run status, launchd agent health.
# Never blocks — exits 0 always; context is best-effort.

CRON_LOG="$HOME/.claude/_reports/cron.log"
TODAY=$(date +"%Y-%m-%d")
NOW=$(date "+%Y-%m-%d %I:%M %p")

# Last 3 cron entries
if [[ -f "$CRON_LOG" ]]; then
  CRON_SUMMARY=$(tail -3 "$CRON_LOG" | while IFS= read -r line; do
    job=$(echo "$line" | jq -r '.job // "?"' 2>/dev/null)
    status=$(echo "$line" | jq -r '.status // "?"' 2>/dev/null)
    detail=$(echo "$line" | jq -r '.detail // ""' 2>/dev/null)
    ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null | cut -c1-16)
    echo "  $ts $job: $status ($detail)"
  done)
else
  CRON_SUMMARY="  (no cron runs yet)"
fi

# Launchd agent status (exit 0=running, 3=not running)
check_agent() {
  local label="$1"
  launchctl list "$label" >/dev/null 2>&1 && echo "running" || echo "not running"
}

SH_STATUS=$(check_agent "com.jjfrasca.selfheal")
MEM_STATUS=$(check_agent "com.jjfrasca.memory")
SK_STATUS=$(check_agent "com.jjfrasca.skills")
BOT_STATUS=$(check_agent "com.jjfrasca.slackbot")

CONTEXT="Session started: $NOW
Today: $TODAY

Cron (last 3 runs):
$CRON_SUMMARY

LaunchAgents:
  self-heal: $SH_STATUS | memory: $MEM_STATUS | skills: $SK_STATUS | slack-bot: $BOT_STATUS"

# Output JSON with additionalContext for the model
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$(echo "$CONTEXT" | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')"

exit 0
