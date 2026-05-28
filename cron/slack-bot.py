#!/usr/bin/env python3
"""
Slack bot server. Receives Slack events, runs claude -p, posts response back.
Listens on port 8765. Pair with start-cloudflared.sh for public access.
"""
import hashlib
import hmac
import json
import os
import re
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
            raw = f.read().strip()
        try:
            data = json.loads(raw)
            raw = data.get("claudeAiOauth", {}).get("accessToken") or data.get("accessToken") or raw
        except (json.JSONDecodeError, AttributeError):
            pass
        env["CLAUDE_CODE_OAUTH_TOKEN"] = raw

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


def cmd_status() -> str:
    """Return a quick status of cron jobs and launchd agents."""
    lines = []
    cron_log = os.path.join(HOME, ".claude/_reports/cron.log")
    if os.path.exists(cron_log):
        with open(cron_log) as f:
            entries = [l.strip() for l in f if l.strip()]
        for raw in entries[-5:]:
            try:
                e = json.loads(raw)
                ts = e.get("ts", "")[:16]
                lines.append(f"  {ts} {e.get('job','?')}: {e.get('status','?')} ({e.get('detail','')})")
            except Exception:
                pass
    else:
        lines.append("  (no cron log yet)")

    agents = {
        "self-heal":  "com.jjfrasca.selfheal",
        "memory":     "com.jjfrasca.memory",
        "skills":     "com.jjfrasca.skills",
        "slack-bot":  "com.jjfrasca.slackbot",
        "cloudflared":"com.jjfrasca.cloudflared",
    }
    agent_lines = []
    for name, label in agents.items():
        r = subprocess.run(["launchctl", "list", label], capture_output=True, text=True)
        if r.returncode != 0:
            agent_lines.append(f"❌ {name} (not loaded)")
            continue
        pid_m = re.search(r'"PID"\s*=\s*(\d+)', r.stdout)
        exit_m = re.search(r'"LastExitStatus"\s*=\s*(\d+)', r.stdout)
        exit_code = int(exit_m.group(1)) >> 8 if exit_m else 0
        if pid_m:
            agent_lines.append(f"✅ {name} (running pid={pid_m.group(1)})")
        elif exit_code == 0:
            agent_lines.append(f"✅ {name} (ok)")
        else:
            agent_lines.append(f"⚠️ {name} (exit {exit_code})")

    return (
        "*Claude Setup Status*\n"
        "*Last 5 cron runs:*\n" + "\n".join(lines) + "\n\n"
        "*LaunchAgents:*\n" + "\n".join(agent_lines)
    )


def cmd_memory() -> str:
    """Return recent memory index entries."""
    memory_md = os.path.join(HOME, ".claude/projects/-Users-joefrasca-claude-work/memory/MEMORY.md")
    if not os.path.exists(memory_md):
        return "_(no memory index found)_"
    with open(memory_md) as f:
        lines = [l.rstrip() for l in f if l.strip() and not l.startswith("#")]
    if not lines:
        return "_(memory index is empty)_"
    return "*Memory Index:*\n" + "\n".join(lines[:15])


def cmd_heal(channel: str):
    """Trigger self-heal manually in background."""
    post_to_slack(channel, "🔧 Triggering self-heal... (check back in ~60s for results)")
    script = os.path.join(HOME, "claude-work/.claude/cron/self-heal.sh")
    subprocess.Popen(
        ["/bin/bash", script],
        stdout=open(os.path.join(HOME, ".claude/_reports/slack-triggered-selfheal.log"), "w"),
        stderr=subprocess.STDOUT,
    )


def handle_message(text: str, channel: str):
    text_lower = text.lower().strip()

    # Built-in command shortcuts
    if text_lower in ("/status", "status", "!status"):
        post_to_slack(channel, cmd_status())
        return

    if text_lower in ("/memory", "memory", "!memory"):
        post_to_slack(channel, cmd_memory())
        return

    if text_lower in ("/heal", "heal", "!heal"):
        cmd_heal(channel)
        return

    if text_lower in ("/help", "help", "!help"):
        post_to_slack(channel, (
            "*Claude Slack Bot*\n"
            "`/status` — cron history and launchd agent health\n"
            "`/memory` — show memory index entries\n"
            "`/heal` — manually trigger self-heal\n"
            "`/help` — show this message\n"
            "Anything else — forwarded to Claude Code (max $2)"
        ))
        return

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
