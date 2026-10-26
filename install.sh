#!/usr/bin/env bash
# Install Claude love Gemini into the user's Claude Code setup.
#
#   bash install.sh            # install into ~/.claude
#   CLAUDE_DIR=/path install.sh
#
# The installer never overwrites your CLAUDE.md, settings.json or an existing
# GEMINI.md. Anything it would touch is reported first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
SKILL_DIR="$CLAUDE_DIR/skills/claude-love-gemini"
GEMINI_DIR="${GEMINI_HOME:-$HOME/.gemini}"

echo "Claude love Gemini — installer"
echo "  target: $SCRIPTS_DIR"
echo

mkdir -p "$SCRIPTS_DIR" "$SKILL_DIR"
for f in agy-run.sh gemini-run.sh gemini-task.sh task_report.py task_meta.py; do
  cp "$HERE/scripts/$f" "$SCRIPTS_DIR/$f"
  chmod +x "$SCRIPTS_DIR/$f" 2>/dev/null || true
  echo "  installed: $SCRIPTS_DIR/$f"
done

mkdir -p "$SCRIPTS_DIR/tests"
for f in run-tests.sh run-lifecycle.sh run-merge-atomic.sh run-agy-engine.sh fake-gemini.sh fake-agy.sh; do
  cp "$HERE/tests/$f" "$SCRIPTS_DIR/tests/$f"
  chmod +x "$SCRIPTS_DIR/tests/$f" 2>/dev/null || true
done
echo "  installed: $SCRIPTS_DIR/tests/ (self-check suites)"

cp "$HERE/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "  installed: $SKILL_DIR/SKILL.md"

echo
if [ -s "$GEMINI_DIR/GEMINI.md" ]; then
  echo "NOTE: $GEMINI_DIR/GEMINI.md already exists and was NOT modified."
  echo "      Rules for the executor are in templates/GEMINI.md — merge them by hand."
else
  mkdir -p "$GEMINI_DIR"
  cp "$HERE/templates/GEMINI.md" "$GEMINI_DIR/GEMINI.md"
  echo "  installed: $GEMINI_DIR/GEMINI.md (executor rules)"
fi

echo
echo "Next steps"
echo "  1. Install an engine if needed:"
echo "     Antigravity CLI (account, no API key):  https://antigravity.google/download"
echo "     or Gemini CLI (API key):                npm i -g @google/gemini-cli"
echo "  2. Check the environment:      $SCRIPTS_DIR/gemini-task.sh doctor"
echo "  3. Run the self-check:         CLC_SCRIPTS=$SCRIPTS_DIR bash $SCRIPTS_DIR/tests/run-tests.sh"
echo "  4. Add permissions to $CLAUDE_DIR/settings.json — see docs/PERMISSIONS.md."
echo "     The installer does not touch settings.json on purpose."
echo
echo "Read docs/SECURITY.md before using this on a machine with real secrets."
echo "Running Claude love Codex too? Both install side by side; see docs/PORTING.md."
