#!/usr/bin/env bash
# Keeps the Claude Code CLI binary itself current.
#
# `claude doctor` reports auto-updates as "enabled" on this machine, but the update check only
# fires on a normal interactive launch. This machine's `claude` is almost entirely invoked via
# one-shot `-p` calls from cron, which never trigger it -- the binary sat at 2.1.251 for a full
# month (last successful auto-update 2026-08-31) until caught and manually bumped to 2.1.286 on
# 2026-09-30. This job is the trigger auto-update was missing, not a replacement for it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="cli-update"
BEFORE="$(claude --version 2>/dev/null)"
OUTPUT="$(claude update 2>&1)"
AFTER="$(claude --version 2>/dev/null)"

if [[ "$BEFORE" == "$AFTER" ]]; then
  log_cron "$JOB" "ok" "already current: $AFTER"
else
  log_cron "$JOB" "ok" "updated: $BEFORE -> $AFTER"
  notify_slack "⬆️ Claude Code CLI updated: $BEFORE -> $AFTER"
fi
