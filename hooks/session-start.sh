#!/bin/bash
# SessionStart hook — injects daily context into each session.
# Outputs additionalContext with: date, last cron run status, launchd agent health.
# Never blocks — exits 0 always; context is best-effort.

CRON_LOG="$HOME/.claude/_reports/cron.log"
TODAY=$(date +"%Y-%m-%d")
NOW=$(date "+%Y-%m-%d %I:%M %p")

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

# Parse launchd agent: returns "running", "ok", "exit N", or "not loaded"
check_agent() {
  local label="$1"
  local info
  info=$(launchctl list "$label" 2>/dev/null) || { echo "not loaded"; return; }
  local pid exit_status
  pid=$(echo "$info" | grep '"PID"' | grep -o '[0-9]*' | head -1)
  exit_status=$(echo "$info" | grep '"LastExitStatus"' | grep -o '[0-9]*' | head -1)
  local code=$(( ${exit_status:-0} >> 8 ))
  if [[ -n "$pid" ]]; then
    echo "running"
  elif [[ "$code" -eq 0 ]]; then
    echo "ok"
  else
    echo "exit $code"
  fi
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
  self-heal: $SH_STATUS  memory: $MEM_STATUS  skills: $SK_STATUS  slack-bot: $BOT_STATUS"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$(echo "$CONTEXT" | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')"

exit 0
