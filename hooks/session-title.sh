#!/bin/bash
# UserPromptSubmit hook — sets a session title from the first user prompt.
# Fires on every prompt; only sets title when not already set.

INPUT=$(cat)

# Only set title once per session
EXISTING_TITLE=$(echo "$INPUT" | jq -r '.session_title // ""' 2>/dev/null)
if [[ -n "$EXISTING_TITLE" ]]; then exit 0; fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
if [[ -z "$PROMPT" ]]; then exit 0; fi

# First 72 chars, collapse whitespace, trim trailing space
TITLE=$(echo "$PROMPT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | head -c 72 | sed 's/[[:space:]]*$//')
# Capitalize first char
TITLE="$(echo "${TITLE:0:1}" | tr '[:lower:]' '[:upper:]')${TITLE:1}"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"%s"}}\n' \
  "$(echo "$TITLE" | sed 's/"/\\"/g')"

exit 0
