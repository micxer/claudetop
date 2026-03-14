#!/bin/bash
# Plugin: Show current git branch + dirty status

CWD=$(echo "$(cat)" | jq -r '.cwd // ""')
[ -z "$CWD" ] && exit 0

cd "$CWD" 2>/dev/null || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
DIRTY=""
if ! git diff --quiet HEAD 2>/dev/null; then
  DIRTY="\033[33m*\033[0m"
fi

printf "\033[35m%s\033[0m%b" "$BRANCH" "$DIRTY"
