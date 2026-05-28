#!/bin/bash
# PostCompact hook — fires after conversation compaction.
# Logs the event and reminds Claude to verify memory was saved.
# Also injects the most recent self-heal findings if any.

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | head -c 8)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPORTS_DIR="$HOME/.claude/_reports"
mkdir -p "$REPORTS_DIR"
printf '{"ts":"%s","job":"compact","status":"ok","detail":"trigger=%s session=%s"}\n' \
  "$TIMESTAMP" "$TRIGGER" "$SESSION" >> "$REPORTS_DIR/cron.log"

CONTEXT="Compaction complete ($TRIGGER). Before continuing:
1. If user preferences, feedback, or project decisions were in the compacted context but NOT yet saved to memory files, save them now.
2. Memory dir: ~/.claude/projects/-Users-joefrasca-claude-work/memory/ — update MEMORY.md when adding files."

# Append latest self-heal findings if any exist
LATEST_REPORT=$(ls "$REPORTS_DIR"/*-selfheal.json 2>/dev/null | sort | tail -1)
if [[ -n "$LATEST_REPORT" ]]; then
  ISSUE_COUNT=$(jq '.fixes | length' "$LATEST_REPORT" 2>/dev/null || echo 0)
  if [[ "$ISSUE_COUNT" -gt 0 ]]; then
    REPORT_DATE=$(basename "$LATEST_REPORT" | sed 's/-selfheal.json//')
    TOP_ISSUES=$(jq -r '.fixes[:3][] | "  • [sev \(.severity)] \(.description[0:80])"' "$LATEST_REPORT" 2>/dev/null)
    CONTEXT="$CONTEXT

Latest self-heal ($REPORT_DATE): $ISSUE_COUNT issue(s) found.
$TOP_ISSUES"
  fi
fi

# Use jq --arg for correct JSON encoding of any special characters
jq -n --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: "PostCompact", additionalContext: $ctx}}'

exit 0
