#!/usr/bin/env bash
# Self-Heal: runs daily at 5 PM via launchd.
# Reads today's Claude sessions, analyzes for failures, writes ranked fix queue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="self-heal"
SESSION_INDEX="$HOME/.claude/_session_logs/index.jsonl"
REPORT_FILE="$REPORTS_DIR/$TODAY-selfheal.json"

echo "[$JOB] Starting — $TODAY"

if [[ ! -f "$SESSION_INDEX" ]]; then
  echo "[$JOB] No session index found. Nothing to analyze."
  notify_slack "🔧 Self-Heal [$TODAY]: No sessions recorded today. Skipped."
  log_cron "$JOB" "skipped" "no session index"
  exit 0
fi

TRANSCRIPT_PATHS=$(grep "\"ts\":\"${TODAY}" "$SESSION_INDEX" 2>/dev/null \
  | jq -r '.transcript // empty' 2>/dev/null \
  | grep -v '^$' || true)

SESSION_COUNT=$(echo "$TRANSCRIPT_PATHS" | grep -c '.' 2>/dev/null || echo 0)

if [[ "$SESSION_COUNT" -eq 0 ]]; then
  echo "[$JOB] No sessions for today. Nothing to analyze."
  notify_slack "🔧 Self-Heal [$TODAY]: No sessions today. Skipped."
  log_cron "$JOB" "skipped" "no sessions today"
  exit 0
fi

echo "[$JOB] Found $SESSION_COUNT session(s). Running analysis..."

TRANSCRIPT_LIST=$(echo "$TRANSCRIPT_PATHS" | head -20 | paste -sd ',' -)

PROMPT="You are analyzing Claude Code session transcripts to identify improvement opportunities.

Today is $TODAY. Analyze these transcript files (paths): $TRANSCRIPT_LIST

For each transcript file that exists and is readable, scan for:
1. Tool errors — any tool that returned an error, especially if retried multiple times
2. User corrections — messages containing words like 'no', 'stop', 'undo', 'revert', 'wrong', 'not that', 'actually'
3. Retry storms — same tool called 3+ times in a row with similar inputs
4. [DEGRADED] flags — any text matching '[DEGRADED]' in assistant messages
5. Incomplete tasks — conversation ends without a clear resolution or the user abandons mid-task

Return ONLY a valid JSON object in this exact format:
{
  \"generated_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
  \"session_count\": $SESSION_COUNT,
  \"fixes\": [
    {
      \"type\": \"tool_error|user_correction|retry_storm|degraded_skill|incomplete_task\",
      \"description\": \"brief description of the issue\",
      \"severity\": 1,
      \"suggested_fix\": \"concrete actionable fix\",
      \"session_id\": \"session id if identifiable\"
    }
  ]
}

Severity scale: 5=critical blocker, 4=significant friction, 3=notable, 2=minor, 1=informational.
Sort fixes by severity descending. If no issues found, return an empty fixes array.
Return ONLY the JSON, no other text."

RESPONSE=$(claude -p "$PROMPT" \
  --model claude-sonnet-4-6 \
  --allowedTools "Read,Bash" \
  --output-format json \
  --no-session-persistence \
  --max-budget-usd 0.50 \
  2>&1)

if [[ $? -ne 0 ]]; then
  echo "[$JOB] ERROR: claude -p failed"
  notify_slack "❌ Self-Heal [$TODAY] FAILED: claude -p error. See $REPORTS_DIR/cron-selfheal.log"
  log_cron "$JOB" "error" "claude -p failed"
  exit 1
fi

COST=$(echo "$RESPONSE" | jq -r '.total_cost_usd // "unknown"' 2>/dev/null || echo "unknown")
RAW_RESULT=$(echo "$RESPONSE" | jq -r '.result' 2>/dev/null)

# Strip markdown code fences if Claude wrapped the JSON in them
RESULT=$(echo "$RAW_RESULT" | sed 's/^```json//; s/^```//; s/```$//' | sed '/^$/d')

if ! echo "$RESULT" | jq . >/dev/null 2>&1; then
  echo "[$JOB] WARNING: result is not valid JSON. Raw result saved for inspection."
  echo "$RAW_RESULT" > "$REPORTS_DIR/$TODAY-selfheal-raw.txt"
  RESULT="{\"generated_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"session_count\":$SESSION_COUNT,\"fixes\":[],\"error\":\"claude returned non-JSON; see $TODAY-selfheal-raw.txt\"}"
fi

echo "$RESULT" > "$REPORT_FILE"

ISSUE_COUNT=$(echo "$RESULT" | jq '.fixes | length' 2>/dev/null || echo "?")
TOP_SEVERITY=$(echo "$RESULT" | jq '[.fixes[].severity] | max // 0' 2>/dev/null || echo "0")

echo "[$JOB] Done. $ISSUE_COUNT issue(s) found. Cost: \$$COST"
echo "[$JOB] Report: $REPORT_FILE"

SLACK_MSG="🔧 Self-Heal [$TODAY]: $SESSION_COUNT session(s), $ISSUE_COUNT issue(s) found (max severity: $TOP_SEVERITY). Cost: \$$COST"
notify_slack "$SLACK_MSG"
log_cron "$JOB" "ok" "issues=$ISSUE_COUNT cost=$COST"
