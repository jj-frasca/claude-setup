#!/bin/bash
# PostCompact hook — fires after conversation compaction.
# Logs the event and reminds Claude to verify memory was saved.

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | head -c 8)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPORTS_DIR="$HOME/.claude/_reports"
mkdir -p "$REPORTS_DIR"
printf '{"ts":"%s","job":"compact","status":"ok","detail":"trigger=%s session=%s"}\n' \
  "$TIMESTAMP" "$TRIGGER" "$SESSION" >> "$REPORTS_DIR/cron.log"

printf '{"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"Compaction complete (%s). If any user preferences, feedback, or project decisions were in the compacted context that were NOT saved to memory files, save them now before continuing."}}\n' \
  "$TRIGGER"

exit 0
