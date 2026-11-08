#!/usr/bin/env bash

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
EFFORT_LEVEL=$(echo "$input" | jq -r '.effort.level // "__ABSENT__"')
SESSION_ID_RAW=$(echo "$input" | jq -r '.session_id // ""')
SESSION_ID=$(echo "$SESSION_ID_RAW" | tr -dc 'a-zA-Z0-9' | cut -c1-24)
EXCEEDS_200K=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# New-schema fields (all gated; absent fields fall back to empty/zero)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
THINKING=$(echo "$input" | jq -r '.thinking.enabled // false')
API_MS=$(echo "$input" | jq -r '.cost.total_api_duration_ms // 0')
PR_NUMBER=$(echo "$input" | jq -r '.pr.number // ""')
PR_REVIEW=$(echo "$input" | jq -r '.pr.review_state // ""')
WORKTREE_NAME=$(echo "$input" | jq -r '.worktree.name // ""')
WORKTREE_BRANCH=$(echo "$input" | jq -r '.worktree.branch // ""')
CC_VERSION=$(echo "$input" | jq -r '.version // ""')
# Present only while this CLI is a client viewing a remote session.
REMOTE_SESSION=$(echo "$input" | jq -r '.remote.session_id // ""')
FAST_MODE=$(echo "$input" | jq -r '.fast_mode // false')
# Prompt cache state. Claude Code omits .prompt_cache until the first request;
# caching_observed stays false when nothing has been cached yet.
PC_OBSERVED=$(echo "$input" | jq -r '.prompt_cache.caching_observed // false')
PC_WARM=$(echo "$input" | jq -r '.prompt_cache.warm // false')
PC_EXPIRES=$(echo "$input" | jq -r '.prompt_cache.expires_at // 0')

# Session token usage (In/Out reflect the current context window, not session
# cumulative totals, since Claude Code v2.1.132)
TOK_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOK_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

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

# Format window size: 1000000 -> 1M, 200000 -> 200k, else raw
fmt_window() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    awk "BEGIN {printf \"%gM\", $n/1000000}"
  elif [ "$n" -ge 1000 ]; then
    awk "BEGIN {printf \"%gk\", $n/1000}"
  else
    echo "$n"
  fi
}

# Repeat a (possibly multibyte) glyph `n` times. Portable: avoids
# `tr ' ' '<glyph>'`, which maps by byte and corrupts the multibyte bar glyphs
# on GNU coreutils — only BSD tr happened to render them. Bars are <=30 chars,
# so the loop is cheap.
repeat_glyph() {
  local n=$1 g=$2 out=''
  while [ "$n" -gt 0 ]; do out="$out$g"; n=$(( n - 1 )); done
  printf '%s' "$out"
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
CYAN="\033[36m"
MAGENTA="\033[35m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RED="\033[31m"
BRIGHT_RED="\033[1;91m"
PURPLE="\033[38;5;135m"
GOLD="\033[38;5;214m"
ORANGE="\033[38;5;202m"
BRIGHT_WHITE="\033[97m"
DIM="\033[2m"
# Black on cyan background: the session line's remote badges.
BADGE="\033[30;46m"

# Limit bar (5h / 7d) color: smooth truecolor gradient.
# 0-50%: dark gray (50,50,50) linearly up to white (255,255,255).
# 50-70%: white through tinted green to pure green (0,255,0).
#   G stays 255; R and B drop 255->0 across the 20% window together.
# 70-80%: green to yellow (255,255,0). R rises 0->255; G=255; B=0.
# 80-90%: yellow to red (255,0,0). R=255; G drops 255->0; B=0.
# >90%: solid red.
limit_bar_color() {
  local pct=$1 r g b v
  if [ "$pct" -lt 50 ]; then
    v=$(( 50 + (255 - 50) * pct / 50 ))
    r=$v; g=$v; b=$v
  elif [ "$pct" -le 70 ]; then
    r=$(( 255 - (pct - 50) * 255 / 20 ))
    g=255
    b=$(( 255 - (pct - 50) * 255 / 20 ))
  elif [ "$pct" -le 80 ]; then
    r=$(( (pct - 70) * 255 / 10 ))
    g=255
    b=0
  elif [ "$pct" -le 90 ]; then
    r=255
    g=$(( 255 - (pct - 80) * 255 / 10 ))
    b=0
  else
    r=255; g=0; b=0
  fi
  printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}
SESSION_BAR_COLOR=$(limit_bar_color "$SESSION_PCT")
WEEKLY_BAR_COLOR=$(limit_bar_color "$WEEKLY_PCT")

# Context window bar color: smooth truecolor gradient.
# 0-60%: dark gray (50,50,50) linearly up to white (255,255,255).
# 60-70%: white through yellow to red. R stays 255;
#   G drops 255->0 across the 10% window; B drops 255->0 over the first 5%.
# >70%: solid red.
if [ "$USED" -lt 60 ]; then
  CONTEXT_V=$(( 50 + (255 - 50) * USED / 60 ))
  CONTEXT_R=$CONTEXT_V; CONTEXT_G=$CONTEXT_V; CONTEXT_B=$CONTEXT_V
elif [ "$USED" -le 70 ]; then
  CONTEXT_R=255
  CONTEXT_G=$(( 255 - (USED - 60) * 255 / 10 ))
  if [ "$USED" -le 65 ]; then
    CONTEXT_B=$(( 255 - (USED - 60) * 255 / 5 ))
  else
    CONTEXT_B=0
  fi
else
  CONTEXT_R=255; CONTEXT_G=0; CONTEXT_B=0
fi
CONTEXT_BAR_COLOR="\033[38;2;${CONTEXT_R};${CONTEXT_G};${CONTEXT_B}m"

# Progress bar of `w` cells at 1/3-cell resolution (floored): full cells █,
# then one boundary cell whose shade density carries the remainder
# (░ = 0, ▒ = 1/3, ▓ = 2/3), then ░ up to the width.
shade_bar() {
  local pct=$1 w=$2 units full rem out
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  units=$(( pct * w * 3 / 100 ))
  full=$(( units / 3 ))
  rem=$(( units % 3 ))
  out=$(repeat_glyph "$full" '█')
  if [ "$full" -lt "$w" ]; then
    case "$rem" in
      1) out="${out}▒" ;;
      2) out="${out}▓" ;;
      *) out="${out}░" ;;
    esac
    out="${out}$(repeat_glyph $(( w - full - 1 )) '░')"
  fi
  printf '%s' "$out"
}

# Context window and 5h / 7d rate limit progress bars (10 cells each)
CONTEXT_BAR=$(shade_bar "$USED" 10)
SESSION_BAR=$(shade_bar "$SESSION_PCT" 10)
WEEKLY_BAR=$(shade_bar "$WEEKLY_PCT" 10)

# Duration
MINS=$(( DURATION_MS / 60000 ))
SECS=$(( (DURATION_MS % 60000) / 1000 ))
DURATION="${MINS}m ${SECS}s"

# Model color by family
case "$MODEL" in
  *Fable*|*Mythos*) MODEL_COLOR="$GOLD" ;;
  *Opus*)           MODEL_COLOR="$PURPLE" ;;
  *Haiku*)          MODEL_COLOR="$GREEN" ;;
  *)                MODEL_COLOR="$CYAN" ;;
esac

# Effort level color (aligned with Claude Code's /effort picker:
# low=warning(yellow), medium=success(green), high=permission(blue),
# xhigh=autoAccept(magenta), max=rainbow→bright white fallback).
# Source is the stdin `.effort.level` field. Claude Code emits one of
# low/medium/high/xhigh/max (it normalizes `ultracode` to `xhigh` upstream) and
# OMITS the field entirely for models without effort support (e.g. Haiku 4.5) —
# that absence is shown as a dim "—" placeholder. A value that is present but
# unrecognized is genuine schema drift and is surfaced loudly as bright-red
# "unknown" — never silently defaulted — so the drift stays visible.
case "$EFFORT_LEVEL" in
  low)        EFFORT_COLOR="$YELLOW" ;;
  medium)     EFFORT_COLOR="$GREEN" ;;
  high)       EFFORT_COLOR="$BLUE" ;;
  xhigh)      EFFORT_COLOR="$MAGENTA" ;;
  max)        EFFORT_COLOR="$BRIGHT_WHITE" ;;
  __ABSENT__) EFFORT_COLOR="$DIM"; EFFORT_LEVEL="—" ;;
  *)          EFFORT_COLOR="$BRIGHT_RED"; EFFORT_LEVEL="unknown" ;;
esac

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

# Shell-style info from powerline theme (user@host, dir, git branch, time)
CWD=$(echo "$input" | jq -r '.workspace.current_dir // ""')
[ -z "$CWD" ] && CWD=$(echo "$input" | jq -r '.cwd // ""')
SHORT_DIR=$(basename "$CWD")
[ "$CWD" = "$HOME" ] && SHORT_DIR="~"

GIT_BRANCH=""
GIT_DIFF_FMT=""
if [ -d "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || true)
  GIT_NUMSTAT=$(git -C "$CWD" --no-optional-locks diff --numstat 2>/dev/null)
  if [ -n "$GIT_NUMSTAT" ]; then
    GIT_ADD=$(echo "$GIT_NUMSTAT" | awk '{a+=$1} END {print a+0}')
    GIT_DEL=$(echo "$GIT_NUMSTAT" | awk '{d+=$2} END {print d+0}')
    GIT_DIFF_FMT="${GREEN}+${GIT_ADD}${RESET} ${RED}-${GIT_DEL}${RESET}"
  fi
fi

COMPACT_COUNT=0
if [ -n "$SESSION_ID" ]; then
  COMPACT_CACHE="/tmp/claude-compacts-${SESSION_ID}.json"
  [ -f "$COMPACT_CACHE" ] && COMPACT_COUNT=$(jq -r '.count // 0' "$COMPACT_CACHE" 2>/dev/null || echo 0)
fi

NOW_TIME=$(date "+%H:%M:%S")

# Account this session is authenticated as, i.e. whose quota it is spending.
# Out-of-band (the statusline payload carries no account field), published per
# session by hooks/account-monitor.sh, which resolves it from the credential
# this session actually uses.
#
# Deliberately NOT read from ~/.claude.json: that file's `.oauthAccount` is a
# single machine-global slot shared by every Claude Code surface, rewritten only
# by a full profile fetch that is gated behind a 24h TTL, so it can name a
# different account than the one in use. See SPEC.md -> Account attribution.
#
#   file absent         -> hook not wired: no label at all (pre-hook layout)
#   displayName present -> render the name
#   displayName null    -> resolution failed: render a loud `?` rather than
#                          silently attributing this session's usage to nobody
ACCOUNT_NAME=""
ACCOUNT_UNRESOLVED=0
ACCOUNT_CACHE=""
[ -n "$SESSION_ID" ] && ACCOUNT_CACHE="/tmp/claude-account-${SESSION_ID}.json"
if [ -n "$ACCOUNT_CACHE" ] && [ -f "$ACCOUNT_CACHE" ]; then
  ACCOUNT_NAME=$(jq -r '.displayName // empty' "$ACCOUNT_CACHE" 2>/dev/null)
  [ -z "$ACCOUNT_NAME" ] && { ACCOUNT_NAME="?"; ACCOUNT_UNRESOLVED=1; }
fi

# Agent name + [ref], as ListAgents prints them. Claude Code keeps a per-process
# registry at <config dir>/sessions/<pid>.json (internal, undocumented); the
# entry whose sessionId matches this payload carries the agent name and the
# messaging socket path, and the ref is sha256("session:<socket path>")[0:6]
# (format as of Claude Code 2.1.317). Without a matching entry, fall back to
# the payload's .session_name (the /rename or auto-generated title) with no ref;
# with neither, the name is omitted. The name renders in the default foreground
# only when the registry says it was set explicitly (nameSource "user", e.g.
# /rename); derived names and the session_name fallback render dim.
#
# The same entry carries bridgeSessionId: a "session_..." id while Remote
# Control is attached to this session, null or absent otherwise (Claude Code
# 2.1.319). It is read from the newest matching entry regardless of whether
# that entry has a name. The CLAUDE_CODE_BRIDGE_SESSION_ID env var is not used:
# a child process started from a bridged session inherits it, so it is not
# matched to this session's id.
sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else cat >/dev/null; fi
}
AGENT_NAME=""
AGENT_REF=""
AGENT_SOURCE=""
BRIDGE_SESSION=""
SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
if [ -n "$SESSION_ID_RAW" ] && [ -d "$SESSIONS_DIR" ]; then
  # grep narrows to the matching file(s) first, so one malformed registry file
  # elsewhere cannot break the jq parse. Newest entry wins if several claim it.
  AGENT_FILES=()
  while IFS= read -r f; do AGENT_FILES+=("$f"); done < <(grep -lF "\"$SESSION_ID_RAW\"" "$SESSIONS_DIR"/*.json 2>/dev/null)
  if [ "${#AGENT_FILES[@]}" -gt 0 ]; then
    AGENT_ROW=$(jq -rs --arg id "$SESSION_ID_RAW" '
      def str: if type == "string" then gsub("[\r\n]"; "") else "" end;
      [.[] | objects | select(.sessionId == $id)] as $all
      | ([$all[] | select((.name // "") | type == "string" and . != "")] | sort_by(.updatedAt // 0) | last // {}) as $n
      | ($all | sort_by(.updatedAt // 0) | last // {}) as $b
      | ($n.name // "" | str), ($n.messagingSocketPath // "" | str), ($n.nameSource // "" | str),
        ($b.bridgeSessionId // "" | str)' "${AGENT_FILES[@]}" 2>/dev/null)
    { IFS= read -r AGENT_NAME; IFS= read -r AGENT_SOCK; IFS= read -r AGENT_SOURCE; IFS= read -r BRIDGE_SESSION; } <<< "$AGENT_ROW"
    if [ -n "$AGENT_NAME" ] && [ -n "$AGENT_SOCK" ]; then
      AGENT_REF=$(printf 'session:%s' "$AGENT_SOCK" | sha256_hex | cut -c1-6)
    fi
  fi
fi
[ -z "$AGENT_NAME" ] && AGENT_NAME=$(echo "$input" | jq -r '.session_name // ""')
# Names are user-settable via /rename; keep backslashes literal under echo -e.
AGENT_NAME=${AGENT_NAME//\\/\\\\}

# Shared dim label column. Width is 7 by default (Model/Context/Tokens/Stats/
# Limits), widened to the account name length when present so line 1's account
# label and the labels below it line up in a single column. pad_label at width 7
# reproduces the original hardcoded labels exactly, so absent-account output is
# unchanged.
LABEL_W=7
[ "${#ACCOUNT_NAME}" -gt "$LABEL_W" ] && LABEL_W=${#ACCOUNT_NAME}
pad_label() { printf "%-${LABEL_W}s" "$1"; }

GIT_LINE=""
[ -n "$SHORT_DIR" ] && GIT_LINE="${CYAN}${SHORT_DIR}${RESET}"
[ -n "$GIT_BRANCH" ] && GIT_LINE="${GIT_LINE} ${DIM}⬠${RESET} ${GREEN}${GIT_BRANCH}${RESET}"
[ -n "$GIT_DIFF_FMT" ] && GIT_LINE="${GIT_LINE} ${DIM}·${RESET} ${GIT_DIFF_FMT}"

# Pull request status (gated on .pr presence), colored by review_state
if [ -n "$PR_NUMBER" ]; then
  case "$PR_REVIEW" in
    approved)          PR_FMT="${GREEN}✓ PR #${PR_NUMBER}${RESET}" ;;
    changes_requested) PR_FMT="${RED}✗ PR #${PR_NUMBER}${RESET}" ;;
    pending)           PR_FMT="${YELLOW}● PR #${PR_NUMBER}${RESET}" ;;
    draft)             PR_FMT="${DIM}○ PR #${PR_NUMBER}${RESET}" ;;
    *)                 PR_FMT="${CYAN}PR #${PR_NUMBER}${RESET}" ;;
  esac
  GIT_LINE="${GIT_LINE} ${DIM}·${RESET} ${PR_FMT}"
fi

# Worktree indicator (gated on --worktree session)
if [ -n "$WORKTREE_NAME" ]; then
  WORKTREE_FMT="${MAGENTA}⎇ ${WORKTREE_NAME}${RESET}"
  # Append @branch only when it differs from the worktree name (avoid "x@x")
  [ -n "$WORKTREE_BRANCH" ] && [ "$WORKTREE_BRANCH" != "$WORKTREE_NAME" ] && WORKTREE_FMT="${WORKTREE_FMT}${DIM}@${WORKTREE_BRANCH}${RESET}"
  GIT_LINE="${GIT_LINE} ${DIM}·${RESET} ${WORKTREE_FMT}"
fi

# Prepend the logged-in account as line 1's dim label (gated), aligned into the
# same label column as Model/Context/... below. When the account is absent, line 1
# stays flush-left as before.
if [ -n "$ACCOUNT_NAME" ]; then
  ACCOUNT_COLOR="$DIM"
  [ "$ACCOUNT_UNRESOLVED" = 1 ] && ACCOUNT_COLOR="$YELLOW"
  LINE1="${ACCOUNT_COLOR}$(pad_label "$ACCOUNT_NAME")${RESET} ${GIT_LINE}"
else
  LINE1="$GIT_LINE"
fi
[ -n "$LINE1" ] && echo -e "$LINE1"

# Model line: model + effort + markers, then session cost, duration, API time.
MODEL_LINE="${DIM}$(pad_label Model)${RESET} ${MODEL_COLOR}${MODEL}${RESET}  ${EFFORT_COLOR}${EFFORT_LEVEL}${RESET}"
# Extended-thinking indicator (gated on thinking.enabled)
[ "$THINKING" = "true" ] && MODEL_LINE="${MODEL_LINE} ${CYAN}✦${RESET}"
# Fast mode indicator (gated on fast_mode); same glyph Claude Code uses
[ "$FAST_MODE" = "true" ] && MODEL_LINE="${MODEL_LINE} ${ORANGE}↯${RESET}"
MODEL_LINE="${MODEL_LINE} ${DIM}·${RESET} ${DIM}Cost${RESET} ${COST_FMT} ${DIM}·${RESET} ${DIM}Dur${RESET} ${DURATION}"
# True API wait time (gated on cost.total_api_duration_ms)
if [ "$API_MS" -gt 0 ]; then
  API_MINS=$(( API_MS / 60000 ))
  API_SECS=$(( (API_MS % 60000) / 1000 ))
  MODEL_LINE="${MODEL_LINE} ${DIM}·${RESET} ${DIM}API${RESET} ${API_MINS}m ${API_SECS}s"
fi
echo -e "$MODEL_LINE"

# Context line: window size, bar, compact count, then the token counts.
CONTEXT_LINE="${DIM}$(pad_label Context)${RESET} "
[ "$CTX_SIZE" -gt 0 ] && CONTEXT_LINE="${CONTEXT_LINE}${DIM}$(fmt_window "$CTX_SIZE")${RESET} "
CONTEXT_LINE="${CONTEXT_LINE}${CONTEXT_BAR_COLOR}${CONTEXT_BAR}${RESET} ${CONTEXT_BAR_COLOR}${USED}%${RESET}"
[ "$COMPACT_COUNT" -gt 0 ] && CONTEXT_LINE="${CONTEXT_LINE} ${DIM}·${RESET} ${DIM}compact ${COMPACT_COUNT}x${RESET}"
CONTEXT_LINE="${CONTEXT_LINE} ${DIM}·${RESET} "
[ "$EXCEEDS_200K" = "true" ] && CONTEXT_LINE="${CONTEXT_LINE}${RED}⚠ 200k+${RESET} ${DIM}·${RESET} "
CONTEXT_LINE="${CONTEXT_LINE}${DIM}In${RESET} ${TOK_IN_FMT} ${DIM}·${RESET} ${DIM}Out${RESET} ${TOK_OUT_FMT} ${DIM}·${RESET} ${DIM}Cache${RESET} ${CACHE_PCT}%"
# Prompt cache expiry (gated on caching_observed): `→HH:MM` while warm, a
# yellow `cold` once expired (the next request re-writes the whole context).
# Warmth is re-checked against NOW in case the payload is older than expiry.
if [ "$PC_OBSERVED" = "true" ]; then
  if [ "$PC_WARM" = "true" ] && [ "$PC_EXPIRES" -gt "$NOW" ]; then
    PC_EXPIRES_TIME=$(date -r "$PC_EXPIRES" "+%H:%M" 2>/dev/null || date -d "@$PC_EXPIRES" "+%H:%M" 2>/dev/null)
    CONTEXT_LINE="${CONTEXT_LINE} ${DIM}→${PC_EXPIRES_TIME}${RESET}"
  else
    CONTEXT_LINE="${CONTEXT_LINE} ${YELLOW}cold${RESET}"
  fi
fi
echo -e "$CONTEXT_LINE"

echo -e "${DIM}$(pad_label Limits)${RESET} ${DIM}5H${RESET} ${DIM}${SESSION_BAR_COLOR}${SESSION_BAR}${RESET} ${SESSION_BAR_COLOR}${SESSION_PCT}%${RESET} ${DIM}↺${RESET} ${SESSION_RESET_FMT} ${DIM}·${RESET} ${DIM}7D${RESET} ${DIM}${WEEKLY_BAR_COLOR}${WEEKLY_BAR}${RESET} ${WEEKLY_BAR_COLOR}${WEEKLY_PCT}%${RESET} ${DIM}↺${RESET} ${WEEKLY_RESET_FMT}"

# Last line: remote badges, agent name [ref], session id, Claude Code CLI
# version, render time. Each part is gated. The version reflects the process
# actually running this session, so it tracks the real version even across
# --resume.
LAST_LINE=""
add_last() { LAST_LINE="${LAST_LINE:+${LAST_LINE} ${DIM}·${RESET} }$1"; }
# Remote badges lead the line, space-separated (the background delimits them,
# so no `·`): Remote Control attached to this session (registry
# bridgeSessionId), and this CLI driving a session that runs elsewhere
# (payload .remote).
BADGES=""
[ -n "$BRIDGE_SESSION" ] && BADGES="${BADGE} ⇄ RC ${RESET}"
[ -n "$REMOTE_SESSION" ] && BADGES="${BADGES:+${BADGES} }${BADGE} ⏿ remote session ${RESET}"
if [ -n "$AGENT_NAME" ]; then
  if [ "$AGENT_SOURCE" = "user" ]; then
    AGENT_FMT="${AGENT_NAME}"
  else
    AGENT_FMT="${DIM}${AGENT_NAME}${RESET}"
  fi
  [ -n "$AGENT_REF" ] && AGENT_FMT="${AGENT_FMT} ${DIM}[${AGENT_REF}]${RESET}"
  add_last "$AGENT_FMT"
fi
[ -n "$SESSION_ID_RAW" ] && add_last "${DIM}${SESSION_ID_RAW}${RESET}"
[ -n "$CC_VERSION" ] && add_last "${DIM}v${CC_VERSION}${RESET}"
add_last "${DIM}${NOW_TIME}${RESET}"

# Append ~/.claude backup drift indicator on the same line so line count stays
# constant (no UI jump). Flag file is written by claude-backup.sh git.
DRIFT_FLAG="$HOME/.claude/system/backup/.drift-status"
if [ -f "$DRIFT_FLAG" ]; then
  DRIFT_TEXT=$(cat "$DRIFT_FLAG" 2>/dev/null)
  if [ -n "$DRIFT_TEXT" ]; then
    LAST_LINE="${LAST_LINE} ${DIM}·${RESET} ${YELLOW}⚠ ${DRIFT_TEXT}${RESET}"
  fi
fi
echo -e "${BADGES:+${BADGES} }${LAST_LINE}"
