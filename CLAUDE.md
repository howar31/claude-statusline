# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A custom statusline for Claude Code: a one-shot Bash script that reads session JSON from stdin and renders an eight-line colored status display. No build, no package manager, no test suite.

## Architecture

See **[`SPEC.md`](SPEC.md)** for the authoritative spec — output layout, color formulas, JSON input contract, IPC invariants, install wiring.

Two scripts:

- `statusline.sh` — the renderer
- `hooks/compact-monitor.sh` — a `PreCompact` hook that bumps a counter the renderer consumes via `/tmp/claude-compacts-<sanitized_session_id>.json`

## Conventions to preserve

- **Every `jq` lookup in `statusline.sh` must have a `//` default.** Claude Code may add or rename schema fields; the script must degrade gracefully.
- **Cross-platform `date`**: use the BSD-or-GNU fallback `date -r "$EPOCH" "+%H:%M" 2>/dev/null || date -d "@$EPOCH" "+%H:%M" 2>/dev/null`. Keep it when adding new time displays.
- **Session id sanitization** (`tr -dc 'a-zA-Z0-9' | cut -c1-24`) is the IPC key shared by `statusline.sh` and `hooks/compact-monitor.sh`. Change one, change both.
- **The context bar must not be wrapped in DIM** — it uses 24-bit truecolor and DIM collapses the gradient.
- **Bar widths**: context 30 chars, 5h/7d 20 chars. If you change one, update its `pct * N / 100` calculation too.

## Testing

No test framework. Pipe a sample JSON to preview:

```bash
echo '{"model":{"display_name":"Claude Opus 4.7"},"session_id":"abc","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},"context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$(($(date +%s)+3600))"'},"seven_day":{"used_percentage":8,"resets_at":'"$(($(date +%s)+86400))"'}},"workspace":{"current_dir":"'"$PWD"'"}}' | ./statusline.sh
```

For the compact hook, seed `/tmp/claude-compacts-<sanitized_id>.json` with `{"count":N}` or trigger `/compact` in a real session.

## Install / wiring

Scripts are meant to be symlinked into `~/.claude/` and referenced from `~/.claude/settings.json` (see `SPEC.md` for the exact JSON stanza). Edits here take effect on the next statusline refresh — no reload needed, because symlinks resolve to the live files.
