# Mission Control - Claude Code Status Line

**Ground Control to Major Tom... your context fuel is color-coded.** 🚀

A two-line "Mission Control" HUD for Claude Code: an accurate, 1M-context-aware
fuel gauge plus the telemetry that actually changes how you work — session cost,
rate limits, git state, and a prompt-cache-warmth indicator no other status line
surfaces.

## What it shows

```
🚀 Opus · 📁 acf-tools · 🌿 main ✎3 ⊕2
⛽ [███░░░░░░░] 18% · 200k · 💰$0.42 · ⏱12m · +156/-23 · 🔥 warm · 5h 23% 7d 41%
```

| Segment | Source | Notes |
|---------|--------|-------|
| 🚀 model | `model.display_name` | Color per family (see below); ` [1m]` on 1M-context models |
| 📁 dir | `workspace.current_dir` | Basename only |
| 🌿 branch | `git` / `worktree.branch` | `✎N` modified, `⊕N` staged |
| ⛽ fuel bar | `context_window.used_percentage` | Pre-calculated by Claude Code (input-only); never parses the transcript |
| window | `context_window.context_window_size` | `200k` or `1M` — auto-detected |
| 💰 cost | `cost.total_cost_usd` | Session estimate |
| ⏱ duration | `cost.total_duration_ms` | Session wall-clock |
| +/- lines | `cost.total_lines_added/removed` | Lines changed this session |
| 🔥 cache | transcript mtime vs 5-min TTL | Warmth heuristic (see below) |
| 5h / 7d | `rate_limits.*.used_percentage` | Pro/Max only; auto-hidden otherwise |

Core segments (model, dir, branch, fuel bar) are always shown. The rest are
toggleable and auto-hide when their data is absent.

## Color: semantic, not decorative

Each hue means one thing, so critical state jumps out and routine metadata recedes.

| Color | Meaning |
|-------|---------|
| Per-model | 🟣 Opus · 🔵 Sonnet (cyan) · 🟢 Haiku · 🔷 Fable — spot "I'm on the wrong model" instantly |
| Green / Yellow / Red | Health zones, reused for the fuel bar **and its %**, rate limits, cost, and cache warmth |
| Dim | Recessive metadata (separators, directory, window size, duration) |
| Bright cyan | A `1M` window (capability highlight) |

**Fuel zones**: green `<70%` · yellow `70–89%` · red `≥90%` (auto-compact triggers
well above the old 70% red). **Cost**: dim `<$5` · yellow `≥$5` · red `≥$20`.

Color is never the *only* signal — bar glyphs (`█`/`░`) and numbers carry the same
information, so colorblind and no-color terminals lose nothing. Honors the
`NO_COLOR` environment variable and a `CONFIG['color']` master switch.

## Cache warmth 🔥 — the unique signal

Claude Code prompt-caches your conversation. The cache TTL is **5 minutes,
sliding** (every turn resets it). Idle past it and your **next message is a cache
miss**: the whole conversation is re-processed and re-written at ~1.25× input cost
with higher latency, instead of a cheap ~0.1× cache read.

The indicator estimates this from how long since your last turn:

| State | Idle time | Meaning |
|-------|-----------|---------|
| 🔥 warm | `< 4 min` | Next turn is a cheap cache read |
| 🔥 cooling | `4–5 min` | TTL about to lapse |
| ❄ cold | `≥ 5 min` | Next turn reprocesses the whole conversation |

It's a **heuristic** (true cache state isn't exposed by the API) derived from the
transcript file's modification time. To keep it ticking toward "cold" while you're
idle, setup injects `"refreshInterval": 30` into your `statusLine` settings.

## Installation

```bash
/plugin install acf-mission-control@acf-tools
# Restart Claude Code — the status line auto-configures on first session.
```

On first `SessionStart` the plugin copies `status-line.py` into your repo at
`.claude/scripts/`, makes it executable, and points `statusLine` in
`.claude/settings.json` at the local copy. The script becomes part of your repo —
it keeps working after the plugin is uninstalled and can be customized per project.

**Requirements**: Python 3.6+ (standard library only). `git` optional (branch
display). A modern terminal for ANSI colors and emoji.

## Self-upgrading

The local copy doesn't go stale. On every `SessionStart` the setup hook compares
the `# mission-control-version:` marker in the shipped plugin against your local
`.claude/scripts/status-line.py` (semantic-version compare):

- **Plugin newer** → your copy is replaced, and the previous one is saved to
  `status-line.py.bak` (so a customized copy is recoverable — diff it back in).
- **Same version** → no-op.
- **Local newer** → left alone (never downgraded).

Every future plugin release therefore propagates automatically. **To pin** your
own version, bump the marker in your local copy above the plugin's; **to opt out**,
remove the `SessionStart` hook.

## Customization

Edit the `CONFIG` block at the top of `.claude/scripts/status-line.py`. Changes
apply on the next status-line update — no reinstall.

```python
CONFIG = {
    "cost": True, "rate_limits": True, "git_dirty": True,
    "duration": True, "lines": True, "cache": True,
    "color": True, "single_line": False, "bar_width": 10,
    "cache_ttl": 300, "ctx_warn": 70, "ctx_crit": 90,
    "cost_warn": 5.0, "cost_crit": 20.0,
}
```

- Toggle any optional segment on/off.
- `single_line: True` collapses both rows into one.
- Tune thresholds, bar width, or the cache TTL (set to `3600` if you use the
  1-hour extended cache).
- Per-model colors live in the `MODEL_COLORS` dict.

## Uninstallation

```bash
/plugin uninstall acf-mission-control
# The status line keeps working (local copy). To remove it:
rm .claude/scripts/status-line.py        # and the .bak if present
# then delete the "statusLine" block from .claude/settings.json
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No status line | `chmod +x .claude/scripts/status-line.py`; confirm `statusLine` in `.claude/settings.json`; `claude --debug` shows exit code/stderr |
| Color codes shown literally | Terminal lacks ANSI support — use iTerm2 / Windows Terminal / kitty, or set `NO_COLOR=1` |
| Percentage looks off vs `/context` | Expected — they're sampled at different moments; `used_percentage` is input-only |
| Rate limits missing | Only present for Pro/Max after the first API response; auto-hidden otherwise |
| Cache always "cold" | The indicator needs `refreshInterval` (auto-injected) and a valid `transcript_path` |
| Branch missing | Not in a git repo, or `git` not installed |

Test it directly with mock input:

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":25,"context_window_size":200000},"session_id":"test"}' | .claude/scripts/status-line.py
```

## Performance

Negligible: no network, no transcript parsing. One optional `git` shell-out,
cached per session for 5s (keyed on `session_id`, per Claude Code's recommended
pattern). Runs after each assistant message (debounced 300ms) plus the 30s idle
refresh for the cache indicator.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Email: acf@fib7.ai

---

**Mission Control out.** 🚀
