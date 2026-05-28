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
    import datetime
    today = datetime.date.today().isoformat()
    lines = []
    today_ok, today_err = [], []
    cron_log = os.path.join(HOME, ".claude/_reports/cron.log")
    if os.path.exists(cron_log):
        with open(cron_log) as f:
            all_entries = [l.strip() for l in f if l.strip()]
        # Filter to actual cron job runs (not compact/stop-failure hook events)
        real_runs = []
        for raw in all_entries:
            try:
                e = json.loads(raw)
                if e.get("job") not in ("compact", "stop-failure"):
                    real_runs.append(e)
                    if e.get("ts", "").startswith(today):
                        if e.get("status") == "ok":
                            today_ok.append(e.get("job", "?"))
                        else:
                            today_err.append(e.get("job", "?"))
            except Exception:
                pass
        for e in real_runs[-5:]:
            ts = e.get("ts", "")[:16]
            lines.append(f"  {ts} {e.get('job','?')}: {e.get('status','?')} ({e.get('detail','')})")
    else:
        lines.append("  (no cron log yet)")

    today_summary = ""
    if today_ok or today_err:
        parts = []
        if today_ok:
            parts.append("✓ " + ", ".join(sorted(set(today_ok))))
        if today_err:
            parts.append("✗ " + ", ".join(sorted(set(today_err))))
        today_summary = "\n*Today (" + today + "):* " + " · ".join(parts)

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
        "*Claude Setup Status*" + today_summary + "\n"
        "*Last 5 cron runs:*\n" + "\n".join(lines) + "\n\n"
        "*LaunchAgents:*\n" + "\n".join(agent_lines)
    )


def cmd_cost() -> str:
    """Return API cost breakdown from cron.log."""
    import datetime, re
    cron_log = os.path.join(HOME, ".claude/_reports/cron.log")
    if not os.path.exists(cron_log):
        return "_(no cron log yet)_"
    today = datetime.date.today().isoformat()
    week_start = (datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())).isoformat()
    by_job_today: dict = {}
    by_job_week: dict = {}
    with open(cron_log) as f:
        for raw in f:
            try:
                e = json.loads(raw.strip())
                ts = e.get("ts", "")
                detail = e.get("detail", "")
                job = e.get("job", "?")
                if job in ("compact", "stop-failure"):
                    continue
                m = re.search(r'cost=([\d.]+)', detail)
                if not m:
                    continue
                cost = float(m.group(1))
                if ts.startswith(today):
                    by_job_today[job] = by_job_today.get(job, 0) + cost
                if ts[:10] >= week_start:
                    by_job_week[job] = by_job_week.get(job, 0) + cost
            except Exception:
                pass
    lines = ["*API Cost Breakdown*"]
    if by_job_today:
        total_today = sum(by_job_today.values())
        lines.append(f"*Today ({today}):* ${total_today:.3f}")
        for job, cost in sorted(by_job_today.items()):
            lines.append(f"  {job}: ${cost:.3f}")
    else:
        lines.append(f"*Today:* $0.000 (no runs yet)")
    if by_job_week:
        total_week = sum(by_job_week.values())
        lines.append(f"*This week (since {week_start}):* ${total_week:.3f}")
        est_month = total_week / max(1, (datetime.date.today() - datetime.date.fromisoformat(week_start)).days + 1) * 30
        lines.append(f"  Estimated monthly: ${est_month:.2f}")
    return "\n".join(lines)


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


def cmd_report() -> str:
    """Return the latest self-heal report findings."""
    reports_dir = os.path.join(HOME, ".claude/_reports")
    reports = sorted(f for f in os.listdir(reports_dir) if f.endswith("-selfheal.json"))
    if not reports:
        return "_(no self-heal reports found)_"
    latest = os.path.join(reports_dir, reports[-1])
    date_str = reports[-1].replace("-selfheal.json", "")
    try:
        with open(latest) as f:
            data = json.load(f)
    except Exception as e:
        return f"_(error reading report: {e})_"
    fixes = data.get("fixes", [])
    if not fixes:
        return f"*Self-Heal {date_str}*: No issues found ✅"
    lines = [f"*Self-Heal {date_str}*: {len(fixes)} issue(s)"]
    for fix in fixes[:8]:
        sev = fix.get("severity", 0)
        icon = "🔴" if sev >= 4 else "🟡" if sev == 3 else "🔵"
        typ = fix.get("type", "?").replace("_", " ")
        desc = fix.get("description", "")[:100]
        auto = " ✅auto" if fix.get("auto_applicable") else ""
        lines.append(f"{icon} [{typ}]{auto}: {desc}")
    return "\n".join(lines)


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

    if text_lower in ("/report", "report", "!report"):
        post_to_slack(channel, cmd_report())
        return

    if text_lower in ("/cost", "cost", "!cost"):
        post_to_slack(channel, cmd_cost())
        return

    if text_lower in ("/help", "help", "!help"):
        post_to_slack(channel, (
            "*Claude Slack Bot*\n"
            "`/status` — cron history and launchd agent health\n"
            "`/report` — latest self-heal findings\n"
            "`/memory` — show memory index entries\n"
            "`/heal` — manually trigger self-heal\n"
            "`/cost` — API cost breakdown (today + this week)\n"
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
