#!/bin/bash
# UserPromptSubmit hook — sets a session title from the first user prompt.
# Fires on every prompt; only sets title when not already set.

INPUT=$(cat)

EXISTING_TITLE=$(echo "$INPUT" | jq -r '.session_title // ""' 2>/dev/null)
if [[ -n "$EXISTING_TITLE" ]]; then exit 0; fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
if [[ -z "$PROMPT" ]]; then exit 0; fi

# Collapse whitespace, truncate to 72 chars (ERE for macOS BSD sed)
TITLE=$(echo "$PROMPT" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed 's/[[:space:]]*$//')
TITLE="${TITLE:0:72}"
TITLE="${TITLE%"${TITLE##*[![:space:]]}"}"  # trim trailing space after truncation
# Capitalize first character
first=$(echo "${TITLE:0:1}" | tr '[:lower:]' '[:upper:]')
TITLE="${first}${TITLE:1}"

# Use jq for correct JSON encoding (handles quotes, backslashes, control chars)
jq -n --arg title "$TITLE" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $title}}'

exit 0
