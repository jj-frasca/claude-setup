#!/usr/bin/env bash
# QuantForge autonomous session driver.
#
# Joe delegated QuantForge to unattended AI operation (2026-08-17): he can't reliably
# start sessions himself, so launchd fires this every 5h — aligned to the subscription's
# 5-hour session window — and each run works until the limit cuts it off.
#
# The session's actual instructions live in the repo, NOT here:
#   ~/claude-work/quantforge/.claude/AUTONOMY_CHARTER.md
# Edit that to change behavior. This script only handles scheduling, budget and logging.
#
# Tunables: ~/.claude/.qf-autonomous.env
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="qf-autonomous"
REPO="$HOME/claude-work/quantforge"
CHARTER="$REPO/.claude/AUTONOMY_CHARTER.md"
LEDGER="$REPORTS_DIR/qf-autonomous-ledger.jsonl"
LOCK="/tmp/qf-autonomous.lock"
RUN_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_LOG="$REPORTS_DIR/qf-autonomous-$(date +%Y%m%d-%H%M).log"

# ── tunables ─────────────────────────────────────────────────────────────────
# Precedence: shell env > ~/.claude/.qf-autonomous.env > defaults below.
# Joe's instruction is to USE THE WHOLE BUDGET — these caps exist only to stop the
# week's quota being burned Mon/Tue leaving Wed-Sun dead, not to hold usage back.
# The in-session retro pass (charter §6) is expected to RAISE these if quota goes unused.
[[ -f "$HOME/.claude/.qf-autonomous.env" ]] && source "$HOME/.claude/.qf-autonomous.env"

QF_WEEKLY_RUN_BUDGET="${QF_WEEKLY_RUN_BUDGET:-21}"   # sessions per ISO week (35 slots exist)
QF_DAILY_RUN_CAP="${QF_DAILY_RUN_CAP:-3}"            # sessions per calendar day (5 slots exist)
QF_MAX_SECONDS="${QF_MAX_SECONDS:-17400}"            # 4h50m — dead before the next slot fires
QF_MODEL="${QF_MODEL:-opus}"                         # most agentic work available
QF_FALLBACK_MODEL="${QF_FALLBACK_MODEL:-sonnet}"     # keep working after the opus limit
QF_ENABLED="${QF_ENABLED:-1}"
QF_DRY_RUN="${QF_DRY_RUN:-0}"                        # 1 = run guards, print prompt, skip claude

ledger() {  # ledger <status> <detail> [duration_s] [exit_code]
  printf '{"ts":"%s","date":"%s","week":"%s","status":"%s","detail":"%s","duration_s":%s,"exit":%s}\n' \
    "$RUN_TS" "$(date +%F)" "$(date +%G-W%V)" "$1" "$2" "${3:-0}" "${4:-0}" >> "$LEDGER"
}

finish() {  # finish <status> <detail> <slack-msg> [duration] [exit]
  ledger "$1" "$2" "${4:-0}" "${5:-0}"
  log_cron "$JOB" "$1" "$2"
  [[ -n "${3:-}" ]] && notify_slack "$3"
  exit 0
}

# ── guards ───────────────────────────────────────────────────────────────────
[[ "$QF_ENABLED" != "1" ]] && finish "disabled" "QF_ENABLED=0" ""

if [[ ! -f "$CHARTER" ]]; then
  finish "failed" "charter missing at $CHARTER" \
    "🤖 QuantForge autonomous: ABORTED — AUTONOMY_CHARTER.md is missing. No instructions to run."
fi

# Stale locks are stolen: a session killed by the 5h limit never runs its trap.
if [[ -f "$LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [[ $LOCK_AGE -lt $QF_MAX_SECONDS ]]; then
    finish "skipped" "session already running (lock ${LOCK_AGE}s old)" ""
  fi
  rm -f "$LOCK"
fi

# ── budget guard ─────────────────────────────────────────────────────────────
# Counts only sessions that actually consumed quota.
#
# BUG FIXED 2026-08-18 (this killed the whole system): the old form was
#   RUNS_TODAY=$(grep -c "..." "$LEDGER" || echo 0)
# On a no-match, grep PRINTS "0" *and* exits 1, so `|| echo 0` appended a second
# line — RUNS_TODAY became "0\n0". `[[ "0\n0" -ge N ]]` is a math error, and
# `SESSION_N=$(( "0\n0" + 1 ))` left SESSION_N unset, which under `set -u` aborted
# the script (exit 127) *after* the lock was taken but *before* claude was ever
# launched. No ledger row, no Slack — a silent dead slot. And because it fired on
# any date with no prior "ran" row, EVERY slot on EVERY new day would have died
# this way from 2026-08-19 onward. Count with a pipeline that cannot fail instead.
count_ledger() {  # count_ledger <json-fragment>
  [[ -f "$LEDGER" ]] || { echo 0; return; }
  local n
  n=$(grep -F "$1" "$LEDGER" 2>/dev/null | grep -cF '"status":"ran"' 2>/dev/null | tr -cd '0-9')
  echo "${n:-0}"
}
RUNS_TODAY=$(count_ledger "\"date\":\"$(date +%F)\"")
RUNS_WEEK=$(count_ledger "\"week\":\"$(date +%G-W%V)\"")

if [[ "$RUNS_WEEK" -ge "$QF_WEEKLY_RUN_BUDGET" ]]; then
  finish "skipped_budget" "weekly budget spent ($RUNS_WEEK/$QF_WEEKLY_RUN_BUDGET)" ""
fi
if [[ "$RUNS_TODAY" -ge "$QF_DAILY_RUN_CAP" ]]; then
  finish "skipped_budget" "daily cap reached ($RUNS_TODAY/$QF_DAILY_RUN_CAP)" ""
fi

# ── peer-session guard ───────────────────────────────────────────────────────
# Session #2 (2026-08-18) caught a peer `claude -r` session writing the SAME working
# tree concurrently: it staged with `git add -A` and swept up the autonomous session's
# half-finished edits into its own commits. That can ship a broken change to master.
#
# Default policy is WARN, not SKIP, on purpose: an interactive session left open for a
# day would otherwise kill every slot and the week's budget with it. Skipping a slot is
# a guaranteed loss; a peer is only a *possible* collision, and the session can be told
# how to work safely alongside one. Set QF_PEER_POLICY=skip to trade budget for safety.
QF_PEER_POLICY="${QF_PEER_POLICY:-warn}"
PEER_NOTE=""
PEER_PIDS=""
# Our own `claude -p` child does not exist yet at this point, so every match is a peer.
# A peer counts if its cwd is the repo, is INSIDE the repo, or is an ANCESTOR of it —
# the live peer found on 2026-08-18 sat at ~/claude-work, one level up, and still
# committed to the repo. Matching only the exact repo path missed it entirely.
for pid in $(pgrep -x claude 2>/dev/null); do
  pcwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | cut -c2-)
  [[ -z "$pcwd" ]] && continue
  if [[ "$pcwd" == "$REPO" || "$pcwd" == "$REPO"/* || "$REPO" == "$pcwd"/* ]]; then
    PEER_PIDS="$PEER_PIDS $pid"
  fi
done

if [[ -n "$PEER_PIDS" ]]; then
  if [[ "$QF_PEER_POLICY" == "skip" ]]; then
    finish "skipped_peer" "peer claude session(s) hold the repo:$PEER_PIDS" \
      "⏸️ QuantForge autonomous: slot skipped — peer claude session(s)$PEER_PIDS have the repo open (QF_PEER_POLICY=skip)."
  fi
  notify_slack "⚠️ QuantForge autonomous: starting alongside peer claude session(s)$PEER_PIDS on the same tree. Both are writing $REPO."
  read -r -d '' PEER_NOTE <<PEER_EOF || true

⚠️ ANOTHER CLAUDE SESSION IS WRITING THIS SAME WORKING TREE RIGHT NOW (PID(s):$PEER_PIDS).
It is a peer, not your subagent, and it is not coordinating with you. Therefore:
  - Stage ONLY explicit paths you wrote. NEVER \`git add -A\`, \`git add .\`, or \`git commit -a\`
    — you would sweep up the other session's half-finished edits into your commit.
  - Before each commit, re-check \`git status\` and confirm every staged path is yours.
  - If you find work in the tree you did not write, leave it alone. Do not commit it,
    revert it, or stash it.
  - Prefer small, frequent commits so less of your work sits uncommitted and collidable.
PEER_EOF
fi

# ── run ──────────────────────────────────────────────────────────────────────
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

cd "$REPO" || finish "failed" "repo not found: $REPO" "🤖 QuantForge autonomous: repo missing."

# ── clean start ──────────────────────────────────────────────────────────────
# Recurring failure (ledger 2026-08-18 shows dirty=19/5/1): a session killed mid-work by the 5h
# limit leaves an uncommitted tree, and the NEXT session inherits it — unable to tell its own work
# from the corpse, it commits the leftovers or works around them. On 2026-08-18 a killed session
# left TWO complete, tested ADRs (035 + 036) uncommitted; they were nearly lost. Give every session
# a CLEAN tree by first preserving any leftovers to a rescue branch pushed to GitHub — visible,
# backed up, and reviewable as a PR, unlike a local stash that is invisible and easy to forget.
#
# Safety, in order:
#   - The leftovers are COMMITTED to a throwaway rescue branch and pushed, then the tree is reset to
#     the branch it was on — nothing is destroyed, and the rescue branch on GitHub is the recovery
#     path (open a PR, cherry-pick, or delete after review). A local stash is kept as a belt-and-
#     suspenders fallback if the push fails (offline).
#   - A dead session's PUSHED commits are already safe on origin; only the uncommitted working tree
#     is captured here.
#   - Only runs when NO peer claude session is live (PEER_PIDS empty). By this point the lock was
#     either absent (prior session exited cleanly) or stale-stolen (prior session is dead), so the
#     only possible live writer is an interactive peer — exactly what PEER_PIDS catches. A peer's
#     dirty tree is work-in-progress we must never touch.
if [[ -z "$PEER_PIDS" ]]; then
  DIRTY_AT_START=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$DIRTY_AT_START" -gt 0 ]]; then
    CUR_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || echo master)
    RESCUE_BRANCH="rescue/qf-$(date +%Y%m%d-%H%M%S)"
    RESCUED=""
    # `checkout -b` carries the uncommitted changes onto a brand-new branch (no conflict from HEAD),
    # then `add -A` + commit captures them as a real commit — inherently safe: the work survives in
    # git even if the push later fails. A parallel stash belt covers the rare case checkout -b fails.
    git -C "$REPO" stash push -u -m "qf-autonomous clean-start belt $RUN_TS" >>"$RUN_LOG" 2>&1 && STASHED=1 || STASHED=0
    git -C "$REPO" stash apply >>"$RUN_LOG" 2>&1 || true  # re-dirty the tree to move it onto the branch
    if git -C "$REPO" checkout -b "$RESCUE_BRANCH" >>"$RUN_LOG" 2>&1 \
       && git -C "$REPO" add -A >>"$RUN_LOG" 2>&1 \
       && git -C "$REPO" commit -q -m "rescue: uncommitted leftovers from a killed session $RUN_TS" >>"$RUN_LOG" 2>&1; then
      if git -C "$REPO" push -q origin "$RESCUE_BRANCH" >>"$RUN_LOG" 2>&1; then
        RESCUED="pushed branch $RESCUE_BRANCH"
        [[ "$STASHED" == 1 ]] && git -C "$REPO" stash drop >>"$RUN_LOG" 2>&1 || true  # safe on origin
      else
        RESCUED="committed locally to $RESCUE_BRANCH (push failed — stash belt kept too)"
      fi
    fi
    # Return to a CLEAN checkout of the original branch for this session to work on.
    git -C "$REPO" checkout -f "$CUR_BRANCH" >>"$RUN_LOG" 2>&1 || true
    if [[ -n "$RESCUED" ]]; then
      log_cron "$JOB" "clean_start" "rescued $DIRTY_AT_START leftover file(s): $RESCUED"
      notify_slack "🧹 QuantForge autonomous: rescued $DIRTY_AT_START uncommitted file(s) from a prior killed session — $RESCUED. Review + PR or delete."
    fi
  fi
fi

SESSION_N=$(( $(count_ledger '"status":"ran"') + 1 ))

read -r -d '' PROMPT <<PROMPT_EOF
You are an autonomous QuantForge session. Nobody is watching and nobody will answer you.
Joe delegated this project to unattended AI operation — he is not driving it.

Session #$SESSION_N. Started $RUN_TS by launchd. Budget so far: $RUNS_TODAY run(s) today,
$RUNS_WEEK this week (weekly budget $QF_WEEKLY_RUN_BUDGET).

FIRST, read these two files completely, in this order, before any other action:
  1. .claude/RUNNING_STATE.md   — what happened before you; assume you remember nothing
  2. .claude/AUTONOMY_CHARTER.md — your standing authority, hard limits, and operating loop

Then follow the charter. It tells you what to work on, what you may decide on your own,
what you must never do, how to keep RUNNING_STATE.md current, and the retro pass to run
before you stop.

Three things the charter says that matter most, repeated here so you cannot miss them:
  - You WILL be cut off mid-work without warning when the session limit hits. Keep every
    commit green and keep RUNNING_STATE.md accurate as you go, never "at the end".
  - Do NOT stop when a task is done. Pick up the next item and keep working until you are
    cut off. Ending early wastes the budget Joe is paying for.
  - NEVER end your turn with finished work sitting uncommitted. Session #3 lost a whole
    slot's output this way: it launched \`make check\` in the background, said it would
    commit once that returned, and the session ended first. Two complete ADRs sat
    unpushed. If a verification job is still running, WAIT for it in the foreground and
    then commit — do not end your turn while it is pending.
$PEER_NOTE

Work now. Do not ask questions — there is nobody to answer them.
PROMPT_EOF

if [[ "$QF_DRY_RUN" == "1" ]]; then
  echo "[$JOB] DRY RUN — guards passed. today=$RUNS_TODAY/$QF_DAILY_RUN_CAP week=$RUNS_WEEK/$QF_WEEKLY_RUN_BUDGET model=$QF_MODEL"
  echo "--- prompt ---"; echo "$PROMPT"; echo "--- end prompt ---"
  exit 0
fi

echo "[$JOB] session #$SESSION_N starting $RUN_TS (today $RUNS_TODAY/$QF_DAILY_RUN_CAP, week $RUNS_WEEK/$QF_WEEKLY_RUN_BUDGET)" | tee -a "$RUN_LOG"
START=$(date +%s)

CLAUDE_ARGS=(-p "$PROMPT" --permission-mode bypassPermissions)
[[ -n "$QF_MODEL" ]] && CLAUDE_ARGS+=(--model "$QF_MODEL")
[[ -n "$QF_FALLBACK_MODEL" ]] && CLAUDE_ARGS+=(--fallback-model "$QF_FALLBACK_MODEL")

claude "${CLAUDE_ARGS[@]}" >>"$RUN_LOG" 2>&1 &
CLAUDE_PID=$!

# Watchdog: no `timeout` binary on this machine, so poll and kill on overrun.
( while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    [[ $(( $(date +%s) - START )) -ge $QF_MAX_SECONDS ]] && {
      echo "[$JOB] watchdog: exceeded ${QF_MAX_SECONDS}s, terminating" >> "$RUN_LOG"
      kill -TERM "$CLAUDE_PID" 2>/dev/null; sleep 20; kill -KILL "$CLAUDE_PID" 2>/dev/null; break; }
    sleep 60
  done ) &
WATCHDOG_PID=$!

wait "$CLAUDE_PID"; EXIT_CODE=$?
kill "$WATCHDOG_PID" 2>/dev/null
DURATION=$(( $(date +%s) - START ))
MINS=$(( DURATION / 60 ))

# ── classify ─────────────────────────────────────────────────────────────────
# Hitting the session limit is the EXPECTED end state here, not a failure.
#
# Two bugs fixed 2026-08-18 after session #1 was reported as "⚠️ exited 1" instead of
# "⏳ hit session limit":
#   1. The CLI's actual wording is "You've hit your session limit · resets 11am". The old
#      pattern had "usage limit" and "rate limit" but not "session limit", so it never matched.
#   2. The pattern was matched against the WHOLE log — which is the agent's own transcript.
#      A session that merely *discusses* rate limiting (session #2 spent hours fixing a
#      yfinance YFRateLimitError outage) would be misreported as quota-exhausted. The limit
#      notice is always the last thing written, so only the tail is searched, and the pattern
#      now requires the CLI's own phrasing rather than the bare words.
if tail -5 "$RUN_LOG" 2>/dev/null \
  | grep -qiE "hit your (session|usage) limit|(session|usage) limit reached|limit reached ·|resets [0-9]+(am|pm)"; then
  OUTCOME="limit_hit"; ICON="⏳"; WORD="ran ${MINS}m, hit session limit (expected)"
elif [[ $EXIT_CODE -eq 0 ]]; then
  OUTCOME="ran"; ICON="✅"; WORD="completed cleanly after ${MINS}m"
else
  OUTCOME="ran"; ICON="⚠️"; WORD="exited ${EXIT_CODE} after ${MINS}m"
fi

COMMITS=$(git -C "$REPO" log --oneline --since="@$START" 2>/dev/null | wc -l | tr -d ' ')
DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Uncommitted work is the failure mode that actually cost a slot (session #3), and it is
# invisible in a commit count — surface it as its own alarm rather than a field in the tail.
UNPUSHED=$(git -C "$REPO" log --oneline origin/master..HEAD 2>/dev/null | wc -l | tr -d ' ')
RISK=""
[[ "$DIRTY" -gt 0 ]] && RISK="$RISK · ⚠️ ${DIRTY} file(s) left UNCOMMITTED"
[[ "$UNPUSHED" -gt 0 ]] && RISK="$RISK · ⚠️ ${UNPUSHED} commit(s) UNPUSHED"

ledger "ran" "$OUTCOME; ${COMMITS} commit(s); dirty=${DIRTY}; unpushed=${UNPUSHED}" "$DURATION" "$EXIT_CODE"
log_cron "$JOB" "$OUTCOME" "session #$SESSION_N ${MINS}m ${COMMITS} commits dirty=${DIRTY} unpushed=${UNPUSHED}"
notify_slack "$ICON QuantForge autonomous #$SESSION_N: $WORD · ${COMMITS} commit(s) · budget $((RUNS_WEEK+1))/$QF_WEEKLY_RUN_BUDGET this week${RISK} · log: $RUN_LOG"

echo "[$JOB] done: $OUTCOME, ${MINS}m, ${COMMITS} commits" | tee -a "$RUN_LOG"
