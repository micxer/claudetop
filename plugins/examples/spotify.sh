#!/bin/bash
# Plugin: Currently playing on Spotify (macOS only)

STATE=$(osascript -e 'tell application "Spotify" to player state as string' 2>/dev/null) || exit 0
[ "$STATE" != "playing" ] && exit 0

TRACK=$(osascript -e 'tell application "Spotify" to name of current track as string' 2>/dev/null) || exit 0
ARTIST=$(osascript -e 'tell application "Spotify" to artist of current track as string' 2>/dev/null) || exit 0
[ -z "$TRACK" ] && exit 0

DISPLAY="${ARTIST} - ${TRACK}"
[ ${#DISPLAY} -gt 40 ] && DISPLAY="${DISPLAY:0:37}..."

printf "\033[32m♫\033[0m \033[90m%s\033[0m" "$DISPLAY"
