#!/usr/bin/env bash
# Starts cloudflared quick tunnel to localhost:8765.
# Captures the public URL, writes it to ~/.claude/.slack_tunnel_url,
# and notifies via Slack webhook if the URL changed (e.g. after reboot).
set -euo pipefail

REPORTS_DIR="$HOME/.claude/_reports"
TUNNEL_URL_FILE="$HOME/.claude/.slack_tunnel_url"
LOGFILE="$REPORTS_DIR/cloudflared.log"
FLAG_FILE="$REPORTS_DIR/.cloudflared_url_found"

mkdir -p "$REPORTS_DIR"
rm -f "$FLAG_FILE"

echo "[cloudflared] Starting tunnel → http://localhost:8765"

cloudflared tunnel --url http://localhost:8765 2>&1 | while IFS= read -r line; do
  echo "$line" | tee -a "$LOGFILE"

  if [[ ! -f "$FLAG_FILE" ]] && echo "$line" | grep -qE 'https://[a-z0-9-]+\.trycloudflare\.com'; then
    URL=$(echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1)
    if [[ -n "$URL" ]]; then
      touch "$FLAG_FILE"
      PREV_URL=$(cat "$TUNNEL_URL_FILE" 2>/dev/null || echo "")
      printf '%s' "$URL" > "$TUNNEL_URL_FILE"

      echo ""
      echo "╔══════════════════════════════════════════════════════════╗"
      echo "║  Tunnel URL: $URL"
      echo "║"
      echo "║  Set Slack Event Subscriptions Request URL to:"
      echo "║  ${URL}/slack/events"
      echo "╚══════════════════════════════════════════════════════════╝"
      echo ""

      if [[ "$URL" != "$PREV_URL" ]]; then
        WEBHOOK=$(cat "$HOME/.claude/.slack_webhook" 2>/dev/null || echo "")
        if [[ -n "$WEBHOOK" ]]; then
          curl -s -X POST "$WEBHOOK" \
            -H 'Content-type: application/json' \
            -d "{\"text\":\"🔗 Slack bot tunnel started (URL changed).\nUpdate Slack Event Subscriptions to:\n\`${URL}/slack/events\`\"}" \
            >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
done
