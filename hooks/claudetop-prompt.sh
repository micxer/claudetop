#!/bin/bash
# claudetop-prompt.sh — Sets iTerm2 background to black when user submits
# Writes directly to TTY + updates state file

[ -n "${CLAUDETOP_ITERM:-}" ] || exit 0

TTY_MAP="$HOME/.claude/claudetop-iterm-ttys"
SESSION_ID="${ITERM_SESSION_ID:-}"

# If no ITERM_SESSION_ID in env, find it from parent process TTY
if [ -z "$SESSION_ID" ] && [ -f "$TTY_MAP" ]; then
  PARENT_TTY=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
  if [ -n "$PARENT_TTY" ]; then
    PARENT_TTY="/dev/${PARENT_TTY}"
    SESSION_ID=$(grep "=${PARENT_TTY}$" "$TTY_MAP" 2>/dev/null | head -1 | cut -d= -f1)
  fi
fi

[ -n "$SESSION_ID" ] || exit 0

# Write directly to TTY for instant black
if [ -f "$TTY_MAP" ]; then
  MY_TTY=$(grep "^${SESSION_ID}=" "$TTY_MAP" 2>/dev/null | tail -1 | cut -d= -f2-)
  if [ -n "$MY_TTY" ] && [ -w "$MY_TTY" ]; then
    printf "\033]1337;SetColors=bg=000000\007" > "$MY_TTY"
  fi
fi

# Update state file
STATE_FILE="$HOME/.claude/claudetop-iterm-state.${SESSION_ID}"
[ -f "$STATE_FILE" ] || exit 0
if grep -q "^bgcolor=" "$STATE_FILE" 2>/dev/null; then
  sed -i "" "s/^bgcolor=.*/bgcolor=000000/" "$STATE_FILE"
else
  echo "bgcolor=000000" >> "$STATE_FILE"
fi
sed -i "" "s/^timestamp=.*/timestamp=$(date +%s)/" "$STATE_FILE"
