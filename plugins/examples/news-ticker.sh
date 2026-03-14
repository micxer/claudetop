#!/bin/bash
# Plugin: Hacker News top story (cached 15min)

CACHE="/tmp/claudetop-hn-cache"
CACHE_AGE=900

if [ -f "$CACHE" ]; then
  AGE=$(( $(date +%s) - $(stat -f%m "$CACHE" 2>/dev/null || stat -c%Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$AGE" -lt "$CACHE_AGE" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

TOP_ID=$(curl -sf "https://hacker-news.firebaseio.com/v0/topstories.json" | jq '.[0]') || exit 0
TITLE=$(curl -sf "https://hacker-news.firebaseio.com/v0/item/${TOP_ID}.json" | jq -r '.title // empty') || exit 0
[ -z "$TITLE" ] && exit 0
[ ${#TITLE} -gt 50 ] && TITLE="${TITLE:0:47}..."

OUTPUT=$(printf "\033[90mHN:\033[0m %s" "$TITLE")
echo "$OUTPUT" > "$CACHE"
echo "$OUTPUT"
