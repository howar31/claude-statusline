#!/usr/bin/env bash

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Session token usage
TOK_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOK_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
TOK_TOTAL=$(( TOK_IN + TOK_OUT ))
if [ "$TOK_TOTAL" -ge 1000 ]; then
  TOK_FMT=$(awk "BEGIN {printf \"%.1fk\", $TOK_TOTAL/1000}")
else
  TOK_FMT="${TOK_TOTAL}"
fi

# Current session (5-hour) rate limit
SESSION_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' | cut -d. -f1)
SESSION_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
NOW=$(date +%s)
SESSION_SECS_LEFT=$(( SESSION_RESET - NOW ))
if [ "$SESSION_SECS_LEFT" -le 0 ]; then
  SESSION_RESET_FMT="now"
else
  SESSION_RESET_MINS=$(( SESSION_SECS_LEFT / 60 ))
  if [ "$SESSION_RESET_MINS" -ge 60 ]; then
    SESSION_RESET_HRS=$(( SESSION_RESET_MINS / 60 ))
    SESSION_RESET_TIME=$(date -r "$SESSION_RESET" "+%H:%M" 2>/dev/null || date -d "@$SESSION_RESET" "+%H:%M" 2>/dev/null)
    SESSION_RESET_FMT="${SESSION_RESET_HRS}h (${SESSION_RESET_TIME})"
  else
    SESSION_RESET_TIME=$(date -r "$SESSION_RESET" "+%H:%M" 2>/dev/null || date -d "@$SESSION_RESET" "+%H:%M" 2>/dev/null)
    SESSION_RESET_FMT="${SESSION_RESET_MINS}m (${SESSION_RESET_TIME})"
  fi
fi

# Weekly (7-day) rate limit
WEEKLY_PCT=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0' | cut -d. -f1)
WEEKLY_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')
WEEKLY_SECS_LEFT=$(( WEEKLY_RESET - NOW ))
if [ "$WEEKLY_SECS_LEFT" -le 0 ]; then
  WEEKLY_RESET_FMT="now"
elif [ "$WEEKLY_SECS_LEFT" -ge 86400 ]; then
  WEEKLY_RESET_DAYS=$(( WEEKLY_SECS_LEFT / 86400 ))
  WEEKLY_RESET_TIME=$(date -r "$WEEKLY_RESET" "+%m/%d %H:%M" 2>/dev/null || date -d "@$WEEKLY_RESET" "+%m/%d %H:%M" 2>/dev/null)
  WEEKLY_RESET_FMT="${WEEKLY_RESET_DAYS}d (${WEEKLY_RESET_TIME})"
else
  WEEKLY_RESET_HRS=$(( WEEKLY_SECS_LEFT / 3600 ))
  WEEKLY_RESET_TIME=$(date -r "$WEEKLY_RESET" "+%H:%M" 2>/dev/null || date -d "@$WEEKLY_RESET" "+%H:%M" 2>/dev/null)
  WEEKLY_RESET_FMT="${WEEKLY_RESET_HRS}h (${WEEKLY_RESET_TIME})"
fi

# Cache token usage
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_CREATE=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')

# Format helper: display as Xk if >= 1000, else raw number
fmt_tok() {
  local n=$1
  if [ "$n" -ge 1000 ]; then
    awk "BEGIN {printf \"%.1fk\", $n/1000}"
  else
    echo "$n"
  fi
}

TOK_IN_FMT=$(fmt_tok "$TOK_IN")
TOK_OUT_FMT=$(fmt_tok "$TOK_OUT")

# Cache hit rate percentage
CACHE_TOTAL=$(( CACHE_READ + CACHE_CREATE ))
if [ "$CACHE_TOTAL" -gt 0 ]; then
  CACHE_PCT=$(awk "BEGIN {printf \"%d\", $CACHE_READ * 100 / $CACHE_TOTAL}")
else
  CACHE_PCT=0
fi

# Colors
RESET="\033[0m"
BOLD="\033[1m"
CYAN="\033[36m"
MAGENTA="\033[35m"
GREEN="\033[32m"
YELLOW="\033[33m"
ORANGE="\033[38;5;208m"
BLUE="\033[34m"
RED="\033[31m"
DIM="\033[2m"

# Session/Weekly color
if [ "$SESSION_PCT" -gt 80 ]; then
  SESSION_COLOR="$RED"
elif [ "$SESSION_PCT" -gt 60 ]; then
  SESSION_COLOR="$YELLOW"
else
  SESSION_COLOR="$GREEN"
fi

if [ "$WEEKLY_PCT" -gt 90 ]; then
  WEEKLY_COLOR="$RED"
elif [ "$WEEKLY_PCT" -gt 70 ]; then
  WEEKLY_COLOR="$YELLOW"
else
  WEEKLY_COLOR="$GREEN"
fi

# Context window bar color
if [ "$USED" -gt 85 ]; then
  CONTEXT_BAR_COLOR="$RED"
elif [ "$USED" -gt 70 ]; then
  CONTEXT_BAR_COLOR="$YELLOW"
else
  CONTEXT_BAR_COLOR="$GREEN"
fi

# Context window progress bar
FILLED=$(( USED * 20 / 100))
EMPTY=$(( 20 - FILLED ))
CONTEXT_BAR=$(printf "%${FILLED}s" | tr ' ' '█')$(printf "%${EMPTY}s" | tr ' ' '░')

# Duration
MINS=$(( DURATION_MS / 60000 ))
SECS=$(( (DURATION_MS % 60000) / 1000 ))
DURATION="${MINS}m ${SECS}s"

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

# Shell-style info from powerline theme (user@host, dir, git branch, time)
CWD=$(echo "$input" | jq -r '.workspace.current_dir // ""')
[ -z "$CWD" ] && CWD=$(echo "$input" | jq -r '.cwd // ""')
SHORT_DIR=$(basename "$CWD")
[ "$CWD" = "$HOME" ] && SHORT_DIR="~"

GIT_BRANCH=""
if [ -d "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || true)
fi

NOW_TIME=$(date "+%H:%M:%S")
NOW_DATE=$(date "+%Y-%m-%d")
WHOAMI=$(whoami)
HOST_SHORT=$(hostname -s)

printf "${BLUE}${WHOAMI}${RESET}${DIM}@${RESET}${MAGENTA}${HOST_SHORT}${RESET} ${DIM}|${RESET} ${CYAN}${SHORT_DIR}${RESET}"
if [ -n "$GIT_BRANCH" ]; then
  printf " ${DIM}⬠${RESET} ${GREEN}${GIT_BRANCH}${RESET}"
fi
printf " ${DIM}|${RESET} ${DIM}${NOW_TIME} ${NOW_DATE}${RESET}\n"

echo -e "${CYAN}$MODEL${RESET} ${DIM}|${RESET} ${DIM}${CONTEXT_BAR_COLOR}${CONTEXT_BAR}${RESET} ${CONTEXT_BAR_COLOR}${USED}%${RESET} ${DIM}|${RESET} ${DIM}In ${RESET}${TOK_IN_FMT} ${DIM}|${RESET} ${DIM}Out ${RESET}${TOK_OUT_FMT} ${DIM}|${RESET} ${DIM}Cache ${RESET}${CACHE_PCT}%"
echo -e "${DIM}Cost${RESET} ${COST_FMT} ${DIM}|${RESET} ${DIM}Dur${RESET} ${DURATION} ${DIM}|${RESET} ${DIM}5H ${RESET}${SESSION_COLOR}${SESSION_PCT}%${RESET} ${DIM}↺${RESET} ${SESSION_RESET_FMT} ${DIM}|${RESET} ${DIM}7D ${RESET}${WEEKLY_COLOR}${WEEKLY_PCT}%${RESET} ${DIM}↺${RESET} ${WEEKLY_RESET_FMT}"
