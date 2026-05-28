#!/bin/bash
# install.sh — sets up the Claude Code global config from this repo.
# Safe to re-run: backs up existing config before overwriting anything.
set -e

CLAUDE_DIR="$HOME/.claude"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$CLAUDE_DIR/backups/pre-install-$(date +%Y-%m-%d-%H%M)"

echo "Claude Code Setup Installer"
echo "==========================="
echo "Config dir: $CLAUDE_DIR"
echo "Backup dir: $BACKUP_DIR"
echo ""

# Dependency check
MISSING=()
for cmd in jq bc python3; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}"
  echo "Install with: brew install ${MISSING[*]}"
  exit 1
fi

# Backup existing config
mkdir -p "$BACKUP_DIR"
for f in settings.json CLAUDE.md; do
  [ -f "$CLAUDE_DIR/$f" ] && cp "$CLAUDE_DIR/$f" "$BACKUP_DIR/" && echo "Backed up: $f"
done
[ -d "$CLAUDE_DIR/hooks" ] && cp -r "$CLAUDE_DIR/hooks" "$BACKUP_DIR/" && echo "Backed up: hooks/"
[ -d "$CLAUDE_DIR/skills" ] && cp -r "$CLAUDE_DIR/skills" "$BACKUP_DIR/" && echo "Backed up: skills/"
echo ""

# Create directories
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/rules" \
         "$CLAUDE_DIR/skills/skill-builder" "$CLAUDE_DIR/skills/skill-auditor" \
         "$CLAUDE_DIR/_session_logs" "$CLAUDE_DIR/_session_logs/titles"

# Copy files
cp "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
cp "$REPO_DIR/rules/preferences.md" "$CLAUDE_DIR/rules/preferences.md"
cp "$REPO_DIR/skills/_manifest.json" "$CLAUDE_DIR/skills/_manifest.json"
cp "$REPO_DIR/skills/skill-builder/SKILL.md" "$CLAUDE_DIR/skills/skill-builder/SKILL.md"
cp "$REPO_DIR/skills/skill-auditor/SKILL.md" "$CLAUDE_DIR/skills/skill-auditor/SKILL.md"

# Copy and make hooks executable
for hook in pre-tool-guard post-tool-logger post-tool-failure notify session-log session-start pre-compact post-compact stop-failure memory-index-sync session-title; do
  cp "$REPO_DIR/hooks/$hook.sh" "$CLAUDE_DIR/hooks/$hook.sh"
  chmod +x "$CLAUDE_DIR/hooks/$hook.sh"
done

# Merge global hooks into ~/.claude/settings.json (preserves existing settings)
echo "Merging hooks into $CLAUDE_DIR/settings.json..."
HOOK_DIR="$REPO_DIR/hooks"
python3 - <<PYEOF
import json, os, sys

home = os.environ['HOME']
settings_path = os.path.join(home, '.claude', 'settings.json')
hook_dir = os.environ.get('HOOK_DIR', '$HOOK_DIR')

# Load existing settings (or start fresh)
try:
    with open(settings_path) as f:
        settings = json.load(f)
except Exception:
    settings = {}

# Build hooks config with absolute paths
hooks = {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": f"{hook_dir}/session-title.sh"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": f"{hook_dir}/session-start.sh"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": f"{hook_dir}/pre-tool-guard.sh"}]}],
    "PostToolUse": [
        {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": f"{hook_dir}/post-tool-logger.sh", "async": True}]},
        {"matcher": "Write", "hooks": [{"type": "command", "command": f"{hook_dir}/memory-index-sync.sh", "async": True}]},
    ],
    "PostToolUseFailure": [
        {"hooks": [{"type": "command", "command": f"{hook_dir}/post-tool-failure.sh", "async": True}]},
    ],
    "Notification": [{"hooks": [{"type": "command", "command": f"{hook_dir}/notify.sh", "async": True}]}],
    "Stop": [{"hooks": [{"type": "command", "command": f"{hook_dir}/session-log.sh", "async": True}]}],
    "StopFailure": [{"matcher": "rate_limit|authentication_failed|overloaded|timeout", "hooks": [{"type": "command", "command": f"{hook_dir}/stop-failure.sh", "async": True}]}],
    "PreCompact": [{"matcher": "auto|manual", "hooks": [{"type": "command", "command": f"{hook_dir}/pre-compact.sh"}]}],
    "PostCompact": [{"matcher": "auto|manual", "hooks": [{"type": "command", "command": f"{hook_dir}/post-compact.sh"}]}],
}

settings['hooks'] = hooks
settings.setdefault('cleanupPeriodDays', 90)
settings.setdefault('awaySummaryEnabled', True)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
print(f"  Hooks merged into {settings_path}")
PYEOF

echo "Files installed."
echo ""

# Set up daily automation (cron scripts + launchd agents)
echo "Setting up daily automation..."

mkdir -p "$HOME/.claude/_reports"
chmod +x "$REPO_DIR/cron/setup-cron-auth.sh" \
         "$REPO_DIR/cron/self-heal.sh" \
         "$REPO_DIR/cron/memory-consolidate.sh" \
         "$REPO_DIR/cron/skills-track.sh"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"

for plist in selfheal memory skills; do
  src="$REPO_DIR/launchd/com.jjfrasca.${plist}.plist"
  dst="$LAUNCH_AGENTS_DIR/com.jjfrasca.${plist}.plist"
  cp -f "$src" "$dst"

  launchctl unload "$dst" 2>/dev/null || true
  launchctl load -w "$dst" && echo "  Loaded: com.jjfrasca.$plist" \
    || echo "  [WARN] Failed to load: com.jjfrasca.$plist (check Console.app)"
done

echo ""
echo "Daily automation installed. Three launchd jobs:"
echo "  5:00 PM  — self-heal      (session failure analysis)"
echo " 10:00 PM  — memory         (memory deduplication)"
echo " 11:00 PM  — skills-track   (skill usage → preferred_skills.md)"
echo ""
echo "REQUIRED one-time steps:"
echo "  1. Run: bash $REPO_DIR/cron/setup-cron-auth.sh"
echo "  2. Set Slack webhook (optional):"
echo "     echo 'https://hooks.slack.com/services/YOUR/URL' > ~/.claude/.slack_webhook"
echo "     chmod 600 ~/.claude/.slack_webhook"
echo ""

# Add repomix MCP (requires claude CLI)
if command -v claude &>/dev/null; then
  echo "Adding repomix MCP server..."
  claude mcp add -s user repomix -- npx -y repomix --mcp 2>/dev/null \
    && echo "repomix MCP added." \
    || echo "repomix already configured or failed — check: claude mcp list"
else
  echo "[SKIP] claude CLI not found — install Claude Code first, then run:"
  echo "  claude mcp add -s user repomix -- npx -y repomix --mcp"
fi

echo ""
echo "Done. Restart Claude Code for hooks to take effect."
echo "To install Anthropic's official document skills, run inside Claude Code:"
echo "  /plugin marketplace add anthropics/skills"
echo "  /plugin install document-skills@anthropic-agent-skills"
