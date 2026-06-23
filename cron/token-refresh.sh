#!/usr/bin/env bash
# Runs every 2 hours via launchd. Keeps the OAuth token fresh for cron jobs.
#
# Two-stage strategy:
#   1. Pull the latest credentials from Keychain (Claude Code updates Keychain
#      during interactive use) into ~/.claude/.claude_token.
#   2. If that token is expired or within REFRESH_BUFFER of expiry, perform a
#      real OAuth refresh against the endpoint Claude Code itself uses, then
#      write the rotated credentials back to BOTH Keychain and the token file.
#
# The refresh only fires when the token is at/near expiry — i.e. when no
# interactive session has touched Keychain recently — so in practice it does
# not race a live session's in-memory refresh token. (Edge case: an *idle*
# interactive session could be forced to re-auth; that is rare and recoverable
# by reopening Claude Code.)
#
# Endpoint + client_id verified against the installed Claude Code binary
# (`strings` on versions/2.1.179): POST https://platform.claude.com/v1/oauth/token
# with client_id 9d1c250a-e61b-44d9-88ed-5944d1962f5e. See memory/auth_token_gap.md.

set -uo pipefail

KEYCHAIN_SERVICE="Claude Code-credentials"
TOKEN_FILE="$HOME/.claude/.claude_token"
REPORTS_DIR="$HOME/.claude/_reports"
SLACK_WEBHOOK_FILE="$HOME/.claude/.slack_webhook"
OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
# The gateway rejects a bare token request with HTTP 429 rate_limit_error; the
# anthropic-beta header (the value Claude Code's own SDK sends) is what makes it
# process the refresh normally. Verified live: without it → 429; with it → 200
# (or 400 invalid_grant for a bad token). See [[auth-token-gap]].
OAUTH_BETA="oauth-2025-04-20"
OAUTH_USER_AGENT="claude-cli/2.1.179 (external, cli)"
REFRESH_BUFFER=600   # refresh if <10 min of validity remains (or already expired)
JOB="token-refresh"
mkdir -p "$REPORTS_DIR"

log_cron() {
  printf '{"ts":"%s","job":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$JOB" "$1" "$2" >> "$REPORTS_DIR/cron.log"
}
notify_slack() {
  [[ -f "$SLACK_WEBHOOK_FILE" ]] || return 0
  local url; url=$(cat "$SLACK_WEBHOOK_FILE")
  [[ -n "$url" ]] || return 0
  curl -s -X POST "$url" -H 'Content-type: application/json' \
    -d "{\"text\": $(printf '%s' "$1" | jq -Rs .)}" >/dev/null 2>&1 || true
}

# ── 1. pull latest credentials from Keychain ───────────────────────────────────
FRESH=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$(whoami)" -w 2>/dev/null)
if [[ -z "$FRESH" ]]; then
  log_cron "error" "keychain extraction failed"
  notify_slack "🔑 token-refresh: Keychain extraction failed — cron auth will fail until Claude Code is opened."
  exit 0
fi
printf '%s' "$FRESH" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# ── 2. parse expiry ─────────────────────────────────────────────────────────────
read -r EXPIRES IS_EXPIRED SECS_LEFT HAS_REFRESH < <(python3 -c "
import json, sys, time, datetime
try:
    d = json.loads(sys.argv[1]).get('claudeAiOauth', {})
    ts = d.get('expiresAt', 0) / 1000
    print(datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%dT%H:%M'),
          ts < time.time(), int(ts - time.time()), bool(d.get('refreshToken')))
except Exception:
    print('unknown', True, 0, False)
" "$FRESH" 2>/dev/null || echo "unknown True 0 False")

# Still comfortably valid → just keep the file synced and exit.
if [[ "$IS_EXPIRED" != "True" && "$SECS_LEFT" -gt "$REFRESH_BUFFER" ]]; then
  log_cron "ok" "expires=$EXPIRES"
  exit 0
fi

# ── 3. token is expired / near expiry → attempt a real OAuth refresh ────────────
if [[ "$HAS_REFRESH" != "True" ]]; then
  log_cron "warn" "token_expired_no_refresh_token expires=$EXPIRES"
  notify_slack "🔑 token-refresh: token expired ($EXPIRES) and no refreshToken present. Open Claude Code to re-authenticate."
  exit 0
fi

REFRESH_TOKEN=$(printf '%s' "$FRESH" | jq -r '.claudeAiOauth.refreshToken')
REQ=$(jq -n --arg rt "$REFRESH_TOKEN" --arg cid "$OAUTH_CLIENT_ID" \
  '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid}')

HTTP_RESP=$(curl -sS -m 30 -w $'\n%{http_code}' -X POST "$OAUTH_TOKEN_URL" \
  -H 'Content-Type: application/json' \
  -H "anthropic-beta: $OAUTH_BETA" \
  -H "User-Agent: $OAUTH_USER_AGENT" \
  -d "$REQ" 2>/dev/null)
HTTP_CODE=$(printf '%s' "$HTTP_RESP" | tail -1)
BODY=$(printf '%s' "$HTTP_RESP" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  ERR=$(printf '%s' "$BODY" | jq -r '.error.type // .error // empty' 2>/dev/null)
  log_cron "warn" "refresh_failed http=$HTTP_CODE err=${ERR:-none} expires=$EXPIRES"
  notify_slack "🔑 token-refresh FAILED: OAuth refresh returned HTTP $HTTP_CODE (${ERR:-unknown}). Token expired $EXPIRES — cron auth will fail until Claude Code is opened."
  exit 0
fi

# ── 4. merge rotated credentials, write back to file + Keychain ─────────────────
NEW_BLOB=$(python3 -c "
import json, sys, time
old = json.loads(sys.argv[1]).get('claudeAiOauth', {})
resp = json.loads(sys.argv[2])
old['accessToken'] = resp['access_token']
if resp.get('refresh_token'):
    old['refreshToken'] = resp['refresh_token']
if resp.get('expires_in'):
    old['expiresAt'] = int((time.time() + float(resp['expires_in'])) * 1000)
if resp.get('scope'):
    old['scopes'] = resp['scope'].split()
print(json.dumps({'claudeAiOauth': old}))
" "$FRESH" "$BODY" 2>/dev/null)

if [[ -z "$NEW_BLOB" ]] || ! printf '%s' "$NEW_BLOB" | jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1; then
  log_cron "warn" "refresh_parse_failed http=200 expires=$EXPIRES"
  notify_slack "🔑 token-refresh: OAuth refresh returned 200 but the response could not be parsed. Token expired $EXPIRES."
  exit 0
fi

printf '%s' "$NEW_BLOB" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
if ! security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$(whoami)" -w "$NEW_BLOB" 2>/dev/null; then
  log_cron "warn" "refreshed_file_only keychain_update_failed"
  notify_slack "🔑 token-refresh: refreshed token written to file but Keychain update failed — interactive Claude Code may still hold the old token."
  exit 0
fi

NEW_EXP=$(printf '%s' "$NEW_BLOB" | python3 -c "
import json, sys, datetime
ts = json.load(sys.stdin)['claudeAiOauth']['expiresAt'] / 1000
print(datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%dT%H:%M'))
" 2>/dev/null || echo unknown)
log_cron "ok" "refreshed expires=$NEW_EXP"
notify_slack "🔑 token-refresh: OAuth token auto-refreshed (was expiring $EXPIRES, now $NEW_EXP)."
exit 0
