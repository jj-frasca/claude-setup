#!/usr/bin/env bash
# Self-Heal: runs daily at 5 PM via launchd.
# Pass 1: analyzes today's sessions → ranked fix queue JSON
# Pass 2: applies safe fixes autonomously, flags the rest to Slack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="self-heal"
SESSION_INDEX="$HOME/.claude/_session_logs/index.jsonl"
REPORT_FILE="$REPORTS_DIR/$TODAY-selfheal.json"
REMEDIATION_FILE="$REPORTS_DIR/$TODAY-selfheal-remediation.json"
TOTAL_COST=0

# ── lock guard ───────────────────────────────────────────────────────────────
[ -f /tmp/self-heal.lock ] && { echo "[$JOB] Already running — exiting."; exit 0; }
touch /tmp/self-heal.lock
trap 'rm -f /tmp/self-heal.lock' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

add_cost() {
  local new_cost="$1"
  TOTAL_COST=$(echo "$TOTAL_COST + $new_cost" | bc 2>/dev/null || echo "$TOTAL_COST")
}

# ── guard: no sessions ────────────────────────────────────────────────────────

START_SECONDS=$SECONDS
echo "[$JOB] Starting — $TODAY"

if [[ ! -f "$SESSION_INDEX" ]]; then
  notify_slack "🔧 Self-Heal [$TODAY]: No sessions recorded. Skipped."
  log_cron "$JOB" "skipped" "no session index"
  exit 0
fi

TRANSCRIPT_PATHS=$(grep "\"ts\":\"${TODAY}" "$SESSION_INDEX" 2>/dev/null \
  | jq -r '.transcript // empty' 2>/dev/null \
  | grep -v '^$' \
  | sort -u \
  | while read -r p; do [ -f "$p" ] && echo "$p"; done || true)

SESSION_COUNT=$(echo "$TRANSCRIPT_PATHS" | grep -c '.' 2>/dev/null || echo 0)

if [[ "$SESSION_COUNT" -eq 0 ]]; then
  notify_slack "🔧 Self-Heal [$TODAY]: No sessions today. Skipped."
  log_cron "$JOB" "skipped" "no sessions today"
  exit 0
fi

# ── pre-extract today's messages from each transcript ─────────────────────────
# Sessions can span multiple days. Grep for today's timestamp prefix (UTC) so
# Claude only sees messages that happened today, regardless of transcript size.
# TODAY is local date; at run time (5PM PDT = midnight UTC) local and UTC dates match.
TODAY_UTC="$TODAY"
TODAY_UTC_NEXT=$(date -u -v+1d +"%Y-%m-%d" 2>/dev/null || date -u -d "tomorrow" +"%Y-%m-%d" 2>/dev/null || echo "")

SESSION_EXTRACTS=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  sid=$(basename "$p" .jsonl | head -c 8)
  # Grep lines with today's UTC date in the timestamp field
  # Use both today and tomorrow UTC to cover sessions around midnight
  today_lines=$(grep -E "\"timestamp\":\"(${TODAY_UTC}|${TODAY_UTC_NEXT})" "$p" 2>/dev/null | tail -500)
  msg_count=$(echo "$today_lines" | grep -c '"type":"user"\|"type":"assistant"' 2>/dev/null || echo 0)
  formatted=$(echo "$today_lines" | python3 -c "
import sys, json
COMPACTION_PREFIX = 'This session is being continued from a previous conversation'
for line in sys.stdin:
    try:
        d = json.loads(line)
        t = d.get('type','')
        if t not in ('user','assistant'):
            continue
        msg = d.get('message', {})
        role = msg.get('role', t)
        c = msg.get('content','')
        # Extract only text blocks, skip tool_use/tool_result blocks
        if isinstance(c, list):
            text = ' '.join(
                x.get('text','') for x in c
                if isinstance(x, dict) and x.get('type') == 'text'
            )
        else:
            text = str(c)
        # Skip compaction summary injections (not real user messages)
        if text.startswith(COMPACTION_PREFIX):
            continue
        ts = d.get('timestamp','')[:16]
        print(f'[{ts}][{role}] {text[:200]}')
    except:
        pass
" 2>/dev/null | head -150)
  SESSION_EXTRACTS="${SESSION_EXTRACTS}
=== Session ${sid}: ${msg_count} message(s) today ===
${formatted:-(no messages matching today)}"
done <<< "$TRANSCRIPT_PATHS"

# Build session titles map
SESSION_TITLES=$(grep "\"ts\":\"${TODAY}" "$SESSION_INDEX" 2>/dev/null \
  | jq -r 'select(.title != null and .title != "") | "\(.session[0:8]): \(.title)"' 2>/dev/null \
  | head -10 | tr '\n' '|' || echo "")

TOOL_FAILURES_LOG="$HOME/.claude/_session_logs/tool-failures.jsonl"
RECENT_TOOL_FAILURES=""
if [[ -f "$TOOL_FAILURES_LOG" ]]; then
  RECENT_TOOL_FAILURES=$(tail -20 "$TOOL_FAILURES_LOG" | jq -r '"\(.ts[0:16]) \(.tool)|\(.target[0:60])|\(.error[0:80])"' 2>/dev/null | tr '\n' '§' || echo "")
fi
GIT_LOG_24H=$(cd "$CLAUDE_WORK" && git log --oneline --since="24 hours ago" 2>/dev/null | head -10 || echo "(none)")
LAST_CRON=$(tail -5 "$REPORTS_DIR/cron.log" 2>/dev/null | jq -r '"\(.ts[0:16]) \(.job): \(.status) (\(.detail))"' 2>/dev/null | tr '\n' '|' || echo "(none)")

# ── pass 1: analysis ──────────────────────────────────────────────────────────

echo "[$JOB] Pass 1: analyzing $SESSION_COUNT session(s)..."

ANALYSIS_PROMPT="You are analyzing Claude Code session transcripts to identify improvement opportunities.

Today is $TODAY. Session count: $SESSION_COUNT.
Session titles: ${SESSION_TITLES:-(none captured yet)}
Recent commits (24h): $GIT_LOG_24H
Recent cron runs: $LAST_CRON
Recent tool failures (PostToolUseFailure hook): ${RECENT_TOOL_FAILURES:-(none)}

Today's messages from each session (pre-filtered by timestamp):
$SESSION_EXTRACTS

Scan for:
1. Tool errors — any tool that returned an error, especially if retried
2. User corrections — messages like 'no', 'stop', 'wrong', 'not that', 'revert', 'undo'
3. [DEGRADED] flags — text matching '[DEGRADED]' in assistant messages
4. Incomplete tasks — conversation ends without resolution
5. User preferences or feedback worth saving as a memory entry
6. Cron/hook script bugs if the cron run data shows failures

Return ONLY valid JSON:
{
  \"generated_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
  \"session_count\": $SESSION_COUNT,
  \"fixes\": [
    {
      \"type\": \"tool_error|user_correction|retry_storm|degraded_skill|incomplete_task\",
      \"description\": \"brief description\",
      \"severity\": 1,
      \"suggested_fix\": \"concrete actionable fix\",
      \"auto_applicable\": false,
      \"session_id\": \"8-char session id if identifiable\"
    }
  ]
}

auto_applicable=true ONLY for: memory file updates, cron/hook script bug fixes, .gitignore additions.
auto_applicable=false for: CLAUDE.md, settings.json, launchd plists, architectural decisions.
Severity: 5=critical, 4=significant, 3=notable, 2=minor, 1=informational.
Sort by severity descending. Return ONLY the JSON."

ANALYSIS_RESPONSE=$(run_claude "$REPORTS_DIR/cron-selfheal-err.log" \
  "$ANALYSIS_PROMPT" \
  --model claude-sonnet-4-6 \
  --allowedTools "Bash" \
  --output-format json \
  --no-session-persistence \
  --max-turns 3 \
  --max-budget-usd 0.30 \
  --debug-file "$REPORTS_DIR/cron-selfheal-debug.log") || {
    local_err=$(cat "$REPORTS_DIR/cron-selfheal-err.log" 2>/dev/null | head -5 | tr '\n' '|')
    notify_slack "❌ Self-Heal [$TODAY] FAILED (Pass 1): claude -p error. $local_err"
    log_cron "$JOB" "error" "pass1 failed"
    exit 1
  }

add_cost "$(echo "$ANALYSIS_RESPONSE" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
RAW=$(echo "$ANALYSIS_RESPONSE" | jq -r '.result // ""' 2>/dev/null)
RESULT=$(extract_json "$RAW") || {
  echo "$RAW" > "$REPORTS_DIR/$TODAY-selfheal-raw.txt"
  RESULT="{\"generated_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"session_count\":$SESSION_COUNT,\"fixes\":[],\"error\":\"non-JSON result\"}"
}

echo "$RESULT" > "$REPORT_FILE"
ISSUE_COUNT=$(echo "$RESULT" | jq '.fixes | length' 2>/dev/null || echo 0)
AUTO_COUNT=$(echo "$RESULT" | jq '[.fixes[] | select(.auto_applicable == true)] | length' 2>/dev/null || echo 0)
echo "[$JOB] Pass 1 done: $ISSUE_COUNT issue(s), $AUTO_COUNT auto-applicable."

# ── pass 2: remediation ───────────────────────────────────────────────────────

APPLIED_LINES="(none)"
FLAGGED_LINES="(none)"
REMEDIATION_COST=0

if [[ "$AUTO_COUNT" -gt 0 ]]; then
  echo "[$JOB] Pass 2: applying $AUTO_COUNT fix(es)..."

  FIX_QUEUE=$(echo "$RESULT" | jq '[.fixes[] | select(.auto_applicable == true)]')

  REMEDIATION_PROMPT="You are the self-healing agent for Joe Frasca's Claude Code setup at ~/claude-work/.claude/.

You have a list of issues found in today's Claude sessions. Apply every fix in the list.

ABSOLUTE RULES — violating these is not allowed:
- NEVER edit CLAUDE.md or settings.json or any launchd plist
- NEVER delete files, branches, or git history
- NEVER make a fix you are not confident about — skip it and mark it flagged
- After making changes, commit with: cd ~/claude-work/.claude && git add cron/ hooks/ rules/ skills/ .gitignore && git diff --cached --quiet || (git commit -m 'self-heal: auto-apply fixes $TODAY' && git push origin master)
- NEVER use git add -A or git add . — only stage the specific directories listed above
- When writing memory files, follow the existing format in ~/.claude/projects/-Users-joefrasca-claude-work/memory/ exactly

AUTO-APPLY these types:
- Memory entries: write a new .md file in ~/.claude/projects/-Users-joefrasca-claude-work/memory/ and add a line to MEMORY.md
- Cron/hook script bugs: edit the file in ~/claude-work/.claude/cron/ or hooks/
- .gitignore additions: edit ~/claude-work/.claude/.gitignore

Fix queue (apply all of these):
$FIX_QUEUE

After applying all fixes and committing, return ONLY this JSON:
{
  \"applied\": [
    {\"description\": \"what you did\", \"file\": \"path/to/file\"}
  ],
  \"skipped\": [
    {\"description\": \"what you skipped and why\"}
  ],
  \"committed\": true
}"

  REMEDIATION_RESPONSE=$(run_claude "$REPORTS_DIR/cron-selfheal-remediation-err.log" \
    "$REMEDIATION_PROMPT" \
    --model claude-sonnet-4-6 \
    --allowedTools "Read,Write,Edit,Bash" \
    --output-format json \
    --no-session-persistence \
    --max-turns 30 \
    --max-budget-usd 1.50 \
    --debug-file "$REPORTS_DIR/cron-selfheal-remediation-debug.log") || {
      local_err2=$(cat "$REPORTS_DIR/cron-selfheal-remediation-err.log" 2>/dev/null | head -3 | tr '\n' '|')
      echo "[$JOB] WARNING: Pass 2 claude -p failed — skipping remediation. $local_err2"
      APPLIED_LINES="  ⚠️ Remediation failed — claude -p error in Pass 2"
    }

  REMEDIATION_COST=$(echo "$REMEDIATION_RESPONSE" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)
  add_cost "$REMEDIATION_COST"

  RAW_REM=$(echo "$REMEDIATION_RESPONSE" | jq -r '.result // ""' 2>/dev/null)
  REM_RESULT=$(extract_json "$RAW_REM") || true

  if [[ -n "$REM_RESULT" ]]; then
    echo "$REM_RESULT" > "$REMEDIATION_FILE"
    APPLIED_COUNT=$(echo "$REM_RESULT" | jq '.applied | length' 2>/dev/null || echo 0)
    SKIPPED_COUNT=$(echo "$REM_RESULT" | jq '.skipped | length' 2>/dev/null || echo 0)

    APPLIED_LINES=$(echo "$REM_RESULT" | jq -r '
      .applied[]? |
      "  ✅ " + .description
    ' 2>/dev/null || echo "  (none)")

    FLAGGED_LINES=$(echo "$REM_RESULT" | jq -r '
      .skipped[]? |
      "  ⚠️ " + .description
    ' 2>/dev/null || echo "  (none)")

    echo "[$JOB] Pass 2 done: $APPLIED_COUNT applied, $SKIPPED_COUNT skipped."
  else
    echo "$RAW_REM" > "$REPORTS_DIR/$TODAY-remediation-raw.txt"
    APPLIED_LINES="  ⚠️ Remediation returned non-JSON (see $TODAY-remediation-raw.txt)"
  fi
fi

# also flag non-auto issues for Slack
FLAGGED_ISSUES=$(echo "$RESULT" | jq -r '
  .fixes[] | select(.auto_applicable != true) |
  (if .severity >= 4 then "🔴" elif .severity == 3 then "🟡" else "🔵" end) as $icon |
  (.type | gsub("_"; " ") | ascii_upcase) as $label |
  (.description | if length > 130 then .[0:130] + "…" else . end) as $desc |
  "  \($icon) \($label): \($desc)"
' 2>/dev/null || echo "")

if [[ -n "$FLAGGED_ISSUES" ]]; then
  FLAGGED_LINES="$FLAGGED_ISSUES"
fi

# ── notify ────────────────────────────────────────────────────────────────────

FINISH_TIME=$(date "+%-I:%M %p")
ELAPSED=$(( SECONDS - START_SECONDS ))
COST_FMT=$(printf "%.3f" "$TOTAL_COST" 2>/dev/null || echo "$TOTAL_COST")

SLACK_MSG="🔧 *Self-Heal — $TODAY*
$SESSION_COUNT session(s) · $ISSUE_COUNT issue(s) found · \$$COST_FMT · ${ELAPSED}s · $FINISH_TIME

*Auto-applied:*
$APPLIED_LINES

*Needs your attention:*
$FLAGGED_LINES"

notify_slack "$SLACK_MSG"
log_cron "$JOB" "ok" "issues=$ISSUE_COUNT auto=$AUTO_COUNT applied=${APPLIED_COUNT:-0} cost=$COST_FMT"
echo "[$JOB] Complete."
