#!/bin/bash
# session-end.sh — Claude Code SessionEnd hook
# Appends one JSONL record per session to ~/.claude/claudetop-history.jsonl
#
# The SessionEnd payload only contains: session_id, transcript_path, cwd,
# hook_event_name, reason. All session data (tokens, model, cost) must be
# extracted from the transcript JSONL file.

set -euo pipefail

HISTORY_FILE="$HOME/.claude/claudetop-history.jsonl"
PRICING_FILE="$HOME/.claude/claudetop-pricing.json"
JSON=$(cat)

# Extract fields from SessionEnd payload
TRANSCRIPT=$(echo "$JSON" | jq -r '.transcript_path // ""')
CWD=$(echo "$JSON" | jq -r '.cwd // ""')
SID=$(echo "$JSON" | jq -r '.session_id // ""')

# Detect git branch
GIT_BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  GIT_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || true
fi

# Defaults
MODEL=""
INPUT_TOKENS=0
OUTPUT_TOKENS=0
REGULAR_INPUT=0
CC_5MIN=0
CC_1HR=0
CC_TOTAL=0
CACHE_READ=0
DURATION_MS=0
COST_USD=0
LINES_ADDED=0
LINES_REMOVED=0

# Parse transcript file for session data
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  STATS=$(jq -s '
    (map(select(.type == "assistant") | .message.model // empty) | first // "") as $model |
    (map(select(.type == "assistant" and .message.usage != null) | .message.usage)) as $usages |
    ($usages | {
      regular:  (map(.input_tokens // 0) | add // 0),
      output:   (map(.output_tokens // 0) | add // 0),
      cc_5min:  (map(.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0),
      cc_1hr:   (map(.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0),
      cc_total: (map(.cache_creation_input_tokens // 0) | add // 0),
      cr:       (map(.cache_read_input_tokens // 0) | add // 0)
    }) as $tok |
    # Lines changed from Write/Edit tool calls
    ([.[] | select(.type == "assistant") | .message.content // [] | .[] |
      select(.type == "tool_use" and (.name == "Write" or .name == "Edit")) |
      if .name == "Write" then
        {added: ((.input.content // "") | split("\n") | length), removed: 0}
      elif .name == "Edit" then
        {added: ((.input.new_string // "") | split("\n") | length),
         removed: ((.input.old_string // "") | split("\n") | length)}
      else {added: 0, removed: 0} end
    ]) as $edits |
    {
      lines_added: ([$edits[].added] | add // 0),
      lines_removed: ([$edits[].removed] | add // 0)
    } as $lines |
    (map(select(.timestamp != null) | .timestamp) | sort |
      if length > 1 then {first: first, last: last}
      else {first: null, last: null} end) as $ts |
    {
      model:    $model,
      regular:  $tok.regular,
      output:   $tok.output,
      cc_5min:  $tok.cc_5min,
      cc_1hr:   $tok.cc_1hr,
      cc_total: $tok.cc_total,
      cr:       $tok.cr,
      la:       $lines.lines_added,
      lr:       $lines.lines_removed,
      first_ts: $ts.first,
      last_ts:  $ts.last
    }
  ' "$TRANSCRIPT" 2>/dev/null) || STATS=""

  if [ -n "$STATS" ]; then
    MODEL=$(echo "$STATS" | jq -r '.model')
    REGULAR_INPUT=$(echo "$STATS" | jq '.regular')
    OUTPUT_TOKENS=$(echo "$STATS" | jq '.output')
    CC_5MIN=$(echo "$STATS" | jq '.cc_5min')
    CC_1HR=$(echo "$STATS" | jq '.cc_1hr')
    CC_TOTAL=$(echo "$STATS" | jq '.cc_total')
    CACHE_READ=$(echo "$STATS" | jq '.cr')
    INPUT_TOKENS=$((REGULAR_INPUT + CC_TOTAL + CACHE_READ))
    LINES_ADDED=$(echo "$STATS" | jq '.la')
    LINES_REMOVED=$(echo "$STATS" | jq '.lr')

    FIRST=$(echo "$STATS" | jq -r '.first_ts // ""')
    LAST=$(echo "$STATS" | jq -r '.last_ts // ""')

    # Compute duration
    if [ -n "$FIRST" ] && [ -n "$LAST" ] && [ "$FIRST" != "null" ] && [ "$LAST" != "null" ]; then
      DURATION_MS=$(python3 -c "
from datetime import datetime
a=datetime.fromisoformat('${FIRST}'.replace('Z','+00:00'))
b=datetime.fromisoformat('${LAST}'.replace('Z','+00:00'))
print(int((b-a).total_seconds()*1000))
" 2>/dev/null) || DURATION_MS=0
    fi

    # Compute cost with per-tier cache pricing
    if [ -f "$PRICING_FILE" ] && [ -n "$MODEL" ]; then
      case "$MODEL" in
        *opus*)   TIER="opus" ;;
        *sonnet*) TIER="sonnet" ;;
        *haiku*)  TIER="haiku" ;;
        *)        TIER="" ;;
      esac
      if [ -n "$TIER" ]; then
        COST_USD=$(jq \
          --arg t "$TIER" \
          --argjson r "$REGULAR_INPUT" \
          --argjson cc5 "$CC_5MIN" \
          --argjson cc1 "$CC_1HR" \
          --argjson cr "$CACHE_READ" \
          --argjson o "$OUTPUT_TOKENS" \
          '.models[$t] as $p |
           ($r*$p.input
            + $cc5*($p.cache_write_5min // ($p.input*1.25))
            + $cc1*($p.cache_write_1hr // ($p.input*2))
            + $cr*$p.cache_read
            + $o*$p.output)
           / 1000000 | . * 10000 | round / 10000' \
          "$PRICING_FILE" 2>/dev/null) || COST_USD=0
      fi
    fi
  fi
fi

# Write history record
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sid "$SID" \
  --arg proj "$(basename "${CWD:-unknown}")" \
  --arg pdir "$CWD" \
  --arg model "$MODEL" \
  --argjson dur "$DURATION_MS" \
  --argjson cost "$COST_USD" \
  --argjson in "$INPUT_TOKENS" \
  --argjson out "$OUTPUT_TOKENS" \
  --argjson la "$LINES_ADDED" \
  --argjson lr "$LINES_REMOVED" \
  --argjson ctx 0 \
  --arg tag "${CLAUDETOP_TAG:-}" \
  --arg branch "$GIT_BRANCH" \
  '{
    timestamp: $ts, session_id: $sid, project: $proj, project_dir: $pdir,
    model: $model, duration_ms: $dur, cost_usd: $cost,
    input_tokens: $in, output_tokens: $out,
    lines_added: $la, lines_removed: $lr, context_used_pct: $ctx,
    tag: $tag, branch: $branch
  }' >> "$HISTORY_FILE"

# Signal THIS session's watcher to reset terminal and exit
# Find session ID via ITERM_SESSION_ID or parent TTY
SESSION_ID="${ITERM_SESSION_ID:-}"
TTY_MAP="$HOME/.claude/claudetop-iterm-ttys"
if [ -z "$SESSION_ID" ] && [ -f "$TTY_MAP" ]; then
  PARENT_TTY=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
  if [ -n "$PARENT_TTY" ] && [ "$PARENT_TTY" != "??" ]; then
    SESSION_ID=$(grep "=/dev/${PARENT_TTY}$" "$TTY_MAP" 2>/dev/null | head -1 | cut -d= -f1)
  fi
fi
if [ -n "$SESSION_ID" ]; then
  sf="$HOME/.claude/claudetop-iterm-state.${SESSION_ID}"
  [ -f "$sf" ] && {
    echo "iterm_session=${SESSION_ID}"
    echo "timestamp=$(date +%s)"
    echo "status=ended"
    echo "bgcolor=default"
    echo "modes=all"
  } > "$sf"
fi
