# claude-statusline

A custom 8-line colored statusline for [Claude Code](https://claude.com/claude-code). Drop-in Bash script — no build, no dependencies beyond `jq` and (optionally) `git`.

## What it looks like

```
claude-statusline ⬠ main · +25 -7
Model   Claude Opus 4.7  xhigh
Context ██████████░░░░░░░░░░░░░░░░░░░░ 35%
Tokens  In 1.2k · Out 800 · Cache 75%
Stats   Cost $0.12 · Dur 0m 42s
Limits  ████░░░░░░░░░░░░░░░░ 5H 22% ↺ 1h (01:35)
        █░░░░░░░░░░░░░░░░░░░ 7D 8% ↺ 1d (04/23 00:35)
abc12345-6789-defg-hijk-lmnopqrstuvw · 2026.04.22 00:35:17
```

## Features

- **Smooth truecolor context bar** — dark gray → white → yellow → red gradient. White at 60%, pure red at 70%+. Reads cooler during headroom, gets loud at the danger zone.
- **Separate 5h / 7d rate-limit bars** with discrete green / yellow / red zones and `↺` reset times.
- **Git line** up top: repo name, branch, `+N -N` diff counts.
- **Effort-level color matches Claude Code's `/effort` picker** (low=yellow, medium=green, high=blue, xhigh=magenta, max=bright white).
- **Compact counter** — a companion `PreCompact` hook tracks how many times `/compact` has fired this session; the renderer surfaces it as `compact Nx` on the context line.
- **Raw session id on the last line** — copy-pasteable into `claude --resume <id>` (Claude Code doesn't do prefix matching, so the full UUID is shown).

## Requirements

- `jq`
- `git` (optional; only used for the git info line)
- A terminal with 24-bit truecolor support — macOS Terminal.app ≥ 10.14, iTerm2, Alacritty, kitty, WezTerm, Ghostty, modern tmux, etc.

## Install

1. Clone this repo anywhere.
2. Symlink the scripts into `~/.claude/`:
   ```bash
   ln -s "$PWD/statusline.sh"                 ~/.claude/statusline.sh
   mkdir -p ~/.claude/hooks
   ln -s "$PWD/hooks/compact-monitor.sh"      ~/.claude/hooks/compact-monitor.sh
   ```
3. Add to `~/.claude/settings.json`:
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
4. Restart Claude Code or wait for the next statusline refresh.

The `PreCompact` hook is what drives the `compact Nx` counter. Without it wired, the counter stays at 0 — the rest of the statusline works fine.

## Testing

Pipe a sample JSON payload through the script to preview output without going through Claude Code:

```bash
echo '{"model":{"display_name":"Claude Opus 4.7"},"session_id":"abc","cost":{"total_cost_usd":0.12,"total_duration_ms":42000},"context_window":{"used_percentage":35,"total_input_tokens":1200,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300}},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":'"$(($(date +%s)+3600))"'},"seven_day":{"used_percentage":8,"resets_at":'"$(($(date +%s)+86400))"'}},"workspace":{"current_dir":"'"$PWD"'"}}' | ./statusline.sh
```

## Spec

See [`SPEC.md`](SPEC.md) for the authoritative layout, color formulas, IPC invariants, and JSON contract.
