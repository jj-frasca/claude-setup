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

# Log expiry for observability
EXPIRES=$(python3 -c "
import json, sys, datetime
try:
    d = json.loads(sys.argv[1])
    ts = d.get('claudeAiOauth', {}).get('expiresAt', 0) / 1000
    print(datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%dT%H:%M'))
except:
    print('unknown')
" "$FRESH" 2>/dev/null || echo "unknown")

printf '{"ts":"%s","job":"token-refresh","status":"ok","detail":"expires=%s"}\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$EXPIRES" >> "$REPORTS_DIR/cron.log"
