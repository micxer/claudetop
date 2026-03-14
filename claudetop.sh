#!/bin/bash
# claudetop — htop for your Claude Code sessions
# https://github.com/liorwn/claudetop
#
# Real-time status line showing project context, token usage,
# cost insights, cache efficiency, and smart alerts.
#
# Environment variables:
#   CLAUDETOP_THEME          compact|minimal|full (default: full)
#   CLAUDETOP_DAILY_BUDGET   daily budget in USD (e.g., 50)
#   CLAUDETOP_TAG            tag for session tracking (e.g., "auth-refactor")
#
# Plugin system: drop executable scripts into ~/.claude/claudetop.d/
# Each plugin receives the session JSON on stdin and outputs a single
# formatted string (ANSI OK). Plugins run with a 1s timeout.

set -euo pipefail

THEME="${CLAUDETOP_THEME:-full}"
HISTORY_FILE="${HOME}/.claude/claudetop-history.jsonl"

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
HOUR=$(date +"%H")
if [ "$HOUR" -ge 22 ] || [ "$HOUR" -lt 6 ]; then
  TIME_FMT="${MAGENTA}${TIME_NOW}${RESET}"
else
  TIME_FMT="${DIM}${TIME_NOW}${RESET}"
fi

# --- Session tag ---
TAG_FMT=""
if [ -n "${CLAUDETOP_TAG:-}" ]; then
  TAG_FMT=" ${DIM}#${CLAUDETOP_TAG}${RESET}"
fi

# --- Cost estimates per model (cache-aware) ---
OPUS_COST=$(calc_cost   15     18.75        1.50       75)
SONNET_COST=$(calc_cost  3      3.75        0.30       15)
HAIKU_COST=$(calc_cost   0.80   1.00        0.08        4)

ACTUAL_COST_FMT=$(fmt_cost "$COST")

# Model estimates always prefixed with ~ (they're approximations)
OPUS_COST_FMT="~$(fmt_cost "$OPUS_COST")"
SONNET_COST_FMT="~$(fmt_cost "$SONNET_COST")"
HAIKU_COST_FMT="~$(fmt_cost "$HAIKU_COST")"

# Highlight current model + flag large divergence from actual
case "$MODEL_ID" in
  *opus*)
    OPUS_COST_FMT="${BOLD}${OPUS_COST_FMT}${RESET}${DIM}"
    # If actual > 3x estimate, snapshot is stale (compaction lost token history)
    if [ "$(echo "$OPUS_COST > 0 && $COST / $OPUS_COST > 3" | bc 2>/dev/null)" = "1" ]; then
      OPUS_COST_FMT="${BOLD}~$(fmt_cost "$OPUS_COST")${RESET}${DIM}${RED}*${RESET}${DIM}"
    fi
    ;;
  *sonnet*)
    SONNET_COST_FMT="${BOLD}${SONNET_COST_FMT}${RESET}${DIM}"
    if [ "$(echo "$SONNET_COST > 0 && $COST / $SONNET_COST > 3" | bc 2>/dev/null)" = "1" ]; then
      SONNET_COST_FMT="${BOLD}~$(fmt_cost "$SONNET_COST")${RESET}${DIM}${RED}*${RESET}${DIM}"
    fi
    ;;
  *haiku*)
    HAIKU_COST_FMT="${BOLD}${HAIKU_COST_FMT}${RESET}${DIM}"
    if [ "$(echo "$HAIKU_COST > 0 && $COST / $HAIKU_COST > 3" | bc 2>/dev/null)" = "1" ]; then
      HAIKU_COST_FMT="${BOLD}~$(fmt_cost "$HAIKU_COST")${RESET}${DIM}${RED}*${RESET}${DIM}"
    fi
    ;;
esac

IN_FMT=$(fmt_tokens "$INPUT_TOKENS")
OUT_FMT=$(fmt_tokens "$OUTPUT_TOKENS")
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

# --- Context composition ---
# Show input token breakdown: fresh vs cached vs output ratio
CTX_COMP=""
if [ "$TOTAL_INPUT" -gt 0 ]; then
  FRESH_PCT=$(echo "scale=0; $REGULAR_INPUT * 100 / $TOTAL_INPUT" | bc)
  WRITE_PCT=$(echo "scale=0; $CACHE_CREATE * 100 / $TOTAL_INPUT" | bc)
  READ_PCT=$CACHE_PCT
  # Output as % of total tokens (input + output)
  TOTAL_ALL=$((TOTAL_INPUT + OUTPUT_TOKENS))
  if [ "$TOTAL_ALL" -gt 0 ]; then
    OUT_PCT=$(echo "scale=0; $OUTPUT_TOKENS * 100 / $TOTAL_ALL" | bc)
    IN_PCT=$((100 - OUT_PCT))
    CTX_COMP="${DIM}in:${IN_PCT}%${RESET} ${DIM}out:${OUT_PCT}%${RESET}"
    # Show cache breakdown: fresh|write|read
    CTX_COMP="${CTX_COMP} ${DIM}(${RESET}${GRAY}fresh:${FRESH_PCT}%${RESET} ${GRAY}cwrite:${WRITE_PCT}%${RESET} ${GRAY}cread:${READ_PCT}%${RESET}${DIM})${RESET}"
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

# --- Daily budget + forecast (from history) ---
BUDGET_FMT=""
FORECAST_FMT=""
if [ -f "$HISTORY_FILE" ]; then
  TODAY=$(date +"%Y-%m-%d")
  # Sum today's completed sessions + current session cost (fast: grep + jq)
  TODAY_PAST=$(grep "\"$TODAY" "$HISTORY_FILE" 2>/dev/null | jq -s '[.[].cost_usd] | add // 0' 2>/dev/null) || TODAY_PAST=0
  TODAY_TOTAL=$(echo "scale=2; $TODAY_PAST + $COST" | bc)

  # Budget alert
  if [ -n "${CLAUDETOP_DAILY_BUDGET:-}" ]; then
    BUDGET_PCT=$(echo "scale=0; $TODAY_TOTAL * 100 / $CLAUDETOP_DAILY_BUDGET" | bc 2>/dev/null) || BUDGET_PCT=0
    BUDGET_LEFT=$(echo "scale=2; $CLAUDETOP_DAILY_BUDGET - $TODAY_TOTAL" | bc)
    if [ "$(echo "$BUDGET_PCT >= 100" | bc)" -eq 1 ]; then
      BUDGET_FMT="${RED}${BOLD}OVER BUDGET${RESET} ${DIM}(\$${TODAY_TOTAL}/\$${CLAUDETOP_DAILY_BUDGET})${RESET}"
    elif [ "$(echo "$BUDGET_PCT >= 80" | bc)" -eq 1 ]; then
      BUDGET_FMT="${YELLOW}budget: \$${BUDGET_LEFT} left${RESET}"
    fi
  fi

  # Monthly forecast — extrapolate from recent daily average
  # Use last 7 days of history for more stable estimate
  WEEK_AGO=$(date -v-7d +"%Y-%m-%d" 2>/dev/null || date -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || echo "")
  if [ -n "$WEEK_AGO" ]; then
    WEEK_COST=$(grep -E "\"(${WEEK_AGO}|$(date -v-6d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-5d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-4d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-3d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-2d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-1d +"%Y-%m-%d" 2>/dev/null || true)|${TODAY})" "$HISTORY_FILE" 2>/dev/null | jq -s '[.[].cost_usd] | add // 0' 2>/dev/null) || WEEK_COST=0
    # Count distinct days in the window
    DAYS_WITH_DATA=$(grep -E "\"(${WEEK_AGO}|$(date -v-6d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-5d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-4d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-3d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-2d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-1d +"%Y-%m-%d" 2>/dev/null || true)|${TODAY})" "$HISTORY_FILE" 2>/dev/null | jq -r '.timestamp[:10]' 2>/dev/null | sort -u | wc -l | tr -d ' ') || DAYS_WITH_DATA=0
    if [ "$DAYS_WITH_DATA" -gt 0 ]; then
      DAILY_AVG=$(echo "scale=2; $WEEK_COST / $DAYS_WITH_DATA" | bc)
      MONTHLY_EST=$(echo "scale=0; $DAILY_AVG * 30" | bc)
      if [ "$(echo "$MONTHLY_EST > 0" | bc)" -eq 1 ]; then
        FORECAST_FMT="${DIM}~\$${MONTHLY_EST}/mo${RESET}"
      fi
    fi
  fi
fi

# --- Plugin system ---
PLUGIN_DIR="${HOME}/.claude/claudetop.d"
PLUGIN_OUTPUT=""
if [ -d "$PLUGIN_DIR" ]; then
  for plugin in "$PLUGIN_DIR"/*; do
    [ -f "$plugin" ] && [ -x "$plugin" ] || continue
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
declare -a ALERTS

# Cost milestones
for THRESHOLD in 25 10 5; do
  if [ "$(echo "$COST >= $THRESHOLD" | bc)" -eq 1 ]; then
    ALERTS+=("${RED}${BOLD}\$${THRESHOLD} MARK${RESET}")
    break
  fi
done

# Budget alert
if [ -n "$BUDGET_FMT" ]; then
  ALERTS+=("$BUDGET_FMT")
fi

# Stale session
DURATION_HOURS=$(echo "scale=2; $DURATION_MS / 3600000" | bc)
if [ "$(echo "$DURATION_HOURS >= 2" | bc)" -eq 1 ] && [ "$CTX_USED" -ge 60 ]; then
  ALERTS+=("${YELLOW}CONSIDER FRESH SESSION${RESET}")
fi

# Cache collapse
DURATION_MIN=$((DURATION_MS / 60000))
if [ "$DURATION_MIN" -ge 5 ] && [ "$TOTAL_INPUT" -gt 0 ]; then
  if [ "$CACHE_PCT" -lt 20 ]; then
    ALERTS+=("${RED}LOW CACHE${RESET}")
  fi
fi

# Velocity spike
if [ -n "$VELOCITY" ] && [ "$(echo "$RATE >= 15" | bc)" -eq 1 ]; then
  ALERTS+=("${RED}BURN RATE${RESET}")
fi

# Output stall
if [ "$(echo "$COST >= 1" | bc)" -eq 1 ] && [ "$TOTAL_LINES" -eq 0 ]; then
  ALERTS+=("${YELLOW}SPINNING?${RESET}")
fi

# Model mismatch
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

# =============================================
# OUTPUT — Theme-aware rendering
# =============================================

if [ "$THEME" = "compact" ]; then
  # --- COMPACT: 1 line ---
  printf "%b " "$TIME_FMT"
  printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
  printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
  printf "  ${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf " %b" "$VELOCITY"
  fi
  printf "  %b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  printf "%b" "$TAG_FMT"
  if [ -n "$ALERT_STR" ]; then
    printf "  %b" "$ALERT_STR"
  fi
  echo ""

elif [ "$THEME" = "minimal" ]; then
  # --- MINIMAL: 2 lines ---
  # Line 1: project + model + duration + lines
  printf "%b  " "$TIME_FMT"
  printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
  if [ -n "$REL_PATH" ]; then
    printf "${DIM}%s${RESET}" "$REL_PATH"
  fi
  printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
  printf "  ${DIM}%s${RESET}" "$DUR_FMT"
  printf "%b" "$DELTA"
  printf "%b" "$TAG_FMT"
  echo ""

  # Line 2: cost + velocity + context + cache + alerts
  printf "${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf "  %b" "$VELOCITY"
  fi
  if [ -n "$FORECAST_FMT" ]; then
    printf "  %b" "$FORECAST_FMT"
  fi
  printf "  %b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  if [ -n "$CACHE_RATIO" ]; then
    printf "  ${DIM}cache:${RESET} %b" "$CACHE_RATIO"
  fi
  if [ -n "$ALERT_STR" ]; then
    printf "  %b" "$ALERT_STR"
  fi
  echo ""

else
  # --- FULL: 3-5 lines (default) ---

  # Line 1: Time + Project + folder + model + duration + line delta + tag
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
  printf "%b" "$TAG_FMT"
  echo ""

  # Line 2: Tokens + context bar + compact warning + cost + velocity + forecast
  printf "${DIM}%s in / %s out  ${RESET}" "$IN_FMT" "$OUT_FMT"
  printf "%b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  printf "  ${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf "  %b" "$VELOCITY"
  fi
  if [ -n "$FORECAST_FMT" ]; then
    printf "  %b" "$FORECAST_FMT"
  fi
  echo ""

  # Line 3: Cache + efficiency + model costs + context composition
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

  # Line 4 (optional): Context composition (when there's data)
  if [ -n "$CTX_COMP" ]; then
    printf "%b\n" "$CTX_COMP"
  fi

  # Line 5 (optional): Alerts + Plugin outputs
  LINE5=""
  if [ -n "$ALERT_STR" ]; then
    LINE5="$ALERT_STR"
  fi
  if [ -n "$PLUGIN_OUTPUT" ]; then
    if [ -n "$LINE5" ]; then
      LINE5="${LINE5}  ${DIM}|${RESET}  ${PLUGIN_OUTPUT}"
    else
      LINE5="$PLUGIN_OUTPUT"
    fi
  fi
  if [ -n "$LINE5" ]; then
    printf "%b\n" "$LINE5"
  fi
fi
