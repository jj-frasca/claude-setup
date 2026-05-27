---
name: skill-auditor
description: Audits the skill manifest against usage logs. Proposes promotions,
  demotions, retirements, and new skills for open gaps. Run weekly or after
  10+ new entries in _usage_log.jsonl.
disable-model-invocation: true
---

## Process

1. Read `~/.claude/skills/_manifest.json`
2. Read `~/.claude/skills/_usage_log.jsonl` (last 30 days)
3. Read `~/.claude/_session_logs/index.jsonl` for session metadata.
   For recent sessions: read the transcript JSONL files to identify patterns.
4. For each skill: assess recency and outcome patterns.
5. Apply `tier_rules` from manifest.
6. Check `gap_log` for open items — has any existing skill now closed a gap?
7. If genuine new gap: propose calling `/skill-builder`.

## Output format — always propose, never auto-apply

```
SKILL AUDIT REPORT — [date]
============================
PROMOTIONS:  [skill] active → core  (reason + usage evidence)
DEMOTIONS:   [skill] active → inactive  (days since last use)
RETIREMENTS: [skill] — (inactive N days, no gap dependency)
NEW GAPS:    [description] — seen N sessions
============================
Awaiting your approval. Say "apply audit" to commit changes.
```

## Hard rules
- Never modify `_manifest.json` without explicit user approval.
- Never create or modify skills during an audit.
- Never retire a skill with an open gap depending on it.
