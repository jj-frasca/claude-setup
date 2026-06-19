#!/bin/bash
# PostToolUseFailure logger — appends JSONL entry when any tool fails.
# async: true so it never blocks the session.

INPUT=$(cat)
if [[ -z "$INPUT" ]]; then exit 0; fi
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
if [[ -z "$TOOL" || "$TOOL" == "null" ]]; then exit 0; fi
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.command // ""' | head -c 120)
# Failure payload shape varies across versions/tools — try the common fields,
# then fall back to the raw tool_response so failures are never silently dropped
# (the previous hardcoded .tool_response.error path matched nothing and the log
# went stale, which also starved self-heal's tool-failure signal).
ERROR=$(echo "$INPUT" | jq -r '
  (.tool_response.error // .tool_response.errorMessage // .tool_response.content // .error // .message // null)
  | if . == null then "" elif type=="array" then (map(.text? // tostring) | join(" ")) elif type=="object" then tojson else tostring end
' 2>/dev/null | head -c 200)
if [[ -z "$ERROR" || "$ERROR" == "null" ]]; then
  ERROR=$(echo "$INPUT" | jq -c '.tool_response // empty' 2>/dev/null | head -c 200)
fi
[[ -z "$ERROR" ]] && ERROR="(failure with no error detail in payload)"
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_FILE="$HOME/.claude/_session_logs/tool-failures.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"

printf '{"ts":"%s","session":"%s","tool":"%s","target":"%s","error":"%s"}\n' \
  "$TIMESTAMP" "$SESSION" "$TOOL" \
  "$(echo "$FILE" | sed 's/"/\\"/g')" \
  "$(echo "$ERROR" | sed 's/"/\\"/g')" >> "$LOG_FILE"

exit 0
