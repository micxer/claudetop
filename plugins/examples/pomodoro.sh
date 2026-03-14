#!/bin/bash
# Plugin: Pomodoro timer
# Start: touch ~/.claude/pomodoro-start
# Stop:  rm ~/.claude/pomodoro-start

POMO_FILE="$HOME/.claude/pomodoro-start"
POMO_MINUTES=25

[ -f "$POMO_FILE" ] || exit 0

START=$(stat -f%m "$POMO_FILE" 2>/dev/null || stat -c%Y "$POMO_FILE" 2>/dev/null) || exit 0
NOW=$(date +%s)
ELAPSED=$(( (NOW - START) / 60 ))
REMAINING=$((POMO_MINUTES - ELAPSED))

if [ "$REMAINING" -le 0 ]; then
  printf "\033[31mBREAK TIME\033[0m"
elif [ "$REMAINING" -le 5 ]; then
  printf "\033[33m%dm left\033[0m" "$REMAINING"
else
  printf "\033[32m%dm left\033[0m" "$REMAINING"
fi
