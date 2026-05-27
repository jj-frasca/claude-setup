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
         "$CLAUDE_DIR/_session_logs"

# Copy files
cp "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
cp "$REPO_DIR/settings.json" "$CLAUDE_DIR/settings.json"
cp "$REPO_DIR/rules/preferences.md" "$CLAUDE_DIR/rules/preferences.md"
cp "$REPO_DIR/skills/_manifest.json" "$CLAUDE_DIR/skills/_manifest.json"
cp "$REPO_DIR/skills/skill-builder/SKILL.md" "$CLAUDE_DIR/skills/skill-builder/SKILL.md"
cp "$REPO_DIR/skills/skill-auditor/SKILL.md" "$CLAUDE_DIR/skills/skill-auditor/SKILL.md"

# Copy and make hooks executable
for hook in pre-tool-guard post-tool-logger notify session-log; do
  cp "$REPO_DIR/hooks/$hook.sh" "$CLAUDE_DIR/hooks/$hook.sh"
  chmod +x "$CLAUDE_DIR/hooks/$hook.sh"
done

# Patch settings.json: replace $HOME placeholder with actual home path
# (exec-form hooks need the resolved path, not the env var)
sed -i '' "s|\$HOME|$HOME|g" "$CLAUDE_DIR/settings.json"

echo "Files installed."
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
