# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A custom statusline for Claude Code: a one-shot Bash script that reads session JSON from stdin and renders a five-line colored status display. No build, no package manager, no test suite.

## Architecture

See **[`SPEC.md`](SPEC.md)** for the authoritative spec — output layout, color formulas, JSON input contract, IPC invariants, install wiring.

Two scripts:

- `statusline.sh` — the renderer
- `hooks/compact-monitor.sh` — a `PreCompact` hook that bumps a counter the renderer consumes via `/tmp/claude-compacts-<sanitized_session_id>.json`

## Conventions to preserve

- **Every `jq` lookup in `statusline.sh` must have a `//` default.** Claude Code may add or rename schema fields; the script must degrade gracefully.
- **Optional payload fields render gated.** Fields that may be absent (`pr.*`, `worktree.*`, `thinking.enabled`, `fast_mode`, `prompt_cache.*`, `context_window.context_window_size`, `cost.total_api_duration_ms`, `session_name`, `version`) are shown only when present / non-zero, so a line never emits a stray separator or placeholder. Keep new field additions gated the same way. See `SPEC.md` → Gated fields.
- **Effort comes from stdin `.effort.level`, with no silent fallback.** It is one of `low/medium/high/xhigh/max` (Claude Code normalizes `ultracode` → `xhigh` upstream, so it never arrives literally). A *missing* field (models without effort support, e.g. Haiku 4.5) renders as a dim `—`; a *present-but-unrecognized* value renders as a loud bright-red `unknown` so schema drift stays visible. Don't reintroduce a quiet default. See `SPEC.md` → Effort level.
- **Cross-platform `date`**: use the BSD-or-GNU fallback `date -r "$EPOCH" "+%H:%M" 2>/dev/null || date -d "@$EPOCH" "+%H:%M" 2>/dev/null`. Keep it when adding new time displays.
- **Bars are built by glyph concatenation, not `tr`.** `tr ' ' '█'` maps *bytes*, so GNU coreutils corrupts the 3-byte bar glyphs into invalid UTF-8 (only BSD `tr` rendered them) — the bars looked fine on macOS but were broken on Linux. Build runs with the `repeat_glyph` helper in `statusline.sh` (and the inline loop in `docs/swatches.sh`); mirror that for any new bar. Bars are drawn by `shade_bar` (10 cells, 1/3-cell resolution via a `░ ▒ ▓` boundary cell); use it for any new bar.
- **Session id sanitization** (`tr -dc 'a-zA-Z0-9' | cut -c1-24`) is the IPC key shared by `statusline.sh`, `hooks/compact-monitor.sh`, and `hooks/account-monitor.sh`. Change one, change all three.
- **The account label must be derived from the session's own credential, never from `~/.claude.json`.** `.oauthAccount` there is a single machine-global slot shared by every Claude Code surface and is only rewritten by a full profile fetch gated behind a 24h TTL, so it can name a different account than the one actually spending quota (it did, for two days, before 2026-08-24). `hooks/account-monitor.sh` resolves the credential the session authenticates with and publishes the owner; the renderer reads only that. If resolution fails the label is a loud yellow `?` — never fall back to a name that might be wrong. See `SPEC.md` → Account attribution.
- **The agent name on the session line comes from Claude Code's internal session registry** (`${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/<pid>.json`, matched by `sessionId`) and derives the ref as `sha256("session:" + messagingSocketPath)[0:6]`, mirroring ListAgents. Both are undocumented internals: keep the lookup read-only, keep the `session_name` fallback (no ref) and the omit-when-absent gate, and never show a name that was not matched to this session's id. Re-verify against `ListAgents` output after a Claude Code upgrade if the name disappears or the ref differs. See `SPEC.md` → Agent name.
- **The context bar must not be wrapped in DIM** — it uses 24-bit truecolor and DIM collapses the gradient. (The 5h / 7d limit bars are also truecolor but are intentionally wrapped in DIM for a softer look — that's a deliberate aesthetic choice, not a precedent to copy.)
- **Bar widths**: context, 5h and 7d are all 10 cells (the `shade_bar` width argument).
- **Line width budget ≤ 120 columns.** Keep every rendered line within ~120 visible columns (excluding ANSI codes and the session line's `⚠ <drift>` suffix appended by `claude-backup`). The shared label column is dynamic (it widens to the account `displayName`), so a long account name — or long repo/branch/PR/worktree on line 1, or a long agent name on the session line — can blow the budget. If a design change would push any line past 120, **confirm the design with the user before shipping** rather than silently overflowing. See `SPEC.md` → Width budget.
- **`docs/swatches.sh` mirrors the colors.** It regenerates the three README graphics and duplicates `statusline.sh`'s palette + gradient formulas (it is *not* sourced by the renderer — that stays a single drop-in file). Change a color constant or gradient formula in `statusline.sh` → update `docs/swatches.sh` too, then re-render and re-screenshot the affected `docs/*.png`.
- **`docs/preview.sh` regenerates the README text previews.** It rewrites the two blocks between the `<!-- preview:baseline -->` / `<!-- preview:full -->` markers in `README.md` by running the real `statusline.sh` against fixed sandboxed payloads (pinned clock via `TZ=UTC` + a `date` shim, scratch git repos for branch/diff, fake `HOME` for the drift flag and session registry, seeded `/tmp` account + compact files). Unlike `swatches.sh` it does **not** duplicate renderer logic — it invokes `statusline.sh`, so it can only drift in its sample inputs, never in output formatting. It is deterministic (a no-op change yields no diff) and byte-reproducible across BSD/GNU (verified in a Linux container). After any change to `statusline.sh`'s output, re-run it (`./docs/preview.sh`) and commit; no manual paste/screenshot needed (that's only swatches, because those are images). `./docs/preview.sh --check` regenerates into a temp file and diffs without mutating README (exit 1 on drift); CI runs exactly this via `.github/workflows/preview-check.yml`, so a stale preview fails the build.

## Testing

No test framework. Pipe a sample JSON to preview:

```bash
echo '{"model":{"display_name":"Claude Opus 4.7"},"session_id":"abc","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},"context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$(($(date +%s)+3600))"'},"seven_day":{"used_percentage":8,"resets_at":'"$(($(date +%s)+86400))"'}},"workspace":{"current_dir":"'"$PWD"'"}}' | ./statusline.sh
```

For the compact hook, seed `/tmp/claude-compacts-<sanitized_id>.json` with `{"count":N}` or trigger `/compact` in a real session.

## Install / wiring

Scripts are meant to be symlinked into `~/.claude/` and referenced from `~/.claude/settings.json` (see `SPEC.md` for the exact JSON stanza). Edits here take effect on the next statusline refresh — no reload needed, because symlinks resolve to the live files.
