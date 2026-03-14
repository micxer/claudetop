#!/bin/bash
# claudetop — htop for your Claude Code sessions
# https://github.com/liorwn/claudetop
#
# Real-time status line showing project context, token usage,
# cost insights, cache efficiency, and smart alerts.
#
# Plugin system: drop executable scripts into ~/.claude/claudetop.d/
# Each plugin receives the session JSON on stdin and outputs a single
# formatted string (ANSI OK). Plugins run with a 1s timeout.

set -euo pipefail

# Read JSON from stdin
JSON=$(cat)

# Extract fields with jq (fallback to defaults if missing)
PROJECT_DIR=$(echo "$JSON" | jq -r '.workspace.project_dir // .cwd // "unknown"')
CWD=$(echo "$JSON" | jq -r '.cwd // "unknown"')
MODEL_NAME=$(echo "$JSON" | jq -r '.model.display_name // "unknown"')
MODEL_ID=$(echo "$JSON" | jq -r '.model.id // "unknown"')

# Token counts
INPUT_TOKENS=$(echo "$JSON" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$JSON" | jq -r '.context_window.total_output_tokens // 0')
CTX_USED=$(echo "$JSON" | jq -r '.context_window.used_percentage // 0')
CACHE_READ=$(echo "$JSON" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_CREATE=$(echo "$JSON" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
REGULAR_INPUT=$(echo "$JSON" | jq -r '.context_window.current_usage.input_tokens // 0')

# Cost & duration
COST=$(echo "$JSON" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$JSON" | jq -r '.cost.total_duration_ms // 0')
LINES_ADDED=$(echo "$JSON" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$JSON" | jq -r '.cost.total_lines_removed // 0')

# --- Formatting helpers ---

shorten_path() {
  echo "$1" | sed "s|$HOME|~|"
}

fmt_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc)"
  elif [ "$n" -ge 1000 ]; then
    printf "%.1fK" "$(echo "scale=1; $n / 1000" | bc)"
  else
    echo "$n"
  fi
}

fmt_duration() {
  local ms=$1
  local secs=$((ms / 1000))
  if [ "$secs" -ge 3600 ]; then
    printf "%dh %dm" $((secs / 3600)) $(((secs % 3600) / 60))
  elif [ "$secs" -ge 60 ]; then
    printf "%dm %ds" $((secs / 60)) $((secs % 60))
  else
    printf "%ds" "$secs"
  fi
}

# Cache-aware cost estimate per model
# current_usage gives the cache breakdown for THIS turn only.
# We extrapolate that ratio across cumulative total_input_tokens.
# Pricing per MTok: [input, cache_write, cache_read, output]
#   Opus:   $15,   $18.75,  $1.50,  $75
#   Sonnet: $3,    $3.75,   $0.30,  $15
#   Haiku:  $0.80, $1.00,   $0.08,  $4

# Estimate cumulative cache breakdown from current turn's ratio
CURRENT_TOTAL_IN=$((CACHE_READ + CACHE_CREATE + REGULAR_INPUT))
if [ "$CURRENT_TOTAL_IN" -gt 0 ]; then
  EST_CACHE_READ=$(echo "scale=0; $INPUT_TOKENS * $CACHE_READ / $CURRENT_TOTAL_IN" | bc)
  EST_CACHE_CREATE=$(echo "scale=0; $INPUT_TOKENS * $CACHE_CREATE / $CURRENT_TOTAL_IN" | bc)
  EST_REGULAR=$(echo "scale=0; $INPUT_TOKENS * $REGULAR_INPUT / $CURRENT_TOTAL_IN" | bc)
else
  EST_CACHE_READ=0
  EST_CACHE_CREATE=0
  EST_REGULAR=$INPUT_TOKENS
fi

calc_cost() {
  local in_price=$1 cache_write_price=$2 cache_read_price=$3 out_price=$4
  echo "scale=4; ($EST_REGULAR * $in_price / 1000000) + ($EST_CACHE_CREATE * $cache_write_price / 1000000) + ($EST_CACHE_READ * $cache_read_price / 1000000) + ($OUTPUT_TOKENS * $out_price / 1000000)" | bc
}

fmt_cost() {
  local c=$1
  if [ "$(echo "$c >= 1" | bc)" -eq 1 ]; then
    printf "\$%.2f" "$c"
  else
    printf "\$%.3f" "$c"
  fi
}

# --- Extract project name ---
PROJECT_NAME=$(basename "$PROJECT_DIR")
SHORT_CWD=$(shorten_path "$CWD")
SHORT_PROJECT=$(shorten_path "$PROJECT_DIR")

REL_PATH=""
if [ "$CWD" != "$PROJECT_DIR" ] && [[ "$CWD" == "$PROJECT_DIR"* ]]; then
  REL_PATH="${CWD#$PROJECT_DIR}"
fi

# --- ANSI Colors ---
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
BLUE="\033[34m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
MAGENTA="\033[35m"
RED="\033[31m"
WHITE="\033[37m"
GRAY="\033[90m"

# --- Time of day ---
TIME_NOW=$(date +"%H:%M")
# Dim after 10pm or before 6am as a gentle "it's late" nudge
HOUR=$(date +"%H")
if [ "$HOUR" -ge 22 ] || [ "$HOUR" -lt 6 ]; then
  TIME_FMT="${MAGENTA}${TIME_NOW}${RESET}"
else
  TIME_FMT="${DIM}${TIME_NOW}${RESET}"
fi

# --- Cost estimates per model (cache-aware) ---
#                     input  cache_write  cache_read  output
OPUS_COST=$(calc_cost   15     18.75        1.50       75)
SONNET_COST=$(calc_cost  3      3.75        0.30       15)
HAIKU_COST=$(calc_cost   0.80   1.00        0.08        4)

ACTUAL_COST_FMT=$(fmt_cost "$COST")
OPUS_COST_FMT=$(fmt_cost "$OPUS_COST")
SONNET_COST_FMT=$(fmt_cost "$SONNET_COST")
HAIKU_COST_FMT=$(fmt_cost "$HAIKU_COST")

# Highlight current model's cost
case "$MODEL_ID" in
  *opus*) OPUS_COST_FMT="${BOLD}${OPUS_COST_FMT}${RESET}${DIM}" ;;
  *sonnet*) SONNET_COST_FMT="${BOLD}${SONNET_COST_FMT}${RESET}${DIM}" ;;
  *haiku*) HAIKU_COST_FMT="${BOLD}${HAIKU_COST_FMT}${RESET}${DIM}" ;;
esac

# Format tokens
IN_FMT=$(fmt_tokens "$INPUT_TOKENS")
OUT_FMT=$(fmt_tokens "$OUTPUT_TOKENS")

# Duration
DUR_FMT=$(fmt_duration "$DURATION_MS")

# --- Cost velocity ($/hr) ---
VELOCITY=""
RATE=0
if [ "$DURATION_MS" -gt 30000 ]; then
  HOURS=$(echo "scale=6; $DURATION_MS / 3600000" | bc)
  RATE=$(echo "scale=2; $COST / $HOURS" | bc)
  if [ "$(echo "$RATE >= 8" | bc)" -eq 1 ]; then
    VELOCITY="${RED}\$${RATE}/hr${RESET}"
  elif [ "$(echo "$RATE >= 3" | bc)" -eq 1 ]; then
    VELOCITY="${YELLOW}\$${RATE}/hr${RESET}"
  else
    VELOCITY="${GREEN}\$${RATE}/hr${RESET}"
  fi
fi

# --- Cache hit ratio ---
CACHE_RATIO=""
CACHE_PCT=0
TOTAL_INPUT=$((CACHE_READ + CACHE_CREATE + REGULAR_INPUT))
if [ "$TOTAL_INPUT" -gt 0 ]; then
  CACHE_PCT=$(echo "scale=0; $CACHE_READ * 100 / $TOTAL_INPUT" | bc)
  if [ "$CACHE_PCT" -ge 60 ]; then
    CACHE_RATIO="${GREEN}${CACHE_PCT}%${RESET}"
  elif [ "$CACHE_PCT" -ge 30 ]; then
    CACHE_RATIO="${YELLOW}${CACHE_PCT}%${RESET}"
  else
    CACHE_RATIO="${RED}${CACHE_PCT}%${RESET}"
  fi
fi

# --- Output efficiency (cost per line changed) ---
EFFICIENCY=""
CPL=0
TOTAL_LINES=$((LINES_ADDED + LINES_REMOVED))
if [ "$TOTAL_LINES" -gt 0 ]; then
  CPL=$(echo "scale=4; $COST / $TOTAL_LINES" | bc)
  if [ "$(echo "$CPL >= 0.1" | bc)" -eq 1 ]; then
    CPL_FMT=$(printf "\$%.2f" "$CPL")
  else
    CPL_FMT=$(printf "\$%.3f" "$CPL")
  fi
  if [ "$(echo "$CPL >= 0.05" | bc)" -eq 1 ]; then
    EFFICIENCY="${RED}${CPL_FMT}/line${RESET}"
  elif [ "$(echo "$CPL >= 0.01" | bc)" -eq 1 ]; then
    EFFICIENCY="${YELLOW}${CPL_FMT}/line${RESET}"
  else
    EFFICIENCY="${GREEN}${CPL_FMT}/line${RESET}"
  fi
fi

# --- Compact warning ---
COMPACT_WARN=""
if [ "$CTX_USED" -ge 80 ]; then
  COMPACT_WARN=" ${RED}${BOLD}COMPACT SOON${RESET}"
elif [ "$CTX_USED" -ge 70 ]; then
  COMPACT_WARN=" ${YELLOW}~$(echo "scale=0; (100 - $CTX_USED) * 2" | bc)% left${RESET}"
fi

# --- Context bar (visual) ---
CTX_BAR=""
BAR_LEN=10
FILLED=$((CTX_USED * BAR_LEN / 100))
for ((i=0; i<BAR_LEN; i++)); do
  if [ $i -lt $FILLED ]; then
    if [ "$CTX_USED" -ge 80 ]; then
      CTX_BAR="${CTX_BAR}\033[31m█${RESET}"
    elif [ "$CTX_USED" -ge 50 ]; then
      CTX_BAR="${CTX_BAR}\033[33m█${RESET}"
    else
      CTX_BAR="${CTX_BAR}\033[32m█${RESET}"
    fi
  else
    CTX_BAR="${CTX_BAR}\033[90m░${RESET}"
  fi
done

# --- Line delta ---
DELTA=""
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
  DELTA=" ${DIM}${GREEN}+${LINES_ADDED}${RESET}${DIM}/${YELLOW}-${LINES_REMOVED}${RESET}"
fi

# --- Plugin system ---
# Scripts in ~/.claude/claudetop.d/ receive JSON on stdin, output one string each
# They run with a 1s timeout to avoid blocking the status line
PLUGIN_DIR="${HOME}/.claude/claudetop.d"
PLUGIN_OUTPUT=""
if [ -d "$PLUGIN_DIR" ]; then
  for plugin in "$PLUGIN_DIR"/*; do
    [ -f "$plugin" ] && [ -x "$plugin" ] || continue
    # Run plugin, capture output, ignore failures
    # Use perl alarm for timeout (works on macOS without coreutils)
    result=$(echo "$JSON" | perl -e 'alarm 1; exec @ARGV' "$plugin" 2>/dev/null) || true
    if [ -n "$result" ]; then
      if [ -n "$PLUGIN_OUTPUT" ]; then
        PLUGIN_OUTPUT="${PLUGIN_OUTPUT}  ${DIM}|${RESET}  ${result}"
      else
        PLUGIN_OUTPUT="$result"
      fi
    fi
  done
fi

# --- Alerts ---
# Stateless alerts derived from current JSON snapshot. Collected into an array.
declare -a ALERTS

# 1. Session cost milestones
for THRESHOLD in 25 10 5; do
  if [ "$(echo "$COST >= $THRESHOLD" | bc)" -eq 1 ]; then
    ALERTS+=("${RED}${BOLD}\$${THRESHOLD} MARK${RESET}")
    break  # Only show highest crossed threshold
  fi
done

# 2. Stale session — long duration + high context = diminishing returns
DURATION_HOURS=$(echo "scale=2; $DURATION_MS / 3600000" | bc)
if [ "$(echo "$DURATION_HOURS >= 2" | bc)" -eq 1 ] && [ "$CTX_USED" -ge 60 ]; then
  ALERTS+=("${YELLOW}CONSIDER FRESH SESSION${RESET}")
fi

# 3. Cache collapse — low cache when it should be high (session > 5min, cache < 20%)
DURATION_MIN=$((DURATION_MS / 60000))
if [ "$DURATION_MIN" -ge 5 ] && [ "$TOTAL_INPUT" -gt 0 ]; then
  if [ "$CACHE_PCT" -lt 20 ]; then
    ALERTS+=("${RED}LOW CACHE${RESET}")
  fi
fi

# 4. Velocity spike — burn rate > $15/hr is excessive
if [ -n "$VELOCITY" ] && [ "$(echo "$RATE >= 15" | bc)" -eq 1 ]; then
  ALERTS+=("${RED}BURN RATE${RESET}")
fi

# 5. Output stall — spending money but no code output (cost > $1, zero lines)
if [ "$(echo "$COST >= 1" | bc)" -eq 1 ] && [ "$TOTAL_LINES" -eq 0 ]; then
  ALERTS+=("${YELLOW}SPINNING?${RESET}")
fi

# 6. Model mismatch — expensive per line on Opus, suggest switching
if [ "$TOTAL_LINES" -gt 0 ] && [ "$(echo "$CPL >= 0.05" | bc)" -eq 1 ]; then
  case "$MODEL_ID" in
    *opus*) ALERTS+=("${CYAN}TRY /fast${RESET}") ;;
  esac
fi

# Build alert string
ALERT_STR=""
for alert in "${ALERTS[@]+"${ALERTS[@]}"}"; do
  if [ -n "$ALERT_STR" ]; then
    ALERT_STR="${ALERT_STR}  ${DIM}|${RESET}  ${alert}"
  else
    ALERT_STR="$alert"
  fi
done

# --- Output ---
# Line 1: Time + Project + folder + model + duration + line delta
printf "%b  " "$TIME_FMT"
printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
if [ -n "$REL_PATH" ]; then
  printf "${DIM}%s${RESET}" "$REL_PATH"
else
  printf " ${DIM}%s${RESET}" "$SHORT_PROJECT"
fi
printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
printf "  ${DIM}%s${RESET}" "$DUR_FMT"
printf "%b" "$DELTA"
echo ""

# Line 2: Tokens + context bar + compact warning + cost + velocity
printf "${DIM}%s in / %s out  ${RESET}" "$IN_FMT" "$OUT_FMT"
printf "%b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
printf "%b" "$COMPACT_WARN"
printf "  ${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
if [ -n "$VELOCITY" ]; then
  printf "  %b" "$VELOCITY"
fi
echo ""

# Line 3: Cache + efficiency + model costs
printf "${DIM}cache:${RESET} "
if [ -n "$CACHE_RATIO" ]; then
  printf "%b" "$CACHE_RATIO"
else
  printf "${GRAY}--${RESET}"
fi
if [ -n "$EFFICIENCY" ]; then
  printf "  ${DIM}efficiency:${RESET} %b" "$EFFICIENCY"
fi
printf "${DIM}  opus:%b  sonnet:%b  haiku:%b${RESET}" "$OPUS_COST_FMT" "$SONNET_COST_FMT" "$HAIKU_COST_FMT"
echo ""

# Line 4 (optional): Alerts + Plugin outputs
LINE4=""
if [ -n "$ALERT_STR" ]; then
  LINE4="$ALERT_STR"
fi
if [ -n "$PLUGIN_OUTPUT" ]; then
  if [ -n "$LINE4" ]; then
    LINE4="${LINE4}  ${DIM}|${RESET}  ${PLUGIN_OUTPUT}"
  else
    LINE4="$PLUGIN_OUTPUT"
  fi
fi
if [ -n "$LINE4" ]; then
  printf "%b\n" "$LINE4"
fi
