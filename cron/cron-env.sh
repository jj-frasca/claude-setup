#!/usr/bin/env bash
# Sourced by all cron scripts. Sets PATH, loads secrets, exports common vars.

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CLAUDE_TOKEN_FILE="$HOME/.claude/.claude_token"
SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"

if [[ ! -f "$CLAUDE_TOKEN_FILE" ]]; then
  echo "[cron-env] ERROR: $CLAUDE_TOKEN_FILE not found. Run cron/setup-cron-auth.sh first." >&2
  exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN
_RAW_TOKEN=$(cat "$CLAUDE_TOKEN_FILE")
# Keychain returns a JSON blob; extract the accessToken if so
if echo "$_RAW_TOKEN" | jq . >/dev/null 2>&1; then
  CLAUDE_CODE_OAUTH_TOKEN=$(echo "$_RAW_TOKEN" | jq -r '.claudeAiOauth.accessToken // .accessToken // .')
else
  CLAUDE_CODE_OAUTH_TOKEN="$_RAW_TOKEN"
fi
unset _RAW_TOKEN

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
  local response stderr_content
  local attempt=0

  while [[ $attempt -lt 2 ]]; do
    stderr_content=""
    if response=$(claude -p "$@" 2>"$err_log"); then
      echo "$response"
      return 0
    fi
    stderr_content=$(cat "$err_log" 2>/dev/null || true)
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
