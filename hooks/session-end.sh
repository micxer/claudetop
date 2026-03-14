#!/bin/bash
# session-end.sh — Claude Code SessionEnd hook
# Appends one JSONL record per session to ~/.claude/claudetop-history.jsonl
#
# Register in ~/.claude/settings.json:
#   "hooks": { "SessionEnd": [{ "type": "command", "command": "/path/to/session-end.sh" }] }

set -euo pipefail

HISTORY_FILE="$HOME/.claude/claudetop-history.jsonl"
JSON=$(cat)

# Detect git branch from project directory
PROJECT_DIR=$(echo "$JSON" | jq -r '.workspace.project_dir // .cwd // ""')
GIT_BRANCH=""
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.git" ]; then
  GIT_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || true
fi

jq -c \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tag "${CLAUDETOP_TAG:-}" \
  --arg branch "$GIT_BRANCH" \
  '{
    timestamp:       $timestamp,
    session_id:      (.session_id // ""),
    project:         ((.workspace.project_dir // .cwd // "") | split("/") | last),
    project_dir:     (.workspace.project_dir // .cwd // ""),
    model:           (.model.id // ""),
    duration_ms:     (.cost.total_duration_ms // 0),
    cost_usd:        (.cost.total_cost_usd // 0),
    input_tokens:    (.context_window.total_input_tokens // 0),
    output_tokens:   (.context_window.total_output_tokens // 0),
    lines_added:     (.cost.total_lines_added // 0),
    lines_removed:   (.cost.total_lines_removed // 0),
    context_used_pct:(.context_window.used_percentage // 0),
    tag:             $tag,
    branch:          $branch
  }' <<< "$JSON" >> "$HISTORY_FILE"
