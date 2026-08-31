#!/usr/bin/env bash
# Daily 8am brief to Joe: where QuantForge is, and whether the money is working.
#
# Joe asked for this 2026-08-29: "I want to know what's going on and how our money making is
# working and whether or not we are getting there."
#
# Design rule: every NUMBER in the email is computed here, in Python, from the committed data.
# The model is given those facts and asked only to WRITE. It is never asked to calculate, recall,
# or estimate a figure — that is how a summary ends up quietly reporting a return that never
# happened. If a fact is missing, the brief says "unavailable", never a guess.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cron-env.sh
source "$SCRIPT_DIR/cron-env.sh"

JOB="daily-brief"
REPO="$HOME/claude-work/quantforge"
TO="jjfrasca10@gmail.com"
FACTS="$REPORTS_DIR/daily-brief-facts-$(date +%Y%m%d).json"
BODY="$REPORTS_DIR/daily-brief-body-$(date +%Y%m%d).txt"
SENT="$REPORTS_DIR/daily-brief-sent-$(date +%Y%m%d).marker"

# The plist carries several clock slots so a slot missed while the Mac was asleep still runs on
# wake. That means the job can legitimately fire more than once a day, and a duplicate brief in
# the inbox trains Joe to ignore it. One send per calendar day; a dry run neither checks nor sets.
if [[ "${BRIEF_DRY_RUN:-0}" != "1" && -f "$SENT" ]]; then
  log_cron "$JOB" "skipped" "already sent today"
  exit 0
fi

cd "$REPO" 2>/dev/null || { log_cron "$JOB" "failed" "repo missing"; exit 0; }
git fetch -q origin 2>/dev/null || true

# ── gather facts ─────────────────────────────────────────────────────────────
python3 - "$REPO" "$REPORTS_DIR" > "$FACTS" <<'PY'
import json, subprocess, sys, os, datetime
repo, reports = sys.argv[1], sys.argv[2]
def sh(c):
    try: return subprocess.run(c, shell=True, cwd=repo, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception: return ""
F = {"generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}

# --- money: the paper account, from the committed equity curve ---
try:
    d = json.load(open(os.path.join(repo, "data/equity_curve.json")))
    pts = d if isinstance(d, list) else d.get("points", [])
    pts = [p for p in pts if isinstance(p, dict) and p.get("equity") is not None]
    pts.sort(key=lambda p: p.get("timestamp", ""))
    if pts:
        cur, first = pts[-1], pts[0]
        prev = pts[-2] if len(pts) > 1 else None
        F["money"] = {
            "as_of": cur.get("timestamp"),
            "equity": cur.get("equity"),
            "cash": cur.get("cash"),
            "pct_cash": round(100.0 * cur["cash"] / cur["equity"], 1) if cur.get("cash") and cur.get("equity") else None,
            "n_positions": cur.get("n_positions"),
            "return_since_start_pct": round(100.0 * cur["return_since_start"], 2) if cur.get("return_since_start") is not None else None,
            "benchmark_return_pct": round(100.0 * cur["benchmark_return_since_start"], 2) if cur.get("benchmark_return_since_start") is not None else None,
            "alpha_pct": round(100.0 * cur["alpha_since_start"], 2) if cur.get("alpha_since_start") is not None else None,
            "equity_change_since_prev": round(cur["equity"] - prev["equity"], 2) if prev else None,
            "days_tracked": len(pts),
            "first_point": first.get("timestamp"),
        }
except Exception as e:
    F["money"] = {"error": f"equity curve unreadable: {e}"}

# --- the book ---
try:
    b = json.load(open(os.path.join(repo, "data/paper_portfolio.json")))
    pos = b.get("positions", b) if isinstance(b, dict) else b
    F["book"] = {"open_positions": len(pos) if hasattr(pos, "__len__") else None}
except Exception:
    F["book"] = {"open_positions": None}

# --- agent activity, last 24h ---
def ledger_24h(path, statuses):
    out = {"runs": 0, "minutes": 0}
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
    try:
        for line in open(path):
            try: r = json.loads(line)
            except Exception: continue
            ts = r.get("ts") or r.get("timestamp") or ""
            try: t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except Exception: continue
            if t < cutoff: continue
            if r.get("status") in statuses:
                out["runs"] += 1
                out["minutes"] += int((r.get("duration_s") or r.get("duration_seconds") or 0) / 60)
    except FileNotFoundError:
        return {"runs": None, "minutes": None}
    return out
F["claude_agent"] = ledger_24h(os.path.join(reports, "qf-autonomous-ledger.jsonl"), {"ran"})
F["codex_agent"]  = ledger_24h(os.path.join(reports, "qf-codex-ledger.jsonl"), {"completed", "limit_hit"})

# --- shipped ---
F["commits_24h"] = int(sh("git log --since='24 hours ago' --oneline | wc -l") or 0)
F["commit_subjects"] = [s for s in sh("git log --since='24 hours ago' --format=%s | grep -viE '^chore\\(' | head -12").split("\n") if s]
F["adr_count"] = int(sh("ls docs/adr/ADR-*.md | wc -l") or 0)
F["newest_adrs"] = [s for s in sh("ls docs/adr/ADR-*.md | tail -3 | xargs -n1 basename").split("\n") if s]
F["behind_origin"] = int(sh("git rev-list --count HEAD..origin/master") or 0)
F["dirty_files"] = int(sh("git status --porcelain | wc -l") or 0)

# --- health ---
F["ci_recent"] = [s for s in sh("gh run list --limit 8 --json conclusion,name -q '.[] | \"\\(.conclusion // \\\"running\\\")  \\(.name)\"'").split("\n") if s]
F["last_agent_run_gap_hours"] = None
try:
    lines = [json.loads(l) for l in open(os.path.join(reports, "qf-autonomous-ledger.jsonl")) if l.strip()]
    last = max(l.get("ts", "") for l in lines if l.get("status") == "ran")
    t = datetime.datetime.fromisoformat(last.replace("Z", "+00:00"))
    F["last_agent_run_gap_hours"] = round((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 3600, 1)
except Exception: pass
print(json.dumps(F, indent=2))
PY

[[ -s "$FACTS" ]] || { log_cron "$JOB" "failed" "fact gathering produced nothing"; exit 0; }

# ── write the brief ──────────────────────────────────────────────────────────
read -r -d '' BRIEF_PROMPT <<'EOF' || true
Write Joe's morning brief on QuantForge as a plain-text email body. He reads it on a phone before
work. He wants two questions answered: what is going on, and is the money working.

You are given a JSON fact block. EVERY number you write must come from it verbatim. Do not compute,
infer, annualize, or project anything. If a field is null or missing, write "not available" — never
substitute a guess. Do not repeat the JSON back; write prose and short lists.

Structure, in this order, no preamble:

1. MONEY (lead with this, 3-5 sentences). State equity, return since start, the benchmark return
   and the alpha, plainly. Then answer "are we getting there?" honestly. Rules for that answer:
   - QuantForge is a RESEARCH and VALIDATION project, not a trading business. The paper account is
     an honesty check on the research, not the product. Say so if the numbers are bad, but do not
     use it to dodge the question.
   - If the return is negative or alpha is negative, say so directly in the first two sentences.
     Never lead with a positive framing of a losing book.
   - A high cash percentage means capital is idle, which caps upside. Mention it if pct_cash > 40.
   - Never describe a paper account as making or losing "money" in a way that implies real funds.
2. WHAT SHIPPED (3-4 sentences + up to 5 bullets). Commits in 24h, notable work from the commit
   subjects, current ADR count.
3. HEALTH (2-4 sentences). Agent runs and minutes for each of the two agents in the last 24h. If
   last_agent_run_gap_hours is above 12, that is the most important thing in this section — say the
   agents have stalled and how long it has been. Flag any non-success CI, uncommitted files, or
   commits behind origin.
4. WHAT I'D WATCH (2-3 bullets). The most decision-relevant things for Joe today. If nothing needs
   him, say that plainly rather than inventing a task.

Tone: direct, specific, no hype, no filler, no sign-off. Under 400 words.

FACTS:
EOF

BRIEF=$(cat "$FACTS" | claude -p "$BRIEF_PROMPT
$(cat "$FACTS")" --model sonnet 2>>"$REPORTS_DIR/daily-brief-error.log")

if [[ -z "$BRIEF" ]]; then
  # Never send a silent or empty brief — a missing email reads as "nothing to report", which is a lie.
  BRIEF="Brief generation FAILED — the summarizer returned nothing. Raw facts below so the morning
is not lost:

$(cat "$FACTS")"
  log_cron "$JOB" "degraded" "summarizer returned empty; sent raw facts"
fi

printf '%s\n' "$BRIEF" > "$BODY"

# ── send ─────────────────────────────────────────────────────────────────────
EQ=$(python3 -c "import json;d=json.load(open('$FACTS')).get('money',{});print(f\"\${d.get('equity','?'):,}\" if isinstance(d.get('equity'),(int,float)) else '?')" 2>/dev/null || echo "?")
RET=$(python3 -c "import json;d=json.load(open('$FACTS')).get('money',{});r=d.get('return_since_start_pct');print(f'{r:+.2f}%' if isinstance(r,(int,float)) else '?')" 2>/dev/null || echo "?")
SUBJECT="QuantForge daily — $EQ ($RET) — $(date +%b\ %-d)"

if [[ "${BRIEF_DRY_RUN:-0}" == "1" ]]; then
  echo "=== DRY RUN — not sending ==="
  echo "To: $TO"
  echo "Subject: $SUBJECT"
  echo "---"
  cat "$BODY"
  exit 0
fi

if gws gmail +send --to "$TO" --subject "$SUBJECT" --body "$(cat "$BODY")" >/dev/null 2>>"$REPORTS_DIR/daily-brief-error.log"; then
  date +%s > "$SENT"
  log_cron "$JOB" "ok" "sent to $TO: $SUBJECT"
else
  log_cron "$JOB" "failed" "gws gmail send failed — see daily-brief-error.log"
  notify_slack "📧 QuantForge daily brief FAILED to send. Body saved at $BODY"
fi
