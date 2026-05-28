#!/bin/bash
# PreCompact hook — reminds Claude to persist important context before compaction.
# Fires before manual or auto compaction. Injects additionalContext.
# Never blocks — exits 0 always.

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)

CONTEXT="[PRE-COMPACT REMINDER]
Before this conversation is compacted, check:
1. Any new user preferences, feedback, or corrections → save to memory (feedback type)
2. Any project decisions, deadlines, or constraints discovered → save to memory (project type)
3. Any recurring pain points worth tracking as a potential new skill
4. Any bugs found and fixed in cron/ or hooks/ scripts worth noting

Memory dir: ~/.claude/projects/-Users-joefrasca-claude-work/memory/
MEMORY.md index must also be updated when adding a new file.
Trigger: $TRIGGER"

jq -n --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: "PreCompact", additionalContext: $ctx}}'

exit 0
