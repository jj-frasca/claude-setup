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
# Skip cron / --no-session-persistence invocations that have no transcript
if [[ -z "$TRANSCRIPT" ]]; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TITLE=$(echo "$INPUT" | jq -r '.session_title // ""' 2>/dev/null)
# Fallback: read from persisted title file written by session-title.sh
if [[ -z "$TITLE" && -n "$SESSION" ]]; then
  TITLE_FILE="$HOME/.claude/_session_logs/titles/${SESSION}.txt"
  [[ -f "$TITLE_FILE" ]] && TITLE=$(cat "$TITLE_FILE" 2>/dev/null)
fi
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_DIR="$HOME/.claude/_session_logs"
mkdir -p "$LOG_DIR"

if [[ -n "$TITLE" ]]; then
  printf '{"ts":"%s","session":"%s","title":"%s","transcript":"%s"}\n' \
    "$TIMESTAMP" "$SESSION" "$(echo "$TITLE" | sed 's/"/\\"/g')" "$TRANSCRIPT" >> "$LOG_DIR/index.jsonl"
else
  printf '{"ts":"%s","session":"%s","transcript":"%s"}\n' \
    "$TIMESTAMP" "$SESSION" "$TRANSCRIPT" >> "$LOG_DIR/index.jsonl"
fi

# Clean up stale title files older than 7 days (best-effort)
find "$LOG_DIR/titles" -name "*.txt" -mtime +7 -delete 2>/dev/null &

exit 0
