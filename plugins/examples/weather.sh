#!/bin/bash
# Plugin: Current weather (cached 30min)
# Change LOCATION to your city

LOCATION="${CLAUDETOP_WEATHER_LOCATION:-New York}"
CACHE="/tmp/claudetop-weather"
CACHE_AGE=1800

if [ -f "$CACHE" ]; then
  AGE=$(( $(date +%s) - $(stat -f%m "$CACHE" 2>/dev/null || stat -c%Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$AGE" -lt "$CACHE_AGE" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

WEATHER=$(curl -sf "wttr.in/${LOCATION}?format=%c%t" 2>/dev/null) || exit 0
[ -z "$WEATHER" ] && exit 0

OUTPUT=$(printf "\033[90m%s\033[0m" "$WEATHER")
echo "$OUTPUT" > "$CACHE"
echo "$OUTPUT"
