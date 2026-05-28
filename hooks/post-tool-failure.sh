#!/bin/bash
# PostToolUseFailure logger — appends JSONL entry when any tool fails.
# async: true so it never blocks the session.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.command // ""' | head -c 120)
ERROR=$(echo "$INPUT" | jq -r '.tool_response.error // ""' | head -c 200)
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_FILE="$HOME/.claude/_session_logs/tool-failures.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"

printf '{"ts":"%s","session":"%s","tool":"%s","target":"%s","error":"%s"}\n' \
  "$TIMESTAMP" "$SESSION" "$TOOL" \
  "$(echo "$FILE" | sed 's/"/\\"/g')" \
  "$(echo "$ERROR" | sed 's/"/\\"/g')" >> "$LOG_FILE"

exit 0
