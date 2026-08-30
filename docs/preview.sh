#!/usr/bin/env bash
#
# docs/preview.sh — regenerate the two plain-text statusline previews in
# README.md, between the <!-- preview:baseline --> / <!-- preview:full -->
# markers.
#
# Unlike docs/swatches.sh, this does NOT duplicate any renderer logic: it runs
# the real statusline.sh against fixed sample payloads inside a sandbox, strips
# ANSI, and rewrites the blocks. So the previews can never drift from the
# renderer's actual output. It is fully deterministic — re-running with no
# renderer change yields no diff — because every non-deterministic input is
# pinned:
#   - clock : TZ=UTC + a `date` shim (fixed "now"; reset epochs are fixed)
#   - git   : throwaway scratch repos give a fixed branch + diff count
#   - HOME  : fake HOME controls the backup-drift flag
#   - account label / compact counter : seeded /tmp files
#
# Usage:  ./docs/preview.sh          # rewrite README.md in place
#         ./docs/preview.sh --check  # exit 1 if README.md is out of date (CI)
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
RENDER="$REPO/statusline.sh"
README="$REPO/README.md"

MODE="${1:-}"
if [ -n "$MODE" ] && [ "$MODE" != "--check" ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi
for m in 'preview:baseline' '/preview:baseline' 'preview:full' '/preview:full'; do
  grep -q "<!-- $m -->" "$README" || { echo "missing marker in README.md: <!-- $m -->" >&2; exit 2; }
done

export TZ=UTC
FIXED_EPOCH=1768467600          # 2026-01-15 09:00:00 UTC — the pinned "now"
FIXED_WALL="2026.01.15 09:00:00"
SID="abc12345-6789-defg-hijk-lmnopqrstuvw"   # illustrative, obviously fake
SAN=$(printf '%s' "$SID" | tr -dc 'a-zA-Z0-9' | cut -c1-24)
COMPACT_FILE="/tmp/claude-compacts-${SAN}.json"
ACCOUNT_FILE="/tmp/claude-account-${SAN}.json"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; rm -f "$COMPACT_FILE" "$ACCOUNT_FILE"; }
trap cleanup EXIT

# --- deterministic clock ----------------------------------------------------
# A `date` shim: pin `+%s` and the wall-clock format; delegate epoch formatting
# (`-r` / `-d`, used by statusline.sh for the reset times) to the real date —
# deterministic because the reset epochs are fixed offsets of FIXED_EPOCH.
SHIM="$WORK/bin"; mkdir -p "$SHIM"
cat > "$SHIM/date" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in -r|-d) exec /bin/date "\$@";; esac; done
case "\$1" in
  +%s) echo $FIXED_EPOCH ;;
  *)   echo "$FIXED_WALL" ;;
esac
EOF
chmod +x "$SHIM/date"

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

render() {  # $1 = HOME dir, $2 = payload file -> plain-text statusline
  PATH="$SHIM:$PATH" HOME="$1" bash "$RENDER" < "$2" | strip_ansi
}

# --- scratch git repos (deterministic repo name, branch, diff count) --------
# Commit `old` lines, then replace them all with `new` distinct lines so the
# working-tree diff is exactly +new -old. Dir basename is the displayed repo.
make_repo() {  # $1 parent  $2 branch  $3 old_lines  $4 new_lines -> echoes repo path
  local dir="$1/claude-statusline"
  mkdir -p "$dir"
  git init -q -b "$2" "$dir" 2>/dev/null || { git init -q "$dir"; git -C "$dir" checkout -q -b "$2"; }
  git -C "$dir" config user.email preview@example.com
  git -C "$dir" config user.name preview
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config core.hooksPath /dev/null   # ignore any global hooks
  seq 1 "$3" > "$dir/f.txt"
  git -C "$dir" add f.txt
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$dir" commit -q -m init
  seq 1000 $((1000 + $4 - 1)) > "$dir/f.txt"
  echo "$dir"
}

BASE_REPO=$(make_repo "$WORK/base" main 7 25)     # +25 -7
FULL_REPO=$(make_repo "$WORK/full" feat 34 128)   # +128 -34

# --- baseline: only always-present fields (no account / compact / drift) -----
rm -f "$COMPACT_FILE" "$ACCOUNT_FILE"              # no stray compact count / account label
BASE_HOME="$WORK/home-base"; mkdir -p "$BASE_HOME"
cat > "$WORK/base.json" <<EOF
{"model":{"display_name":"Claude Opus 4.8"},"version":"2.1.195","effort":{"level":"xhigh"},
 "session_id":"$SID","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},
 "context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,
   "current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},
 "rate_limits":{"five_hour":{"used_percentage":22,"resets_at":$((FIXED_EPOCH+3600))},
   "seven_day":{"used_percentage":8,"resets_at":$((FIXED_EPOCH+86400))}},
 "workspace":{"current_dir":"$BASE_REPO"}}
EOF
{ echo '```'; render "$BASE_HOME" "$WORK/base.json"; echo '```'; } > "$WORK/baseline.block"

# --- everything-on: account + every gated field ------------------------------
FULL_HOME="$WORK/home-full"; mkdir -p "$FULL_HOME/.claude/system/backup"
printf '3 files / 1d behind' > "$FULL_HOME/.claude/system/backup/.drift-status"
printf '{"count":2}' > "$COMPACT_FILE"
# Account label: what hooks/account-monitor.sh publishes for this session. The
# name is fictitious, so no real account leaks into the committed preview.
printf '{"displayName":"Ada Lovelace"}' > "$ACCOUNT_FILE"
cat > "$WORK/full.json" <<EOF
{"model":{"display_name":"Claude Opus 4.8"},"version":"2.1.195","effort":{"level":"xhigh"},
 "thinking":{"enabled":true},"session_id":"$SID","exceeds_200k_tokens":true,
 "pr":{"number":42,"review_state":"approved"},"worktree":{"name":"wt","branch":"feat"},
 "cost":{"total_cost_usd":1.07,"total_duration_ms":1325000,"total_api_duration_ms":612000},
 "context_window":{"used_percentage":45,"context_window_size":1000000,
   "total_input_tokens":1200,"total_output_tokens":800,
   "current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},
 "rate_limits":{"five_hour":{"used_percentage":78,"resets_at":$((FIXED_EPOCH+7200))},
   "seven_day":{"used_percentage":35,"resets_at":$((FIXED_EPOCH+345600))}},
 "workspace":{"current_dir":"$FULL_REPO"}}
EOF
{ echo '```'; render "$FULL_HOME" "$WORK/full.json"; echo '```'; } > "$WORK/full.block"

# --- inject between markers --------------------------------------------------
# Normal mode rewrites README.md in place; --check builds the desired content in
# a temp file and diffs it, never touching README.md.
TARGET="$README"
if [ "$MODE" = "--check" ]; then
  TARGET="$WORK/README.work"
  cp "$README" "$TARGET"
fi

inject() {  # $1 = marker name, $2 = block file (rewrites $TARGET in place)
  awk -v s="<!-- preview:$1 -->" -v e="<!-- /preview:$1 -->" -v f="$2" '
    $0==s {print; while((getline line < f)>0) print line; close(f); skip=1; next}
    $0==e {skip=0; print; next}
    skip {next}
    {print}
  ' "$TARGET" > "$TARGET.tmp"
  mv "$TARGET.tmp" "$TARGET"
}

inject baseline "$WORK/baseline.block"
inject full     "$WORK/full.block"

if [ "$MODE" = "--check" ]; then
  if diff -u "$README" "$TARGET" > "$WORK/preview.diff" 2>&1; then
    echo "README previews are up to date."
  else
    echo "ERROR: README previews are stale. Run ./docs/preview.sh and commit the result." >&2
    cat "$WORK/preview.diff" >&2
    exit 1
  fi
else
  echo "README previews regenerated."
fi
