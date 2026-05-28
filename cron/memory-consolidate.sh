#!/usr/bin/env bash
# Memory Consolidation: runs daily at 10 PM via launchd.
# Deduplicates and reindexes Claude auto-memory files across all projects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="memory-consolidate"
MEMORY_BACKUP_DIR="$REPORTS_DIR/memory-backup-$TODAY"

START_SECONDS=$SECONDS
echo "[$JOB] Starting — $TODAY"

MEMORY_FILES=$(find "$HOME/.claude/projects" -path "*/memory/*.md" 2>/dev/null | sort)
FILE_COUNT=$(echo "$MEMORY_FILES" | grep -c '.' 2>/dev/null || echo 0)

if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "[$JOB] No memory files found. Skipping."
  notify_slack "🧠 Memory [$TODAY]: No memory files found. Skipped."
  log_cron "$JOB" "skipped" "no memory files"
  exit 0
fi

echo "[$JOB] Found $FILE_COUNT memory file(s). Backing up..."
mkdir -p "$MEMORY_BACKUP_DIR"
find "$HOME/.claude/projects" -path "*/memory/*.md" | while IFS= read -r f; do
  dest="$MEMORY_BACKUP_DIR/${f#/}"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done
echo "[$JOB] Backup created: $MEMORY_BACKUP_DIR"

MEMORY_PATH_LIST=$(echo "$MEMORY_FILES" | paste -sd ',' -)

PROMPT="You are maintaining Claude Code auto-memory files to keep them deduplicated and consistent.

Today is $TODAY. The memory files are at these paths: $MEMORY_PATH_LIST

Your task:
1. Read each memory file using the Read tool
2. Within each project's memory directory, identify:
   - DUPLICATE entries: same fact stated in multiple files with the same meaning
   - CONTRADICTORY entries: conflicting facts (e.g., two files say different things about the same topic)
   - STALE entries: facts that are clearly no longer true (look for explicit time references > 90 days ago)
3. For duplicates: merge into the most complete version, remove the redundant one
4. For contradictions: keep the more recent/specific one, remove the outdated one
5. After modifying any memory files, rewrite the corresponding MEMORY.md index file to list current files accurately
6. Be CONSERVATIVE: when uncertain, leave the file as-is. Only merge if the meaning is clearly identical.

RULES:
- Never delete a file if it contains unique information not present elsewhere
- Never modify MEMORY.md files in ~/.claude/projects/ unless you are also modifying the memory files they index
- Never add new facts — only consolidate existing ones
- If a project has no duplicates or issues, leave it untouched

After completing all changes, reply with a JSON summary:
{
  \"projects_scanned\": N,
  \"files_scanned\": N,
  \"merges\": N,
  \"contradictions_resolved\": N,
  \"unchanged\": N
}

Return ONLY the JSON summary at the end, nothing else."

RESPONSE=$(run_claude "$REPORTS_DIR/cron-memory-err.log" \
  "$PROMPT" \
  --model claude-sonnet-4-6 \
  --allowedTools "Read,Write,Edit,Bash" \
  --output-format json \
  --no-session-persistence \
  --max-turns 25 \
  --max-budget-usd 1.00 \
  --debug-file "$REPORTS_DIR/cron-memory-debug.log") || {
    local_err=$(cat "$REPORTS_DIR/cron-memory-err.log" 2>/dev/null | head -5 | tr '\n' '|')
    echo "[$JOB] ERROR: claude -p failed. Backup preserved at $MEMORY_BACKUP_DIR"
    notify_slack "❌ Memory [$TODAY] FAILED: claude -p error. $local_err Backup at $MEMORY_BACKUP_DIR."
    log_cron "$JOB" "error" "claude -p failed"
    exit 1
  }

RAW_COST=$(echo "$RESPONSE" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)
COST=$(printf "%.3f" "$RAW_COST" 2>/dev/null || echo "$RAW_COST")
RAW_RESULT=$(echo "$RESPONSE" | jq -r '.result // ""' 2>/dev/null)
RESULT=$(extract_json "$RAW_RESULT") || {
  echo "$RAW_RESULT" > "$REPORTS_DIR/$TODAY-memory-raw.txt"
  RESULT="{}"
}

MERGES=$(echo "$RESULT" | jq -r '.merges // "?"' 2>/dev/null || echo "?")
FILES=$(echo "$RESULT" | jq -r '.files_scanned // "?"' 2>/dev/null || echo "?")

ELAPSED=$(( SECONDS - START_SECONDS ))
echo "[$JOB] Done. $FILES file(s) scanned, $MERGES merge(s). Cost: \$$COST (${ELAPSED}s)"

SLACK_MSG="🧠 Memory [$TODAY]: $FILES file(s) scanned, $MERGES merge(s). Cost: \$$COST · ${ELAPSED}s"
notify_slack "$SLACK_MSG"
log_cron "$JOB" "ok" "files=$FILES merges=$MERGES cost=$COST"
