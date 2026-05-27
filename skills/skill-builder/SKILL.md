---
name: skill-builder
description: Creates a new skill from a described gap or recurring pain point.
  Follows the official Claude Code SKILL.md frontmatter spec. Registers as
  candidate in _manifest.json. Use when a pain point has appeared 2+ sessions.
disable-model-invocation: true
---

## Process

1. **Receive**: What pain point does this skill solve? How many sessions has it appeared?

2. **Research first** — does this skill already exist?
   - Check manifest: `cat ~/.claude/skills/_manifest.json`
   - Official Anthropic skills: https://github.com/anthropics/skills
   - If found: recommend installing the existing skill instead.

3. **Design the SKILL.md**:
   - `description` (2–4 sentences: what + when to invoke)
   - `when_to_use` (trigger phrases)
   - Prerequisites / inputs
   - Step-by-step process
   - Output format + success criteria
   - Select correct frontmatter fields per official spec

4. **Size gate**: if design exceeds 500 lines, split into supporting files.

5. **Create** the directory and SKILL.md. Do not create other files without reason.

6. **Register** in `_manifest.json` as tier: `"candidate"`.

7. **Test** once on a real case. Report outcome.

8. Keep `disable-model-invocation: true` until 5+ successful uses confirm value.

## Official frontmatter fields (verified 2026-05-27)
- `name`, `description`, `when_to_use`
- `disable-model-invocation: true` — manual-only (no auto-invoke)
- `user-invocable: false` — hide from / menu
- `allowed-tools: Bash(git *) Read` — auto-approve these tools
- `context: fork` — run in isolated subagent
- `agent: Explore` — subagent type (with context: fork)
- `paths:` — only activate for matching files
- `effort: high` — effort override
- `model: claude-opus-4-6` — model override
- `hooks:` — lifecycle hooks scoped to this skill

Source: https://code.claude.com/docs/en/skills
