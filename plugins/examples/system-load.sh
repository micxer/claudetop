#!/bin/bash
# Plugin: CPU load average (macOS + Linux)

if [ "$(uname)" = "Darwin" ]; then
  LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}') || exit 0
  CORES=$(sysctl -n hw.ncpu 2>/dev/null) || exit 0
else
  LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || exit 0
  CORES=$(nproc 2>/dev/null) || exit 0
fi

THRESHOLD_WARN=$(echo "scale=1; $CORES * 0.5" | bc)
THRESHOLD_CRIT=$CORES

if [ "$(echo "$LOAD >= $THRESHOLD_CRIT" | bc)" -eq 1 ]; then
  LOAD_COLOR="\033[31m"
elif [ "$(echo "$LOAD >= $THRESHOLD_WARN" | bc)" -eq 1 ]; then
  LOAD_COLOR="\033[33m"
else
  LOAD_COLOR="\033[32m"
fi

printf "%b%s\033[0m\033[90m load\033[0m" "$LOAD_COLOR" "$LOAD"
