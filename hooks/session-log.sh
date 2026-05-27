#!/bin/bash
# Stop hook — writes session metadata to _session_logs/index.jsonl.
# Reads transcript_path for manual review in a future session.
# Never invokes `claude -p` — that would risk an infinite loop.
# async: true so it never blocks session end.

INPUT=$(cat)

# Guard against infinite loops. Field may not exist in all versions;
# defaults to "false" if absent, which is safe — the check becomes a no-op.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_DIR="$HOME/.claude/_session_logs"
mkdir -p "$LOG_DIR"

printf '{"ts":"%s","session":"%s","transcript":"%s"}\n' \
  "$TIMESTAMP" "$SESSION" "$TRANSCRIPT" >> "$LOG_DIR/index.jsonl"

exit 0
