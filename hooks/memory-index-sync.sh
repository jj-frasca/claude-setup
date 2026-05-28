#!/bin/bash
# PostToolUse hook — when a memory .md file is written, ensure MEMORY.md index
# has an entry for it. Prevents "file exists but not in index" drift.
# async: true. Never blocks.

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // ""' 2>/dev/null)

# Only care about memory directory .md files (not MEMORY.md itself)
MEMORY_DIR="$HOME/.claude/projects"
case "$FILE" in
  */memory/*.md) : ;;
  *) exit 0 ;;
esac
case "$FILE" in
  */MEMORY.md) exit 0 ;;
esac

# Extract the name slug from frontmatter
NAME=$(grep -m1 '^name:' "$FILE" 2>/dev/null | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'")
if [[ -z "$NAME" ]]; then exit 0; fi

# Find the sibling MEMORY.md
MEMORY_MD="$(dirname "$FILE")/MEMORY.md"
if [[ ! -f "$MEMORY_MD" ]]; then exit 0; fi

# Check if this file is already indexed (by filename)
BASENAME=$(basename "$FILE")
if grep -q "$BASENAME" "$MEMORY_MD" 2>/dev/null; then
  exit 0
fi

# Extract description from frontmatter for the index line
DESC=$(grep -m1 '^description:' "$FILE" 2>/dev/null | sed 's/^description:[[:space:]]*//' | tr -d '"' | head -c 120)
if [[ -z "$DESC" ]]; then
  DESC="$NAME"
fi

# Convert slug to Title Case for display: "my-slug-name" → "My Slug Name"
DISPLAY=$(echo "$NAME" | sed 's/-/ /g' | python3 -c "import sys; print(sys.stdin.read().strip().title())" 2>/dev/null || echo "$NAME")

# Append to MEMORY.md
printf -- '- [%s](%s) — %s\n' "$DISPLAY" "$BASENAME" "$DESC" >> "$MEMORY_MD"

exit 0
