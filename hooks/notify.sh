#!/bin/bash
# Notification hook — sends a terminal bell + OSC notification when Claude pauses.
# Requires Claude Code v2.1.141+. We are on v2.1.152.
# async: true so it never blocks the session.

INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude needs input"')

SEQ=$(printf '\033]777;notify;Claude Code;%s\007' "$MESSAGE")
jq -nc --arg seq "$SEQ" '{terminalSequence: $seq}'
exit 0
