#!/usr/bin/env bash
# Sourced by all cron scripts. Sets PATH, loads secrets, exports common vars.

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CLAUDE_TOKEN_FILE="$HOME/.claude/.claude_token"
SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"

# Mirror the current Keychain credential blob into the token file for
# diagnostics/observability. Best-effort — not used for auth.
if _FRESH=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null) \
    && [[ -n "$_FRESH" ]]; then
  printf '%s' "$_FRESH" > "$CLAUDE_TOKEN_FILE"
  chmod 600 "$CLAUDE_TOKEN_FILE"
fi
unset _FRESH

# Auth: do NOT export a static CLAUDE_CODE_OAUTH_TOKEN. A static access token
# can't be refreshed and goes stale between runs, and having token-refresh rotate
# the refresh token independently desynced the CLI's own rotating token (HTTP 400
# invalid_grant). Unset it so `claude` authenticates from Keychain and lets its
# own token manager handle refresh + rotation as the single source of truth.
unset CLAUDE_CODE_OAUTH_TOKEN

SLACK_WEBHOOK_URL=""
if [[ -f "$SLACK_WEBHOOK_FILE" ]]; then
  SLACK_WEBHOOK_URL=$(cat "$SLACK_WEBHOOK_FILE")
fi

export REPORTS_DIR="$HOME/.claude/_reports"
export CLAUDE_WORK="$HOME/claude-work/.claude"
export TODAY
TODAY=$(date +"%Y-%m-%d")

mkdir -p "$REPORTS_DIR"

notify_slack() {
  local message="$1"
  if [[ -z "$SLACK_WEBHOOK_URL" ]]; then return 0; fi
  curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-type: application/json' \
    -d "{\"text\": $(printf '%s' "$message" | jq -Rs .)}" \
    >/dev/null 2>&1 || true
}

log_cron() {
  local job="$1"
  local status="$2"
  local detail="$3"
  printf '{"ts":"%s","job":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$job" "$status" "$detail" \
    >> "$REPORTS_DIR/cron.log"
}

# extract_json <text>
# Prints the rightmost valid JSON dict found in text, strips code fences.
# Returns exit 1 (and prints nothing) if no valid JSON dict is found.
extract_json() {
  printf '%s' "$1" | python3 -c "
import sys, json, re
text = sys.stdin.read().strip()
text = re.sub(r'\`\`\`(?:json)?\s*', '', text).strip()
try:
    obj = json.loads(text)
    if isinstance(obj, dict):
        print(json.dumps(obj))
        sys.exit(0)
except Exception:
    pass
positions = [m.start() for m in re.finditer(r'\{', text)]
for start in reversed(positions):
    depth = 0
    end = -1
    for i, c in enumerate(text[start:]):
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end = start + i + 1
                break
    if end > start:
        try:
            obj = json.loads(text[start:end])
            if isinstance(obj, dict):
                print(json.dumps(obj))
                sys.exit(0)
        except Exception:
            continue
sys.exit(1)
" 2>/dev/null
}

# run_claude <error-log-path> [claude args...]
# Runs claude -p, separating stderr. On rate-limit, retries once after 60s.
# Prints JSON response on success. Logs stderr to error-log-path on failure.
run_claude() {
  local err_log="$1"; shift
  local response stderr_content exit_code
  local attempt=0

  while [[ $attempt -lt 2 ]]; do
    stderr_content=""
    response=$(claude -p "$@" 2>"$err_log")
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
      echo "$response"
      return 0
    fi
    stderr_content=$(cat "$err_log" 2>/dev/null || true)
    if [[ -z "$stderr_content" ]]; then
      {
        echo "[cron-env] claude -p exited with status $exit_code, no stderr captured."
        if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
          echo "[cron-env] CLAUDE_CODE_OAUTH_TOKEN is empty."
        else
          echo "[cron-env] CLAUDE_CODE_OAUTH_TOKEN length: ${#CLAUDE_CODE_OAUTH_TOKEN}"
        fi
        echo "[cron-env] claude binary: $(command -v claude 2>&1)"
        echo "[cron-env] claude --version: $(claude --version 2>&1)"
        if [[ -n "$response" ]]; then
          echo "[cron-env] stdout from claude -p:"
          printf '%s\n' "$response"
        else
          echo "[cron-env] stdout from claude -p was empty."
        fi
      } >> "$err_log"
      stderr_content=$(cat "$err_log" 2>/dev/null || true)
    fi
    attempt=$((attempt + 1))
    if echo "$stderr_content" | grep -qi "rate.limit\|429\|too.many.request"; then
      echo "[cron-env] Rate limit — sleeping 90s before retry ($attempt/2)..." >&2
      sleep 90
    else
      return 1
    fi
  done
  return 1
}
