#!/bin/sh
# Usage: ./install.sh /path/to/your/project
set -e
TARGET="${1:?usage: ./install.sh <target-project-dir>}"
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TARGET/.claude/skills" "$TARGET/.cursor/rules" "$TARGET/.github"
cp -r "$SRC/skills/." "$TARGET/.claude/skills/"
cp "$SRC/.cursor/rules/"*.mdc "$TARGET/.cursor/rules/"
cp "$SRC/.github/copilot-instructions.md" "$TARGET/.github/"
echo "Installed: .claude/skills, .cursor/rules, .github/copilot-instructions.md -> $TARGET"
