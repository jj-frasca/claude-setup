#!/bin/bash
# PostToolUse logger — appends a JSONL entry for every Write/Edit/MultiEdit.
# async: true so it never blocks the session.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_FILE="$HOME/.claude/skills/_usage_log.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"

printf '{"ts":"%s","session":"%s","tool":"%s","file":"%s"}\n' \
  "$TIMESTAMP" "$SESSION" "$TOOL" "$FILE" >> "$LOG_FILE"

exit 0
