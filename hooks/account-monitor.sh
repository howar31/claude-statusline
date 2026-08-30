#!/usr/bin/env bash
#
# account-monitor.sh — resolve WHICH ACCOUNT this session is authenticated as,
# and publish it for statusline.sh.
#
# Why this exists: ~/.claude.json's `.oauthAccount` block is a single global slot
# shared by every Claude Code surface on the machine (terminal CLI, IDE
# extensions, the desktop app's bundled CLI). Claude Code only rewrites the
# identity fields (displayName / emailAddress / accountUuid) during a full
# profile fetch, and that fetch is gated behind a 24h TTL on `profileFetchedAt`
# — which token refresh keeps bumping without touching the identity. So that
# file can name a different account than the credential actually in use, for
# days, and any other surface can overwrite it. It cannot answer "whose quota is
# this session spending".
#
# The only trustworthy answer: take the token THIS session authenticates with
# and ask the API who owns it. That is what this hook does.
#
# Wiring: SessionStart (resolve for the session) + UserPromptSubmit (catch an
# account switch mid-session). Both are latency-sensitive, so the hook returns
# immediately and does the work in a detached background job; the network call
# is skipped whenever the token's fingerprint is already cached.
#
# Output contract: writes /tmp/claude-account-<sanitized_session_id>.json, read
# by statusline.sh. `displayName` is a string when resolved, null when the
# resolution was attempted and failed (statusline renders that as a loud `?`).
# The file's absence means "not wired up" and renders as no label at all.
#
# Prints NOTHING on stdout: SessionStart / UserPromptSubmit stdout is injected
# into the session context.

set -u

input=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null | tr -dc 'a-zA-Z0-9' | cut -c1-24)
[ -n "$SESSION_ID" ] || exit 0

SESSION_FILE="/tmp/claude-account-${SESSION_ID}.json"
PROFILE_TTL=43200                                  # 12h; a token rotation invalidates sooner
API_BASE="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"

# Portable sha256 -> hex on stdout. BSD/macOS ships `shasum`, most Linux distros
# ship `sha256sum`; fall back to openssl before giving up.
sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else cat >/dev/null; fi
}

write_session() {  # $1 = JSON body
  local tmp="${SESSION_FILE}.$$.tmp"
  printf '%s' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$SESSION_FILE" 2>/dev/null
}

resolve() {
  # --- 1. the token this session authenticates with -------------------------
  # Mirrors Claude Code's own precedence: explicit env credential first, then
  # the credential store keyed by the config dir.
  local token="" source="" cred=""
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    token="$CLAUDE_CODE_OAUTH_TOKEN"; source="env-oauth"
  elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    token="$ANTHROPIC_AUTH_TOKEN"; source="env-auth"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    token="$ANTHROPIC_API_KEY"; source="env-apikey"
  elif [ "$(uname -s)" = "Darwin" ]; then
    # Keychain service name is derived from the config dir: the default dir uses
    # a bare name, a custom CLAUDE_CONFIG_DIR appends sha256(dir)[0:8].
    local svc="Claude Code-credentials" suffix=""
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      suffix=$(printf '%s' "$CLAUDE_CONFIG_DIR" | sha256_hex | cut -c1-8)
      [ -n "$suffix" ] && svc="Claude Code-credentials-${suffix}"
    fi
    cred=$(security find-generic-password -a "$(id -un)" -w -s "$svc" 2>/dev/null \
           || security find-generic-password -w -s "$svc" 2>/dev/null || true)
    token=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    source="keychain"
  else
    cred=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null || true)
    token=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    source="credfile"
  fi

  if [ -z "$token" ]; then
    write_session '{"displayName":null,"error":"no-token"}'
    return
  fi

  # --- 2. cache, keyed by the token itself ----------------------------------
  # A cache hit is always the right account: the key IS the credential. The TTL
  # only exists so a renamed account eventually catches up.
  local fp cache now age=999999
  fp=$(printf '%s' "$token" | sha256_hex | cut -c1-12)
  [ -n "$fp" ] || { write_session '{"displayName":null,"error":"no-fingerprint"}'; return; }
  cache="/tmp/claude-account-${fp}.json"
  now=$(date +%s)
  if [ -f "$cache" ]; then
    local at
    at=$(jq -r '.fetchedAt // 0' "$cache" 2>/dev/null || echo 0)
    age=$(( now - at ))
  fi

  # Housekeeping: drop caches for tokens and sessions long gone.
  find /tmp -maxdepth 1 -name 'claude-account-*' -mtime +7 -delete 2>/dev/null || true

  # --- 3. resolve the owner -------------------------------------------------
  if [ "$age" -ge "$PROFILE_TTL" ]; then
    local resp parsed tmp
    resp=$(curl -sS --max-time 5 "${API_BASE}/api/oauth/profile" \
             -H "Authorization: Bearer ${token}" \
             -H 'Content-Type: application/json' \
             -H 'Cache-Control: no-cache' 2>/dev/null || true)
    parsed=$(printf '%s' "$resp" | jq -c --argjson at "$now" '
        select(.account != null) |
        {displayName: (.account.display_name // .account.full_name // null),
         accountUuid: .account.uuid,
         email: .account.email,
         organization: (.organization.name // null),
         fetchedAt: $at}' 2>/dev/null)
    if [ -n "$parsed" ]; then
      tmp="${cache}.$$.tmp"
      printf '%s' "$parsed" > "$tmp" 2>/dev/null && mv "$tmp" "$cache" 2>/dev/null
    fi
  fi

  # A stale cache entry still names the right account (same token), so it is
  # preferred over reporting unknown when a refresh fails.
  if [ -f "$cache" ]; then
    local out
    out=$(jq -c --arg fp "$fp" --arg src "$source" '. + {tokenFp: $fp, source: $src}' "$cache" 2>/dev/null)
    [ -n "$out" ] && write_session "$out" && return
  fi
  write_session '{"displayName":null,"error":"profile-unavailable"}'
}

# Detached: never make the user wait on a keychain read or a network call.
( resolve >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
