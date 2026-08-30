# SPEC.md

Authoritative architecture and behavior spec for this repo. `CLAUDE.md` indexes this file for detail.

## Purpose

Render Claude Code's statusline as an 8-line colored status display. Stateless one-shot Bash script — no daemon, no build, no tests.

## Components

### `statusline.sh`

The main renderer. Invoked by Claude Code with a JSON payload on stdin; writes eight ANSI-colored lines to stdout and exits. Wired via `statusLine.command` in `~/.claude/settings.json`.

### `hooks/compact-monitor.sh`

A pass-through `PreCompact` hook. Reads stdin, increments the `count` field in `/tmp/claude-compacts-<sanitized_session_id>.json`, echoes stdin back unchanged so additional `PreCompact` hooks can chain after it. Wired via `hooks.PreCompact[]` in `~/.claude/settings.json`.

### `hooks/account-monitor.sh`

A `SessionStart` + `UserPromptSubmit` hook that answers "whose quota is this session spending". It resolves the credential the session actually authenticates with, asks the API who owns it, and publishes the answer to `/tmp/claude-account-<sanitized_session_id>.json` for the renderer. It prints nothing (both hook events inject stdout into the session context) and returns immediately, doing its work in a detached background job. Wired via `hooks.SessionStart[]` and `hooks.UserPromptSubmit[]` in `~/.claude/settings.json`. See *Account attribution* below for the resolution order and rationale.

### `docs/swatches.sh`

A developer tool (not part of the runtime). Prints the ANSI behind the three README color graphics — `model` (model family + effort), `context` (context bar gradient), `limit` (5h/7d limit bar gradient); no arg prints all. It **duplicates** `statusline.sh`'s palette constants and gradient formulas rather than sourcing them, so the renderer stays a single drop-in file — keep the two in sync (see CLAUDE.md). It emits ANSI only, not PNGs: render a section in a 24-bit truecolor terminal, screenshot it, and save over the matching `docs/*.png`.

### `docs/preview.sh`

A developer tool (not part of the runtime). Regenerates the two plain-text statusline previews in `README.md`'s *What it looks like* section — a **Baseline** (always-present fields only) and an **Everything on** (account label + every gated field) — by rewriting the blocks between the `<!-- preview:baseline -->` / `<!-- preview:full -->` markers. Unlike `swatches.sh` it does **not** duplicate renderer logic: it invokes `statusline.sh` itself against two fixed sample payloads, strips ANSI, and injects the result, so the previews can never drift from the renderer's actual formatting. It is fully deterministic — re-running with no renderer change yields no diff — because every non-deterministic input is pinned: the clock (`TZ=UTC` + a `date` shim that fixes "now" and lets reset epochs format deterministically), git branch/diff (throwaway scratch repos giving `main · +25 -7` and `feat · +128 -34`), the backup-drift flag (a fake `HOME`), and the account label plus compact counter (seeded `/tmp/claude-account-*.json` and `/tmp/claude-compacts-*.json`). The account name is the fictitious `Ada Lovelace` and the session id is an obvious placeholder, so no real personal data is emitted. Re-run after any change to `statusline.sh`'s output format; no manual paste needed (the blocks are text, not images).

`./docs/preview.sh --check` regenerates into a temp file and diffs it against `README.md` without mutating anything — exit 0 if current, exit 1 plus the diff if stale. The output is byte-reproducible across BSD (macOS) and GNU (Linux), verified by running `--check` in an Ubuntu container against a macOS-generated README. CI enforces freshness via `.github/workflows/preview-check.yml`, which runs `bash docs/preview.sh --check` on `ubuntu-latest` whenever `statusline.sh`, `docs/preview.sh`, or `README.md` changes.

## Out-of-band IPC

The renderer reads three state files written by external processes; none of them is part of the statusline JSON payload. Two are produced by this repo's own hooks (compact counter, account attribution), the third by the separate `claude-backup` project (drift flag).

### Compact counter

The `PreCompact` hook writes, the renderer reads: `/tmp/claude-compacts-<SANITIZED_SESSION_ID>.json`. Both sides compute the key identically:

```bash
sanitized = session_id | tr -dc 'a-zA-Z0-9' | cut -c1-24
```

**Invariant**: the same sanitization rule appears in `statusline.sh`, `hooks/compact-monitor.sh`, and `hooks/account-monitor.sh`. Change one, change all three, or the renderer will miss the count (and the account label).

### Account attribution

The line-1 account label answers one question: **which account's quota is this session spending**. Accuracy matters more than presence — a label naming the wrong account is worse than no label.

`hooks/account-monitor.sh` writes, the renderer reads: `/tmp/claude-account-<SANITIZED_SESSION_ID>.json`, keyed by the same sanitization as the compact counter (same invariant applies — three files now share the rule).

**Why not `~/.claude.json` → `.oauthAccount.displayName`** (which is what this repo read until 2026-08-24, and got wrong):

- That block is a single machine-global slot shared by every Claude Code surface: terminal CLI, IDE extensions, and the desktop app's bundled CLI all default to config dir `~/.claude` and therefore to the same `~/.claude.json`.
- Claude Code rewrites its identity fields (`displayName` / `emailAddress` / `accountUuid`) only during a **full profile fetch**, which is gated behind a 24h TTL on `profileFetchedAt`. Token refresh bumps `profileFetchedAt` while merging only subscription fields, so the TTL can be renewed indefinitely without the identity ever being re-checked.
- Net effect: after switching accounts, the file can keep naming the previous account for a day or more, and whichever surface performs the next full fetch owns the slot. Observed in practice: a session authenticating as account A displayed account B's name for two days.
- Sessions that authenticate from an env credential (`CLAUDE_CODE_OAUTH_TOKEN`, as the desktop app passes to its bundled CLI) never write the slot at all.

**Resolution order** (mirrors Claude Code's own credential precedence, so the hook resolves the same credential the session authenticates with):

1. `CLAUDE_CODE_OAUTH_TOKEN` → `ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` from the environment the session runs in.
2. macOS: Keychain generic password, service `Claude Code-credentials`; a custom `CLAUDE_CONFIG_DIR` appends `-<sha256(dir)[0:8]>` to the service name, matching how Claude Code derives it.
3. Otherwise: `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`.

In both stores the token is `.claudeAiOauth.accessToken`. The Keychain lookup tries `-a "$(id -un)"` first and falls back to a service-only match. Hashing goes through a `sha256_hex` helper that tries `shasum -a 256`, then `sha256sum`, then `openssl dgst -sha256`, so the hook works on BSD and GNU userlands alike.

The token is then resolved to an owner via `GET {ANTHROPIC_BASE_URL:-https://api.anthropic.com}/api/oauth/profile` (the same endpoint Claude Code uses, `curl --max-time 5`), and cached at `/tmp/claude-account-<sha256(token)[0:12]>.json` with a 12h TTL (`PROFILE_TTL=43200`). **The cache key is the credential itself**, so a hit can never name the wrong account, and an account switch invalidates it automatically. A stale entry is preferred over a failed refresh — same token, same owner. Entries older than 7 days are pruned.

**Renderer states** (`statusline.sh` reads only the per-session file; it never touches the network or the Keychain):

| Session file | Label |
|---|---|
| absent | no label at all — hook not wired; line 1 stays flush-left, byte-identical to the pre-hook layout |
| `displayName` is a string | the name, dim, in the shared label column |
| `displayName` is `null` | a yellow `?` — resolution was attempted and failed; the session's usage is deliberately *not* attributed to anyone |

`displayName` (e.g. `Ada Lovelace`) is stored and rendered rather than `email` / `organization` to keep addresses and org names out of statusline screenshots (this repo publishes `docs/*.png`); the resolver caches those two fields for debugging but the renderer ignores them.

### Backup drift flag

`claude-backup.sh git` (from the separate `claude-backup` repo, symlinked at `~/.claude/system/backup`) writes, the renderer reads: `~/.claude/system/backup/.drift-status`. If the file exists and is non-empty, its contents render as the line-8 drift indicator (`⚠ <text>`, yellow); if absent or empty, nothing is shown. This path is owned by the backup project, not this repo — the renderer is a read-only consumer that degrades silently when the file is missing.

## Input JSON schema

`statusline.sh` reads Claude Code's statusline payload. Fields consumed (all with `//` defaults in `jq`):

- `model.display_name`
- `session_id`
- `exceeds_200k_tokens`
- `cost.total_cost_usd`
- `cost.total_duration_ms`
- `cost.total_api_duration_ms` (true API wait time; shown as `API` on the Stats line when > 0)
- `context_window.used_percentage`
- `context_window.context_window_size` (model max window; shown as `1M` / `200k` on the Context line when > 0)
- `context_window.total_input_tokens`
- `context_window.total_output_tokens`
- `context_window.current_usage.cache_read_input_tokens`
- `context_window.current_usage.cache_creation_input_tokens`
- `thinking.enabled` (extended-thinking marker `✦` on the Model line when true)
- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`
- `workspace.current_dir` (falls back to `.cwd`)
- `effort.level` (omitted by Claude Code for models without effort support)
- `pr.number`, `pr.review_state` (PR indicator on line 1 when `.pr` is present; glyph/color by review_state)
- `worktree.name`, `worktree.branch` (worktree indicator on line 1 during `--worktree` sessions)
- `version` (Claude Code CLI version; dim `v<version>` suffix on the Model line). It reflects the **process actually running this session**, not the conversation thread: a continuous run reports a fixed version, but `--resume` launches a fresh process with the currently-installed CLI, so the displayed version updates if Claude Code was upgraded between exit and resume.

**Token-field semantics**: since Claude Code v2.1.132, `context_window.total_input_tokens` / `total_output_tokens` reflect the *current* context-window usage, not session-cumulative totals. The `Tokens` line's `In` / `Out` are labeled with that meaning.

**Gated fields**: the fields annotated above with "when present" / "when > 0" (`cost.total_api_duration_ms`, `context_window.context_window_size`, `thinking.enabled`, `pr.*`, `worktree.*`, `version`) are rendered only if the source field is non-empty/non-zero, so a line never shows a stray separator or placeholder for an absent field.

**Discipline**: every `jq` lookup must have a `//` default. The script must degrade gracefully if Claude Code renames, removes, or adds fields.

## Output layout (8 lines)

1. **Git info**: `<repo_name> ⬠ <branch> · +N -N`, then gated extras: ` · <glyph> PR #<n>` when `.pr` is present (glyph/color by `review_state`), and ` · ⎇ <worktree>` (magenta) during `--worktree` sessions — with `@<branch>` appended only when the worktree's branch differs from its name. When the session's account has been resolved, its `displayName` is prepended as a dim label in the shared label column (so the git info aligns with the Model/Context values); an attempted-but-failed resolution renders a yellow `?` in that slot instead. With no account file at all, this line is flush-left as below. Omitted entirely if CWD is unknown **and** no account label is present.
2. **`Model  `** — `<model>` + effort level, then ` ✦` (cyan) when `thinking.enabled` is true, then a dim ` · v<version>` suffix (the Claude Code CLI version) when `version` is present.
3. **`Context`** — 30-char progress bar, percentage, optional ` · <window_size>` (`1M` / `200k` from `context_window_size`), optional `compact Nx`.
4. **`Tokens `** — `In <X> · Out <Y> · Cache <pct>%`. When `exceeds_200k_tokens` is true, `⚠ 200k+` appears in red **before** `In` — i.e. `⚠ 200k+ · In X · Out Y · Cache Z%`. Note: this flag is set by Claude Code based on the current context window size, and `In`/`Out` are themselves current-context counts (see **Token-field semantics** above), so the warning can fire even when the displayed `In/Out` sum is well below 200k.
5. **`Stats  `** — `Cost $X.XX · Dur Xm Xs`, then ` · API Xm Xs` when `cost.total_api_duration_ms` > 0.
6. **`Limits `** — 20-char 5h bar, `5H <pct>%`, reset time
7. **(unlabeled, blank-label indent)** — 20-char 7d bar, `7D <pct>%`, reset time (indented by an empty label of the shared column width so the bar aligns under the 5h bar)
8. **Session id + timestamp** (unlabeled, dim, flush-left) — `<session_id> · YYYY.MM.DD HH:MM:SS`. When the `~/.claude` backup drift flag is present and non-empty, ` · ⚠ <drift_text>` (yellow) is appended on this same line — deliberately kept on line 8 so the line count stays at 8 and the UI never jumps.

### Alignment rules

- Lines 2–6 share a dim label column (`Model`, `Context`, `Tokens`, `Stats`, `Limits`), each left-padded to a common width and followed by one separator space. The width is **7 by default**, but widens to the account `displayName` length when the line-1 account label is present, so all labels — including line 1's account — line up in one column. All labels are produced by a single `pad_label` helper; at width 7 it reproduces the original hardcoded labels exactly, so absent-account output is byte-identical to the pre-account layout.
- Line 7's indent (DIM spaces of the same label width + one separator space) mirrors the `Limits` label structure so the 7d bar starts at the same column as the 5h bar.
- Line 8 is flush-left so it can be scanned or copied without leading indent — its raw session id is designed for `claude --resume <id>` (Claude Code does not support prefix matching, so the full UUID is shown). Line 1 is flush-left **only when no account is present**; with an account it joins the label column (the account is its label), trading flush-left for column alignment by design.

### Bar widths

- Context bar: **30 chars**
- 5h / 7d bars: **20 chars** each

If you change a width, update the matching `pct * N / 100` calculation.

### Width budget

Target: **every rendered line stays within ~60 visible columns** (measured after stripping ANSI escape codes, and excluding the line-8 ` · ⚠ <drift_text>` suffix that `claude-backup` may append). This keeps the statusline readable in narrow terminals and stable across themes.

The binding lines are data-driven:

- **Line 8** is effectively fixed at ~58 (36-char session UUID + ` · ` + 19-char timestamp) and is independent of the label column.
- **Lines 3 / 6 / 7** are `LABEL_W + bar(30 or 20) + value/reset text`, so they grow with the shared label-column width `LABEL_W` (`max(7, len(displayName))`). A `displayName` longer than ~14 chars can push the 5h/7d lines past 60.
- **Line 1** grows with `LABEL_W` plus the repo / branch / `+N -N` / PR / worktree extras.

**Rule**: if a design change (new field, wider bar, longer label) would push any line past ~60 columns for realistic data, **confirm the design with the user before shipping** instead of silently overflowing. A capping/truncation strategy for an over-long account label is a candidate solution to raise at that point. This mirrors `CLAUDE.md` → Conventions to preserve → "Line width budget".

## Color specification

ANSI palette defined at the top of `statusline.sh`: `RESET`, `CYAN`, `MAGENTA`, `GREEN`, `YELLOW`, `BLUE`, `RED`, `BRIGHT_RED`, `PURPLE`, `GOLD`, `BRIGHT_WHITE`, `DIM`.

### Context bar — smooth truecolor gradient (`\033[38;2;R;G;Bm`)

- **0–60%**: grayscale ramp. `R=G=B = 50 + (255-50) * USED / 60`. 0% → `(50,50,50)` darkest gray; 60% → `(255,255,255)` white.
- **60–70%**: white → yellow → red.
  - `R = 255` throughout.
  - `G = 255 - (USED-60) * 255 / 10` (255→0 across the full 10%).
  - `B = 255 - (USED-60) * 255 / 5` for `USED ≤ 65`, else `0` (drops 255→0 over the first half).
  - Waypoints: 60% = `(255,255,255)` white, 65% = `(255,128,0)` orange, 70% = `(255,0,0)` red.
- **>70%**: solid red `(255,0,0)`.

The context bar is **not** wrapped in DIM — the gradient renders at full intensity. Don't add DIM back.

### Rate limit bars (5h / 7d) — smooth truecolor gradient (`\033[38;2;R;G;Bm`)

- **0–50%**: grayscale ramp. `R=G=B = 50 + (255-50) * pct / 50`. 0% → `(50,50,50)` darkest gray; 50% → `(255,255,255)` white.
- **50–70%**: white → green. `R = B = 255 - (pct-50) * 255 / 20`; `G = 255`. Waypoint: 70% = `(0,255,0)` pure green.
- **70–80%**: green → yellow. `R = (pct-70) * 255 / 10`; `G = 255`; `B = 0`. Waypoint: 80% = `(255,255,0)` pure yellow.
- **80–90%**: yellow → red. `R = 255`; `G = 255 - (pct-80) * 255 / 10`; `B = 0`. Waypoint: 90% = `(255,0,0)` pure red.
- **>90%**: solid red `(255,0,0)`.

The bar is wrapped in DIM so the gradient reads softly against labels; the percentage uses the same truecolor **without** DIM so the number stays legible. The `Limits ` label, the `5H` / `7D` markers, and the `↺` reset separator are also DIM.

### Model family

- `*Fable*` / `*Mythos*` → `$GOLD` (256-color 214) — the Mythos-class tier above Opus
- `*Opus*` → `$PURPLE` (256-color 135)
- `*Haiku*` → `$GREEN`
- else → `$CYAN` (includes Sonnet)

### Effort level (mirrors Claude Code's `/effort` picker tokens)

Source: the stdin `effort.level` field. Claude Code emits one of the five tokens
below (it normalizes the session-scoped `ultracode` selection to `xhigh` upstream,
so `ultracode` never reaches the statusline as a literal). The field is **omitted**
entirely for models without effort support (e.g. Haiku 4.5, Sonnet 4.5, Opus 4.0/4.1).

| effort       | displayed   | statusline color | picker token         |
|--------------|-------------|------------------|----------------------|
| `low`        | `low`       | `$YELLOW`        | `warning`            |
| `medium`     | `medium`    | `$GREEN`         | `success`            |
| `high`       | `high`      | `$BLUE`          | `permission`         |
| `xhigh`      | `xhigh`     | `$MAGENTA`       | `autoAccept-shimmer` |
| `max`        | `max`       | `$BRIGHT_WHITE`  | `rainbow-animated`   |
| *(omitted)*  | `—`         | `$DIM`           | model has no effort  |
| *(any other)*| `unknown`   | `$BRIGHT_RED`    | schema drift         |

`max` uses bright white because the statusline is stateless one-shot output and cannot
animate a rainbow. The five known mappings use the ANSI equivalent of the `/effort`
picker's semantic color token (discovered by inspecting Claude Code's binary).

**No silent fallback.** A missing `effort.level` is a legitimate state (the model has
no effort concept) and renders as a dim `—`. A *present but unrecognized* value is
treated as genuine schema drift and rendered as a loud bright-red `unknown`, so a future
Claude Code token rename or addition is immediately visible rather than masked.

## Cross-platform date handling

Timestamp formatting must support both macOS (BSD `date`) and Linux (GNU `date`):

```bash
date -r "$EPOCH" "+%H:%M" 2>/dev/null || date -d "@$EPOCH" "+%H:%M" 2>/dev/null
```

Keep this fallback whenever adding new time displays.

Bars must be built by **concatenating the glyph N times** (the `repeat_glyph` helper in `statusline.sh`; an inline loop in `docs/swatches.sh`), never `tr ' ' '█'`. `tr` maps *bytes*, so GNU coreutils turns each 3-byte bar glyph (`█` = `E2 96 88`) into a lone `E2` (invalid UTF-8); only BSD `tr` rendered the multibyte glyph. The bars therefore looked correct on macOS but were corrupted on Linux until switched to concatenation. Mirror this for any new bar.

## Testing

No test framework. Pipe a sample JSON payload to preview:

```bash
echo '{"model":{"display_name":"Claude Opus 4.7"},"session_id":"abc","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},"context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$(($(date +%s)+3600))"'},"seven_day":{"used_percentage":8,"resets_at":'"$(($(date +%s)+86400))"'}},"workspace":{"current_dir":"'"$PWD"'"}}' | ./statusline.sh
```

To test the compact hook, either seed `/tmp/claude-compacts-<sanitized_id>.json` manually with `{"count":N}`, or trigger `/compact` in a real Claude Code session. The renderer picks up the count on its next invocation.

To test the account hook end to end, feed it a session id and inspect what it publishes:

```bash
echo '{"session_id":"testsession-1234"}' | bash hooks/account-monitor.sh   # prints nothing
sleep 2 && cat /tmp/claude-account-testsession1234.json                    # {"displayName":"...", ...}
```

Force the failure path (which must render as a yellow `?`, never as a wrong name) by pointing it at a credential that resolves to nobody:

```bash
CLAUDE_CODE_OAUTH_TOKEN=not-a-real-token bash -c 'echo "{\"session_id\":\"bogus-01\"}" | bash hooks/account-monitor.sh'
sleep 6 && cat /tmp/claude-account-bogus01.json                            # {"displayName":null,"error":...}
```

## Install / wiring

Symlink the scripts into `~/.claude/` so `settings.json` references stable paths that don't depend on the repo's clone location:

```
~/.claude/statusline.sh             → <repo>/statusline.sh
~/.claude/hooks/compact-monitor.sh  → <repo>/hooks/compact-monitor.sh
~/.claude/hooks/account-monitor.sh  → <repo>/hooks/account-monitor.sh
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
    ],
    "SessionStart": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "bash ~/.claude/hooks/account-monitor.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "bash ~/.claude/hooks/account-monitor.sh" }
        ]
      }
    ]
  }
}
```

`SessionStart` resolves the account for a new/resumed session; `UserPromptSubmit` re-checks it so an account switch mid-session is picked up on the next prompt rather than at the next session. Both are cheap: the hook returns immediately and the resolution runs detached, hitting the network only when the credential's fingerprint is not already cached.

Edits to the repo take effect immediately on the next statusline refresh — no reload needed, since the symlinks resolve to the live files. Without the `PreCompact` hook wired, the `compact Nx` counter stays at 0; without the account hooks wired, line 1 shows no account label. The rest of the statusline works in both cases.
