#!/usr/bin/env bash
#
# advisor-monitor.sh — track this session's advisor model and advisor call
# count and publish them for statusline.sh.
#
# Why this exists: the statusline payload has no advisor field; both facts are
# only recorded in the session transcript, and the one that sets the model can
# be anywhere in it (usually near the start). Reading the whole transcript on
# every statusline refresh grows with the file, so the state is kept here
# instead: a Stop hook (once per completed reply) reads only the bytes appended
# since its last run and folds them into a per-session state file.
#
# Advisor model (Claude Code 2.1.322, internal and undocumented): when the
# advisor tool is added to or removed from the session, Claude Code writes an
# attachment entry
#   {"type":"attachment","attachment":{"type":"advisor_tool","available":true,
#    "model":"claude-fable-5-2","toolChange":"add"},...}
# (`available:false` with toolChange "remove" when it goes away). The latest
# such attachment is the current state: its model when available is true, ""
# otherwise. The per-entry top-level `advisorModel` on assistant entries is not
# used: it is also written in sessions where the advisor tool was never added
# (it then names the main model).
#
# What counts as a call: a
# main-chain assistant entry carries a content block
#   {"type":"server_tool_use","id":"srvtoolu_...","name":"advisor",...}
# One call can be repeated across several entries, so calls are de-duplicated
# by id. The pattern is matched against unescaped JSON, which only real
# structure produces: the same text inside tool output or user text is a JSON
# string with escaped quotes and does not match.
#
# Output contract: writes /tmp/claude-advisor-<sanitized_session_id>.json as
#   {"advisor":"<model id or empty>","count":N,"ids":[...],"offset":BYTES,
#    "path":"<transcript>","last":EPOCH}
# statusline.sh reads only `.advisor` and `.count`. The file's absence means
# "not wired up" (or no reply yet) and renders as nothing.
#
# Prints NOTHING and returns immediately; the read runs detached.

set -u

input=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null | tr -dc 'a-zA-Z0-9' | cut -c1-24)
TRANSCRIPT=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] || exit 0

STATE="/tmp/claude-advisor-${SESSION_ID}.json"
LOCK="/tmp/claude-advisor-${SESSION_ID}.lock"
CALL_RE='"type":"server_tool_use","id":"srvtoolu_[A-Za-z0-9_]*","name":"advisor"'

# One updater per session; a lock older than 120s is left over from a killed
# run and is taken over. The lock is released explicitly (an EXIT trap does not
# fire reliably in the detached subshell).
update() {
  [ -r "$TRANSCRIPT" ] || return
  if ! mkdir "$LOCK" 2>/dev/null; then
    local now mtime
    now=$(date +%s)
    # GNU first: GNU `stat -f` means "file system" and prints a block, while BSD
    # stat rejects -c cleanly.
    mtime=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo "$now")
    case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
    [ $(( now - mtime )) -gt 120 ] || return
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || return
  fi
  scan
  rmdir "$LOCK" 2>/dev/null
}

scan() {
  local offset=0 ids='[]' prev_path="" size advisor=""
  if [ -f "$STATE" ]; then
    offset=$(jq -r '.offset // 0 | floor' "$STATE" 2>/dev/null || echo 0)
    advisor=$(jq -r '.advisor // "" | if type == "string" then . else "" end' "$STATE" 2>/dev/null)
    ids=$(jq -c '.ids // [] | map(strings)' "$STATE" 2>/dev/null || echo '[]')
    prev_path=$(jq -r '.path // ""' "$STATE" 2>/dev/null)
    # A state file written before the advisor model was tracked never saw the
    # attachment (it sits near the start of the transcript): read it again.
    [ "$(jq -r 'has("advisor")' "$STATE" 2>/dev/null)" = "true" ] || prev_path=""
  fi
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  [ -n "$ids" ] || ids='[]'
  size=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '0-9')
  [ -n "$size" ] || return
  # A different file, or one shorter than what was already read (rewritten or
  # replaced): start over from the beginning.
  if [ "$prev_path" != "$TRANSCRIPT" ] || [ "$size" -lt "$offset" ]; then
    offset=0; ids='[]'; advisor=""
  fi

  local chunk="${STATE}.$$.chunk" new_ids="[]" consumed=0 len partial
  # Only the bytes appended since the last run; a trailing line without its
  # newline is still being written, so it is left for the next run.
  tail -c +$(( offset + 1 )) "$TRANSCRIPT" 2>/dev/null | head -c $(( size - offset )) > "$chunk"
  len=$(wc -c < "$chunk" | tr -dc '0-9')
  if [ "${len:-0}" -gt 0 ]; then
    if [ "$(tail -c 1 "$chunk" | od -An -c | tr -d ' ')" = '\n' ]; then
      consumed=$len
    else
      partial=$(tail -n 1 "$chunk" | wc -c | tr -dc '0-9')
      consumed=$(( len - partial ))
    fi
    if [ "$consumed" -gt 0 ]; then
      new_ids=$(head -c "$consumed" "$chunk" \
        | LC_ALL=C grep -a "$CALL_RE" | LC_ALL=C grep -avF '"isSidechain":true' \
        | LC_ALL=C grep -ao "$CALL_RE" | LC_ALL=C grep -ao 'srvtoolu_[A-Za-z0-9_]*' \
        | jq -R . | jq -cs . 2>/dev/null)
      [ -n "$new_ids" ] || new_ids='[]'
      # Latest advisor_tool attachment in the new lines, "@"-prefixed so an
      # "unavailable" state ("@") is distinguishable from "none in this chunk".
      local adv_line
      adv_line=$(head -c "$consumed" "$chunk" | LC_ALL=C grep -aF '"type":"advisor_tool"' \
        | jq -rR 'fromjson? | objects
            | select(.type == "attachment" and .isSidechain != true and (.attachment | type) == "object"
                     and .attachment.type == "advisor_tool")
            | .attachment
            | "@" + (if .available == true and (.model | type) == "string" then .model else "" end)' 2>/dev/null \
        | tail -n 1)
      [ -n "$adv_line" ] && advisor=${adv_line#@}
    fi
  fi
  rm -f "$chunk"

  local tmp="${STATE}.$$.tmp"
  jq -cn --argjson a "$ids" --argjson b "$new_ids" --argjson off $(( offset + consumed )) \
    --arg path "$TRANSCRIPT" --arg adv "$advisor" --argjson now "$(date +%s)" \
    '($a + $b | unique) as $ids
     | {advisor: $adv, count: ($ids | length), ids: $ids, offset: $off, path: $path, last: $now}' \
    > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
  rm -f "$tmp"
}

# Detached: a Stop hook should not delay the end of the reply. The first run on
# a long transcript reads the whole file once.
( update >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
