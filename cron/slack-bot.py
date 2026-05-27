#!/usr/bin/env python3
"""
Slack bot server. Receives Slack events, runs claude -p, posts response back.
Listens on port 8765. Pair with start-cloudflared.sh for public access.
"""
import hashlib
import hmac
import json
import os
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8765
HOME = os.path.expanduser("~")

def _read_secret(path):
    with open(path) as f:
        return f.read().strip()

BOT_TOKEN      = _read_secret(f"{HOME}/.claude/.slack_bot_token")
SIGNING_SECRET = _read_secret(f"{HOME}/.claude/.slack_signing_secret")
CLAUDE_BIN     = subprocess.run(["which", "claude"], capture_output=True, text=True).stdout.strip()
CLAUDE_WORK    = f"{HOME}/claude-work"


def verify_signature(body: str, timestamp: str, signature: str) -> bool:
    if abs(time.time() - int(timestamp)) > 300:
        return False
    basestring = f"v0:{timestamp}:{body}"
    expected = "v0=" + hmac.new(
        SIGNING_SECRET.encode(),
        basestring.encode(),
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


def post_to_slack(channel: str, text: str):
    payload = json.dumps({"channel": channel, "text": text}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {BOT_TOKEN}",
        },
    )
    urllib.request.urlopen(req, timeout=10)


def run_claude(prompt: str) -> str:
    token_path = f"{HOME}/.claude/.claude_token"
    env = os.environ.copy()
    if os.path.exists(token_path):
        with open(token_path) as f:
            env["CLAUDE_CODE_OAUTH_TOKEN"] = f.read().strip()

    result = subprocess.run(
        [
            CLAUDE_BIN, "-p", prompt,
            "--output-format", "json",
            "--no-session-persistence",
            "--allowedTools", "Read,Bash,Write,Edit,Glob,Grep",
            "--max-budget-usd", "2.00",
        ],
        capture_output=True,
        text=True,
        env=env,
        cwd=CLAUDE_WORK,
        timeout=300,
    )
    try:
        data = json.loads(result.stdout)
        return data.get("result", "").strip() or "(no response)"
    except Exception:
        return (result.stdout or result.stderr or "Error: no output from claude").strip()


def handle_message(text: str, channel: str):
    try:
        response = run_claude(text)
        # Slack has a 4000-char message limit
        if len(response) > 3900:
            response = response[:3900] + "\n…_(truncated)_"
        post_to_slack(channel, response)
    except subprocess.TimeoutExpired:
        post_to_slack(channel, "_(timed out after 5 minutes)_")
    except Exception as e:
        post_to_slack(channel, f"_(error: {e})_")


class SlackHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        body = raw.decode()

        timestamp = self.headers.get("X-Slack-Request-Timestamp", "0")
        signature = self.headers.get("X-Slack-Signature", "")

        if not verify_signature(body, timestamp, signature):
            self.send_response(401)
            self.end_headers()
            return

        data = json.loads(body)

        # URL verification (one-time handshake when setting up Event Subscriptions)
        if data.get("type") == "url_verification":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"challenge": data["challenge"]}).encode())
            return

        # Acknowledge immediately — Slack times out at 3s
        self.send_response(200)
        self.end_headers()

        event = data.get("event", {})
        event_type = event.get("type", "")
        bot_id = event.get("bot_id")
        subtype = event.get("subtype")  # e.g. "bot_message"

        # Only handle human messages (app_mention or DM), skip bot messages
        if event_type in ("app_mention", "message") and not bot_id and not subtype:
            text = event.get("text", "")
            # Strip @mention tokens (e.g. <@U12345>)
            text = " ".join(w for w in text.split() if not w.startswith("<@")).strip()
            channel = event.get("channel", "")
            if text and channel:
                threading.Thread(target=handle_message, args=(text, channel), daemon=True).start()

    def log_message(self, fmt, *args):
        print(f"[slack-bot] {self.client_address[0]} - {fmt % args}")


if __name__ == "__main__":
    if not CLAUDE_BIN:
        raise SystemExit("ERROR: claude not found in PATH")
    print(f"[slack-bot] Starting on port {PORT}")
    print(f"[slack-bot] Using claude: {CLAUDE_BIN}")
    server = HTTPServer(("0.0.0.0", PORT), SlackHandler)
    server.serve_forever()
