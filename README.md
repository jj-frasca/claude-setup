# claude-setup

My personal Claude Code configuration — hooks, skills, and self-healing infrastructure that lives in `~/claude-work/.claude/` and applies to every project I work on.

## What this does

Claude Code is powerful out of the box, but by default it has no memory between sessions, no logging, and no protection against accidents. This setup adds:

- **Self-healing feedback loop** — every session is logged, failures surface patterns, patterns become skills
- **Safety hooks** — blocks the few commands that are genuinely irreversible (nuking system directories, writing to raw disk devices)
- **Usage tracking** — every file edit is logged so you can audit what Claude touched across sessions
- **Terminal notifications** — get a ping when Claude pauses waiting for input
- **Skill system** — package repeatable workflows into slash commands; audit and grow them over time

## Directory structure

```
~/claude-work/
└── .claude/                    ← applies to all work in this directory
    ├── CLAUDE.md               ← Claude's standing instructions
    ├── settings.json           ← hooks, model, permissions
    ├── hooks/
    │   ├── pre-tool-guard.sh   ← blocks catastrophic bash commands
    │   ├── post-tool-logger.sh ← logs every file write/edit to JSONL
    │   ├── notify.sh           ← terminal notification on pause
    │   └── session-log.sh      ← logs session metadata on stop
    ├── rules/
    │   └── preferences.md      ← personal style preferences
    ├── skills/
    │   ├── _manifest.json      ← skill registry with tier system
    │   ├── skill-builder/      ← /skill-builder: create new skills
    │   └── skill-auditor/      ← /skill-auditor: review and promote skills
    └── _session_logs/
        └── index.jsonl         ← one entry per session with transcript path
```

Individual repos under `repos/` can have their own `.claude/` for targeted overrides — test commands, project-specific rules, or extra permissions scoped to that codebase.

## Self-healing system

The setup runs in three phases that activate over time:

### Phase A — Immediate (day one)
Claude follows hard retry limits: max 2 attempts on any failure, then stops and explains the root cause. No silent loops. Destructive operations (file deletion, DB migrations) are never auto-retried.

### Phase B — Session-end (after a few weeks of stable hooks)
The Stop hook writes a JSONL entry for every session pointing at the full transcript. In the next session, Claude can read `_session_logs/index.jsonl`, open recent transcripts, and identify recurring failure patterns — things that went wrong more than once with no skill coverage.

When a pattern appears 3+ times, it becomes a gap log entry.

### Phase C — Systemic (after months of usage)
Run `/skill-auditor` to review the manifest against usage logs. It proposes promotions, demotions, retirements, and calls `/skill-builder` for open gaps. New skills are proposed to you — never created autonomously.

## Hooks

All hooks receive JSON on stdin from Claude Code and output JSON to control behavior.

### `pre-tool-guard.sh`
Fires before every Bash command. Blocks only genuinely catastrophic operations:
- `rm -rf /` or `rm -rf /usr /etc /System`
- Direct writes to raw disk devices (`> /dev/sd*`, `> /dev/disk*`)

Everything else runs freely. `bypassPermissions` mode handles normal permission flow.

### `post-tool-logger.sh`
Fires after every Write/Edit/MultiEdit. Appends a JSONL entry:
```json
{"ts":"2026-05-27T10:00:00Z","session":"abc123","tool":"Edit","file":"/path/to/file.py"}
```
Useful for auditing what Claude changed across sessions.

### `session-log.sh`
Fires when Claude stops. Writes session metadata to `_session_logs/index.jsonl`:
```json
{"ts":"2026-05-27T10:00:00Z","session":"abc123","transcript":"/path/to/transcript.jsonl"}
```
Use the transcript path in the next session to review what happened.

### `notify.sh`
Fires on Notification events. Sends a terminal notification using `terminalSequence` (requires Claude Code v2.1.141+).

## Skill system

Skills are slash commands loaded on demand — their content doesn't consume context until you invoke them.

### `/skill-builder`
Invoke when a recurring pain point needs a repeatable solution. It checks whether a skill already exists (including [Anthropic's official skills](https://github.com/anthropics/skills)), designs the SKILL.md, creates the directory, and registers it as a `candidate` in the manifest.

### `/skill-auditor`
Reads `_manifest.json` and `_usage_log.jsonl`. Produces a report:
```
SKILL AUDIT REPORT — 2026-05-27
============================
PROMOTIONS:  skill-builder active → core  (used 12x, high value)
DEMOTIONS:   old-skill active → inactive  (22 days unused)
NEW GAPS:    docker-debug — seen 4 sessions
============================
Awaiting your approval. Say "apply audit" to commit changes.
```
Nothing is applied without your explicit approval.

## Model selection

Default is `claude-sonnet-4-6` — fast, 40% cheaper than Opus 4.7.

Switch to Opus 4.7 for multi-step agentic tasks, deep architecture decisions, or complex debugging. Claude will proactively suggest a switch when the task warrants it.

```
/model claude-opus-4-7   ← switch for this session
/fast                    ← Opus with faster output
```

Pricing (verified 2026-05-27):
- Sonnet 4.6: $3/MTok input, $15/MTok output
- Opus 4.7: $5/MTok input, $25/MTok output

## Installation

```bash
git clone https://github.com/jj-frasca/claude-setup.git ~/claude-work
cd ~/claude-work/repos/claude-setup
chmod +x install.sh
./install.sh
```

Then open Claude Code with your working directory set to `~/claude-work` and run:
```
/plugin marketplace add anthropics/skills
/plugin install document-skills@anthropic-agent-skills
```

## Global settings (`~/.claude/settings.json`)

The global config stays minimal — just model default and bypass mode. All hooks live at the workspace level so they're visible and editable without digging into hidden system directories.

```json
{
  "model": "claude-sonnet-4-6",
  "permissions": { "defaultMode": "bypassPermissions" }
}
```

## References

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Claude Code memory & CLAUDE.md](https://code.claude.com/docs/en/memory)
- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [Anthropic official skills](https://github.com/anthropics/skills)
- [Model pricing](https://platform.claude.com/docs/en/docs/about-claude/models/overview)
