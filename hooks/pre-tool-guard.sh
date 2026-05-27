#!/bin/bash
# PreToolUse guard — blocks only truly catastrophic, irreversible system operations.
# bypassPermissions mode handles all normal permission checks.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only block operations that are irreversible at a system/filesystem level
BLOCKED_PATTERNS=(
  "rm[[:space:]]+-rf[[:space:]]*/[[:space:]]*$"
  "rm[[:space:]]+-rf[[:space:]]+/usr"
  "rm[[:space:]]+-rf[[:space:]]+/etc"
  "rm[[:space:]]+-rf[[:space:]]+/System"
  ">[[:space:]]*/dev/sd"
  ">[[:space:]]*/dev/disk"
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    jq -n --arg reason "Blocked: $pattern targets a system path. Run manually if truly intended." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
done

exit 0
