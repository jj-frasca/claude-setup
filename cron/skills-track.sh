#!/usr/bin/env bash
# Skills Tracker: runs daily at 10:30 PM via launchd.
# Analyzes tool/skill usage and updates rules/preferred_skills.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="skills-track"
USAGE_LOG="$HOME/.claude/skills/_usage_log.jsonl"
MANIFEST="$CLAUDE_WORK/skills/_manifest.json"
PREFERRED_SKILLS_FILE="$CLAUDE_WORK/rules/preferred_skills.md"
CUTOFF=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d" 2>/dev/null || echo "")
# CUTOFF used in prompt as the 30-day lookback boundary

START_SECONDS=$SECONDS
echo "[$JOB] Starting — $TODAY"

if [[ ! -f "$USAGE_LOG" ]] && [[ ! -f "$MANIFEST" ]]; then
  echo "[$JOB] No usage log or manifest found. Skipping."
  notify_slack "🛠 Skills [$TODAY]: No usage data yet. Skipped."
  log_cron "$JOB" "skipped" "no data"
  exit 0
fi

PROMPT="You are analyzing Claude Code skill and tool usage to update the preferred skills reference file.

Today is $TODAY. Analyze the 30-day period from $CUTOFF to today.

Data sources:
- Usage log (last 30 days of tool calls): $USAGE_LOG
- Skills manifest: $MANIFEST

Your task:
1. Read both files using the Read tool
2. From the usage log, count tool usage frequency by tool name and by file extension (from the 'file' field)
3. From the manifest, check which skills are 'active' vs 'inactive' and their last-used patterns
4. Identify skills going inactive (not used in 14+ days based on usage log)

Then write a new file at: $PREFERRED_SKILLS_FILE

Then write a new file at: $PREFERRED_SKILLS_FILE

The file MUST be ≤45 lines and follow this EXACT format (replace [] placeholders with real data):
# Preferred Skills & Tool Patterns
_Auto-updated $(date +%Y-%m-%d) by skills-track.sh_

## Most-Used Tools (Last 30 Days)
- Write: N uses
- Edit: N uses
(top 5 tools by count; use 'No data yet' if log is empty)

## Top File Types Touched
- .ext: N edits
(top 5 extensions by count; derived from 'file' field in usage log)

## Proactively Suggest
- skill-builder: user describes a recurring pain point → propose a new skill
- skill-auditor: after 10+ new log entries or weekly → audit manifest and usage
(add any other skills whose patterns in usage log suggest they'd be useful)

## Watch List (Inactive >14 Days)
No skills inactive — [reason]
(or list: - skill-name: last used [date])

## Notes
- [1-3 concise observations about patterns, total log size, etc.]

If the usage log doesn't exist or is empty, write 'No usage data yet' in each section.
After writing the file, output ONLY this JSON (no other text):
{
  \"tools_analyzed\": N,
  \"skills_active\": N,
  \"skills_watch_list\": N,
  \"lines_written\": N,
  \"top_tool\": \"ToolName\",
  \"top_extension\": \".ext\"
}"

RESPONSE=$(run_claude "$REPORTS_DIR/cron-skills-err.log" \
  "$PROMPT" \
  --model claude-sonnet-4-6 \
  --allowedTools "Read,Write" \
  --output-format json \
  --no-session-persistence \
  --max-turns 10 \
  --max-budget-usd 0.25 \
  --debug-file "$REPORTS_DIR/cron-skills-debug.log") || {
    local_err=$(cat "$REPORTS_DIR/cron-skills-err.log" 2>/dev/null | head -5 | tr '\n' '|')
    echo "[$JOB] ERROR: claude -p failed. $local_err"
    notify_slack "❌ Skills [$TODAY] FAILED: claude -p error. $local_err"
    log_cron "$JOB" "error" "claude -p failed"
    exit 1
  }

COST=$(echo "$RESPONSE" | jq -r '.total_cost_usd // "unknown"' 2>/dev/null || echo "unknown")
RAW_RESULT=$(echo "$RESPONSE" | jq -r '.result // ""' 2>/dev/null)
RESULT=$(extract_json "$RAW_RESULT") || {
  echo "$RAW_RESULT" > "$REPORTS_DIR/$TODAY-skills-raw.txt"
  RESULT="{}"
}

ACTIVE=$(echo "$RESULT" | jq -r '.skills_active // "?"' 2>/dev/null || echo "?")
WATCH=$(echo "$RESULT" | jq -r '.skills_watch_list // "?"' 2>/dev/null || echo "?")
TOP_TOOL=$(echo "$RESULT" | jq -r '.top_tool // "?"' 2>/dev/null || echo "?")
TOP_EXT=$(echo "$RESULT" | jq -r '.top_extension // "?"' 2>/dev/null || echo "?")

ELAPSED=$(( SECONDS - START_SECONDS ))
echo "[$JOB] Done. $ACTIVE active, $WATCH watch. Top: $TOP_TOOL/$TOP_EXT. Cost: \$$COST (${ELAPSED}s)"
echo "[$JOB] Updated: $PREFERRED_SKILLS_FILE"

SLACK_MSG="🛠 Skills [$TODAY]: preferred_skills.md updated. $ACTIVE active, $WATCH watch. Top: $TOP_TOOL ($TOP_EXT). Cost: \$$COST · ${ELAPSED}s"
notify_slack "$SLACK_MSG"
log_cron "$JOB" "ok" "active=$ACTIVE watchlist=$WATCH top=$TOP_TOOL cost=$COST"
