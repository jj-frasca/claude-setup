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

echo "[$JOB] Starting — $TODAY"

if [[ ! -f "$USAGE_LOG" ]] && [[ ! -f "$MANIFEST" ]]; then
  echo "[$JOB] No usage log or manifest found. Skipping."
  notify_slack "🛠 Skills [$TODAY]: No usage data yet. Skipped."
  log_cron "$JOB" "skipped" "no data"
  exit 0
fi

PROMPT="You are analyzing Claude Code skill and tool usage to update the preferred skills reference file.

Today is $TODAY. Analyze the 30-day period ending today.

Data sources:
- Usage log (last 30 days of tool calls): $USAGE_LOG
- Skills manifest: $MANIFEST

Your task:
1. Read both files using the Read tool
2. From the usage log, count tool usage frequency by tool name and by file extension (from the 'file' field)
3. From the manifest, check which skills are 'active' vs 'inactive' and their last-used patterns
4. Identify skills going inactive (not used in 14+ days based on usage log)

Then write a new file at: $PREFERRED_SKILLS_FILE

The file MUST be ≤40 lines and follow this exact format:
\`\`\`
# Preferred Skills & Tool Patterns
_Auto-updated $(date +%Y-%m-%d) by skills-track.sh_

## Most-Used Tools (Last 30 Days)
- [Tool]: [count] uses
(list top 5 by frequency)

## Proactively Suggest
- [skill-name]: [one-line trigger description]
(list skills that should be suggested automatically based on usage patterns)

## Watch List (Inactive >14 Days)
- [skill-name]: last used [date or 'no recent usage']
(list skills at risk of retirement)

## Notes
[any notable patterns or recommendations, 1-3 bullet points max]
\`\`\`

If usage log is empty or too sparse, still create the file with 'No usage data yet' sections.
After writing the file, reply with a JSON summary:
{
  \"tools_analyzed\": N,
  \"skills_active\": N,
  \"skills_watch_list\": N,
  \"lines_written\": N
}

Return ONLY the JSON at the end."

RESPONSE=$(claude -p "$PROMPT" \
  --model claude-sonnet-4-6 \
  --allowedTools "Read,Write" \
  --output-format json \
  --no-session-persistence \
  --max-budget-usd 0.25 \
  2>&1)

if [[ $? -ne 0 ]]; then
  echo "[$JOB] ERROR: claude -p failed"
  notify_slack "❌ Skills [$TODAY] FAILED: claude -p error. See $REPORTS_DIR/cron-skills.log"
  log_cron "$JOB" "error" "claude -p failed"
  exit 1
fi

COST=$(echo "$RESPONSE" | jq -r '.total_cost_usd // "unknown"' 2>/dev/null || echo "unknown")
RESULT=$(echo "$RESPONSE" | jq -r '.result' 2>/dev/null | sed 's/^```json//; s/^```//; s/```$//' | sed '/^$/d')

ACTIVE=$(echo "$RESULT" | jq -r '.skills_active // "?"' 2>/dev/null || echo "?")
WATCH=$(echo "$RESULT" | jq -r '.skills_watch_list // "?"' 2>/dev/null || echo "?")

echo "[$JOB] Done. $ACTIVE active skill(s), $WATCH on watch list. Cost: \$$COST"
echo "[$JOB] Updated: $PREFERRED_SKILLS_FILE"

SLACK_MSG="🛠 Skills [$TODAY]: preferred_skills.md updated. $ACTIVE active, $WATCH on watch list. Cost: \$$COST"
notify_slack "$SLACK_MSG"
log_cron "$JOB" "ok" "active=$ACTIVE watchlist=$WATCH cost=$COST"
