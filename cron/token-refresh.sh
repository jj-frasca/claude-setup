#!/usr/bin/env bash
# Runs every 2 hours via launchd. Extracts the latest OAuth token from Keychain
# and writes it to ~/.claude/.claude_token so cron jobs always have a fresh token.
# Claude Code updates Keychain whenever it refreshes the access token during active use.

TOKEN_FILE="$HOME/.claude/.claude_token"
REPORTS_DIR="$HOME/.claude/_reports"
mkdir -p "$REPORTS_DIR"

FRESH=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null)
if [[ -z "$FRESH" ]]; then
  printf '{"ts":"%s","job":"token-refresh","status":"error","detail":"keychain extraction failed"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$REPORTS_DIR/cron.log"
  exit 0
fi

printf '%s' "$FRESH" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# Check expiry and log accordingly
EXPIRY_INFO=$(python3 -c "
import json, sys, datetime, time
try:
    d = json.loads(sys.argv[1])
    ts = d.get('claudeAiOauth', {}).get('expiresAt', 0) / 1000
    expires_str = datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%dT%H:%M')
    expired = ts < time.time()
    print(f'{expires_str} expired={expired}')
except:
    print('unknown expired=False')
" "$FRESH" 2>/dev/null || echo "unknown expired=False")

EXPIRES="${EXPIRY_INFO%% expired=*}"
IS_EXPIRED="${EXPIRY_INFO##* expired=}"

if [[ "$IS_EXPIRED" == "True" ]]; then
  # Token in Keychain is already expired. Claude Code only refreshes Keychain during
  # active interactive use. OAuth refresh via API endpoint not yet confirmed (see auth_token_gap.md).
  # Cron jobs will likely fail with authentication_failed until user opens Claude Code.
  printf '{"ts":"%s","job":"token-refresh","status":"warn","detail":"token_expired expires=%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$EXPIRES" >> "$REPORTS_DIR/cron.log"
else
  printf '{"ts":"%s","job":"token-refresh","status":"ok","detail":"expires=%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$EXPIRES" >> "$REPORTS_DIR/cron.log"
fi
