#!/usr/bin/env bash
#
# swatches.sh — regenerate the source ANSI for the three README graphics.
#
#   docs/model-effort-colors.png   <- "model"   (model family + effort level)
#   docs/context-bar-gradient.png  <- "context" (context bar color gradient)
#   docs/limit-bar-gradient.png    <- "limit"   (5h/7d limit bar color gradient)
#
# This script DUPLICATES the palette and gradient formulas from statusline.sh
# so the docs can be regenerated consistently. It is NOT sourced by the
# renderer — statusline.sh stays a single drop-in file. If you change a palette
# constant or a gradient formula in statusline.sh, update it here too (same
# spirit as the "change one, change both" conventions in CLAUDE.md).
#
# It does NOT emit PNGs (no reliable headless terminal->image here). Render a
# section in a 24-bit truecolor terminal, screenshot it, and save over the
# matching docs/*.png.
#
# Usage:
#   ./docs/swatches.sh           # print all three sections
#   ./docs/swatches.sh model     # model family + effort swatch
#   ./docs/swatches.sh context   # context bar gradient
#   ./docs/swatches.sh limit     # 5h/7d limit bar gradient

# --- Palette (mirror of statusline.sh) ---------------------------------------
GOLD="\033[38;5;214m"     # Fable / Mythos
PURPLE="\033[38;5;135m"   # Opus
GREEN="\033[32m"          # Haiku / medium effort
CYAN="\033[36m"           # Sonnet / fallback
YELLOW="\033[33m"         # low effort
BLUE="\033[34m"           # high effort
MAGENTA="\033[35m"        # xhigh effort
BRIGHT_WHITE="\033[97m"   # max effort
BRIGHT_RED="\033[1;91m"   # unknown effort (schema drift)
DIM="\033[2m"
RESET="\033[0m"

# --- Gradient color formulas (mirror of statusline.sh) -----------------------

# Context bar: gray(50)->white@60% -> orange@65% -> red@70%+.
context_bar_color() {
  local pct=$1 r g b v
  if [ "$pct" -lt 60 ]; then
    v=$(( 50 + (255 - 50) * pct / 60 ))
    r=$v; g=$v; b=$v
  elif [ "$pct" -le 70 ]; then
    r=255
    g=$(( 255 - (pct - 60) * 255 / 10 ))
    if [ "$pct" -le 65 ]; then
      b=$(( 255 - (pct - 60) * 255 / 5 ))
    else
      b=0
    fi
  else
    r=255; g=0; b=0
  fi
  printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

# Limit bar: gray(50)->white@50% -> green@70% -> yellow@80% -> red@90%+.
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

# Render statusline's proportional bar (filled = pct of width) in one color.
render_bar() {  # width pct color_escape
  local width=$1 pct=$2 color=$3 filled empty bar i
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  # Concatenate the glyphs rather than `tr ' ' '<glyph>'` — tr maps by byte and
  # corrupts the multibyte bar glyphs on GNU coreutils (mirrors statusline.sh).
  bar=''
  for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
  for (( i = 0; i < empty;  i++ )); do bar="${bar}░"; done
  printf '%b%s%b' "$color" "$bar" "$RESET"
}

# --- Sections ----------------------------------------------------------------

model_effort_swatch() {
  printf '\n'
  printf "${DIM}  (statusline.sh model family + effort level colors)${RESET}\n\n"
  printf "\033[1m  Model family${RESET}\n\n"
  printf "  ${GOLD}███  %-18s${RESET} ${DIM}%s${RESET}\n" 'Claude Fable 5'    '256-color 214 (gold)  ← Mythos-class, above Opus'
  printf "  ${PURPLE}███  %-18s${RESET} ${DIM}%s${RESET}\n" 'Claude Opus 4.8'   '256-color 135 (purple)'
  printf "  ${GREEN}███  %-18s${RESET} ${DIM}%s${RESET}\n"  'Claude Haiku 4.5'  'ANSI 32 (green)'
  printf "  ${CYAN}███  %-18s${RESET} ${DIM}%s${RESET}\n"   'Claude Sonnet 4.6' 'ANSI 36 (cyan)  — also the fallback for any other model'
  printf '\n'
  printf "\033[1m  Effort level${RESET}\n\n"
  printf "  ${YELLOW}███  %-9s${RESET} ${DIM}%s${RESET}\n"       'low'     'ANSI 33 (yellow)'
  printf "  ${GREEN}███  %-9s${RESET} ${DIM}%s${RESET}\n"        'medium'  'ANSI 32 (green)'
  printf "  ${BLUE}███  %-9s${RESET} ${DIM}%s${RESET}\n"         'high'    'ANSI 34 (blue)'
  printf "  ${MAGENTA}███  %-9s${RESET} ${DIM}%s${RESET}\n"      'xhigh'   'ANSI 35 (magenta)'
  printf "  ${BRIGHT_WHITE}███  %-9s${RESET} ${DIM}%s${RESET}\n" 'max'     'ANSI 97 (bright white)'
  printf "  ${DIM}███  %-9s${RESET} ${DIM}%s${RESET}\n"          '—'       'dim — model has no effort support'
  printf "  ${BRIGHT_RED}███  %-9s${RESET} ${DIM}%s${RESET}\n"   'unknown' 'bright red — present but unrecognized (schema drift)'
  printf '\n'
}

context_gradient() {
  local pcts=(0 10 20 30 40 50 60 65 70 80 90) p note
  printf '\n'
  printf "\033[1m  Context bar${RESET} ${DIM}(30 chars; gray → white@60%% → orange@65%% → red@70%%+)${RESET}\n\n"
  for p in "${pcts[@]}"; do
    printf '  %3d%%  ' "$p"
    render_bar 30 "$p" "$(context_bar_color "$p")"
    note=''
    case $p in 60) note='white' ;; 65) note='orange' ;; 70) note='red' ;; esac
    [ -n "$note" ] && printf "  ${DIM}%s${RESET}" "$note"
    printf '\n'
  done
  printf '\n'
}

limit_gradient() {
  local pcts=(5 10 20 30 40 50 60 70 80 90 100) p note
  printf '\n'
  printf "\033[1m  Limit bar${RESET} ${DIM}(20 chars; gray → white@50%% → green@70%% → yellow@80%% → red@90%%+)${RESET}\n\n"
  for p in "${pcts[@]}"; do
    printf '  %3d%%  ' "$p"
    render_bar 20 "$p" "$(limit_bar_color "$p")"
    note=''
    case $p in 50) note='white' ;; 70) note='green' ;; 80) note='yellow' ;; 90) note='red' ;; esac
    [ -n "$note" ] && printf "  ${DIM}%s${RESET}" "$note"
    printf '\n'
  done
  printf "\n  ${DIM}(statusline.sh dims these bars; shown here at full intensity to expose the colors)${RESET}\n\n"
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-all}" in
  model)   model_effort_swatch ;;
  context) context_gradient ;;
  limit)   limit_gradient ;;
  all)     model_effort_swatch; context_gradient; limit_gradient ;;
  *) echo "usage: $0 [model|context|limit|all]" >&2; exit 2 ;;
esac
