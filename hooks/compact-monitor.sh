#!/usr/bin/env bash
input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id // ""' | tr -dc 'a-zA-Z0-9' | cut -c1-24)

if [ -n "$SESSION_ID" ]; then
  CACHE_FILE="/tmp/claude-compacts-${SESSION_ID}.json"
  COUNT=0
  [ -f "$CACHE_FILE" ] && COUNT=$(jq -r '.count // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  COUNT=$(( COUNT + 1 ))
  NOW=$(date +%s)
  TMP="${CACHE_FILE}.${$}.${NOW}.tmp"
  echo "{\"count\":${COUNT},\"last\":${NOW}}" > "$TMP" && mv "$TMP" "$CACHE_FILE"
fi

echo "$input"
