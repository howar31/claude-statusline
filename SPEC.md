# SPEC.md

Authoritative architecture and behavior spec for this repo. `CLAUDE.md` indexes this file for detail.

## Purpose

Render Claude Code's statusline as an 8-line colored status display. Stateless one-shot Bash script — no daemon, no build, no tests.

## Components

### `statusline.sh`

The main renderer. Invoked by Claude Code with a JSON payload on stdin; writes eight ANSI-colored lines to stdout and exits. Wired via `statusLine.command` in `~/.claude/settings.json`.

### `hooks/compact-monitor.sh`

A pass-through `PreCompact` hook. Reads stdin, increments the `count` field in `/tmp/claude-compacts-<sanitized_session_id>.json`, echoes stdin back unchanged so additional `PreCompact` hooks can chain after it. Wired via `hooks.PreCompact[]` in `~/.claude/settings.json`.

## Out-of-band IPC

The hook writes, the renderer reads: `/tmp/claude-compacts-<SANITIZED_SESSION_ID>.json`. Both sides compute the key identically:

```bash
sanitized = session_id | tr -dc 'a-zA-Z0-9' | cut -c1-24
```

**Invariant**: if you change the sanitization rule in one file, change it in the other, or the renderer will miss the count.

## Input JSON schema

`statusline.sh` reads Claude Code's statusline payload. Fields consumed (all with `//` defaults in `jq`):

- `model.display_name`
- `session_id`
- `exceeds_200k_tokens`
- `cost.total_cost_usd`
- `cost.total_duration_ms`
- `context_window.used_percentage`
- `context_window.total_input_tokens`
- `context_window.total_output_tokens`
- `context_window.current_usage.cache_read_input_tokens`
- `context_window.current_usage.cache_creation_input_tokens`
- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`
- `workspace.current_dir` (falls back to `.cwd`)

**Discipline**: every `jq` lookup must have a `//` default. The script must degrade gracefully if Claude Code renames, removes, or adds fields.

One non-standard read: `effortLevel` is pulled from `~/.claude/settings.json` (user-defined, not part of the statusline schema).

## Output layout (8 lines)

1. **Git info** (unlabeled, flush-left): `<repo_name> ⬠ <branch> · +N -N`. Omitted entirely if CWD is unknown.
2. **`Model  `** — `<model>` + effort level
3. **`Context`** — 30-char progress bar, percentage, optional `compact Nx`
4. **`Tokens `** — `In <X> · Out <Y> · Cache <pct>%`. When `exceeds_200k_tokens` is true, `⚠ 200k+` appears in red **before** `In` — i.e. `⚠ 200k+ · In X · Out Y · Cache Z%`. Note: this flag is set by Claude Code based on the current context window size (not cumulative `In + Out` session totals), so the warning can fire even when the displayed `In/Out` sum is well below 200k.
5. **`Stats  `** — `Cost $X.XX · Dur Xm Xs`
6. **`Limits `** — 20-char 5h bar, `5H <pct>%`, reset time
7. **(unlabeled, 8-space indent)** — 20-char 7d bar, `7D <pct>%`, reset time
8. **Session id + timestamp** (unlabeled, dim, flush-left) — `<session_id> · YYYY.MM.DD HH:MM:SS`

### Alignment rules

- Lines 2–6 use a dim label column of width 7 (`Model  `, `Context`, `Tokens `, `Stats  `, `Limits `) followed by one separator space.
- Line 7's 8-space indent (as DIM spaces) mirrors the `Limits ` label structure so the 7d bar starts at the same column as the 5h bar.
- Lines 1 and 8 are flush-left so they can be scanned or copied without leading indent — line 8's raw session id is designed for `claude --resume <id>` (Claude Code does not support prefix matching, so the full UUID is shown).

### Bar widths

- Context bar: **30 chars**
- 5h / 7d bars: **20 chars** each

If you change a width, update the matching `pct * N / 100` calculation.

## Color specification

ANSI palette defined at the top of `statusline.sh`: `RESET`, `CYAN`, `MAGENTA`, `GREEN`, `YELLOW`, `ORANGE`, `BLUE`, `RED`, `PURPLE`, `BRIGHT_WHITE`, `DIM`.

### Context bar — smooth truecolor gradient (`\033[38;2;R;G;Bm`)

- **0–60%**: grayscale ramp. `R=G=B = 50 + (255-50) * USED / 60`. 0% → `(50,50,50)` darkest gray; 60% → `(255,255,255)` white.
- **60–70%**: white → yellow → red.
  - `R = 255` throughout.
  - `G = 255 - (USED-60) * 255 / 10` (255→0 across the full 10%).
  - `B = 255 - (USED-60) * 255 / 5` for `USED ≤ 65`, else `0` (drops 255→0 over the first half).
  - Waypoints: 60% = `(255,255,255)` white, 65% = `(255,128,0)` orange, 70% = `(255,0,0)` red.
- **>70%**: solid red `(255,0,0)`.

The context bar is **not** wrapped in DIM — the gradient renders at full intensity. Don't add DIM back.

### Rate limit bars (5h / 7d) — discrete zones

- `pct ≤ 75%` → `$GREEN` (ANSI 32), wrapped in DIM on the bar so it reads as dim green
- `76% ≤ pct ≤ 90%` → `$YELLOW` (ANSI 33)
- `pct > 90%` → `$RED` (ANSI 31)

The percentage number uses the same zone color without DIM so it stays legible.

### Model family

- `*Opus*` → `$PURPLE` (256-color 135)
- `*Haiku*` → `$GREEN`
- else → `$CYAN`

### Effort level (mirrors Claude Code's `/effort` picker tokens)

| effort   | statusline color | picker token           |
|----------|------------------|------------------------|
| `low`    | `$YELLOW`        | `warning`              |
| `medium` | `$GREEN`         | `success`              |
| `high`   | `$BLUE`          | `permission`           |
| `xhigh`  | `$MAGENTA`       | `autoAccept-shimmer`   |
| `max`    | `$BRIGHT_WHITE`  | `rainbow-animated`     |

`max` uses bright white because the statusline is stateless one-shot output and cannot animate a rainbow. All other mappings use the ANSI equivalent of the `/effort` picker's semantic color token (discovered by inspecting Claude Code's binary).

## Cross-platform date handling

Timestamp formatting must support both macOS (BSD `date`) and Linux (GNU `date`):

```bash
date -r "$EPOCH" "+%H:%M" 2>/dev/null || date -d "@$EPOCH" "+%H:%M" 2>/dev/null
```

Keep this fallback whenever adding new time displays.

## Testing

No test framework. Pipe a sample JSON payload to preview:

```bash
echo '{"model":{"display_name":"Claude Opus 4.7"},"session_id":"abc","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},"context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$(($(date +%s)+3600))"'},"seven_day":{"used_percentage":8,"resets_at":'"$(($(date +%s)+86400))"'}},"workspace":{"current_dir":"'"$PWD"'"}}' | ./statusline.sh
```

To test the compact hook, either seed `/tmp/claude-compacts-<sanitized_id>.json` manually with `{"count":N}`, or trigger `/compact` in a real Claude Code session. The renderer picks up the count on its next invocation.

## Install / wiring

Symlink the scripts into `~/.claude/` so `settings.json` references stable paths that don't depend on the repo's clone location:

```
~/.claude/statusline.sh             → <repo>/statusline.sh
~/.claude/hooks/compact-monitor.sh  → <repo>/hooks/compact-monitor.sh
```

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  },
  "hooks": {
    "PreCompact": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "bash ~/.claude/hooks/compact-monitor.sh" }
        ]
      }
    ]
  }
}
```

Edits to the repo take effect immediately on the next statusline refresh — no reload needed, since the symlinks resolve to the live files. Without the `PreCompact` hook wired, the `compact Nx` counter stays at 0 (the rest of the statusline still works).
