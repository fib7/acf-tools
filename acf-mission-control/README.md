# Mission Control: a status line for Claude Code

A two-line HUD. The first line shows the model, directory and git branch. The second shows how full
the context window is (1M-context models included), session cost, duration, lines changed, whether
the prompt cache is still warm, and your 5-hour and 7-day rate limits.

## What it shows

```
◆ Opus · ▸ acf-tools · ⎇ main ✎3 ⊕2
▰▰▱▱▱▱▱▱▱▱ 18% · 200k · ≈$0.42 · 12m · +156/-23 · ● warm · 5h 23% 7d 41%
```

| Segment | Source | Notes |
|---------|--------|-------|
| ◆ model | `model.display_name` | Color per family (see below); ` [1m]` on 1M-context models |
| ▸ dir | `workspace.current_dir` | Basename only |
| ⎇ branch | `git` / `worktree.branch` | `✎N` modified, `⊕N` staged |
| ▰▱ fuel bar | `context_window.used_percentage` | Pre-calculated by Claude Code (input-only); never parses the transcript |
| window | `context_window.context_window_size` | `200k` or `1M`, detected automatically |
| cost | transcript usage × LiteLLM rates | `≈` marks a self-priced figure (see below); falls back to `cost.total_cost_usd` |
| duration | `cost.total_duration_ms` | Session wall-clock |
| +/- lines | `cost.total_lines_added/removed` | Lines changed this session |
| ● cache | transcript mtime vs 5-min TTL | Warmth heuristic (see below) |
| 5h / 7d | `rate_limits.*.used_percentage` | Pro/Max only; hidden otherwise |

Model, dir, branch and the fuel bar always show. You can toggle the rest, and each one hides itself
when its data is absent.

Glyphs come in themes, set by `CONFIG["glyphs"]` (default `sleek`). See
[Customization](#customization).

## Color

Each hue means one thing, so a problem stands out and routine metadata stays in the background.

| Color | Meaning |
|-------|---------|
| Per-model | Opus magenta, Sonnet cyan, Haiku green, Fable blue, so a session on the wrong model is obvious |
| Green / Yellow / Red | Health zones, used for the fuel bar **and its %**, rate limits, cost, and cache warmth |
| Anchor glyphs | Line-1 icons keep a fixed hue so each segment is easy to find: model `◆` in its family color, dir `▸` blue, branch `⎇` cyan (line-art themes `sleek`/`nerd`) |
| Dim | Background metadata (separators, directory, window size, duration) |
| Bright cyan | A `1M` window |

**Fuel zones**: green `<70%` · yellow `70–89%` · red `≥90%` (auto-compact triggers well above the
old 70% red). **Cost**: dim `<$5` · yellow `≥$5` · red `≥$20`.

Color never carries information on its own. The bar's filled and empty glyphs and the numbers say
the same thing, so colorblind users and no-color terminals lose nothing. The script honors the
`NO_COLOR` environment variable and a `CONFIG['color']` master switch.

## Cost that survives a proxy

Claude Code only prices models it ships rates for. Point it at a gateway (LiteLLM, OpenRouter,
Bedrock, a self-hosted endpoint) and `cost.total_cost_usd` reads **$0.00** for the whole session,
whatever you spend.

Mission Control prices the session itself:

1. Rates come from [LiteLLM's model price table](https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json)
   (~2.5k models), distilled to the five token-billing fields and cached under
   `~/.cache/acf-mission-control/`. The cache refreshes once a day in a detached process, so the
   status line never waits on the network.
2. Provider prefixes are treated as routing: `nebius/zai-org/GLM-5.2` is GLM-5.2 served by nebius.
   Segments are dropped left to right until an entry matches, then the bare model name is looked
   up wherever it's published.
3. Tokens come from the session transcript, deduplicated by request. Claude Code writes one record
   per content block and repeats the whole request's usage in each, so a naive sum overstates cost
   3-4×. Cache reads and 5-minute vs 1-hour cache writes are billed at their own rates.
4. **Subagents count.** Subagent and workflow conversations go to sibling transcripts under
   `<transcript>/subagents/`, not into the main transcript. On a workflow-heavy session they can
   cost several times the main thread: one measured session read `≈$6.03` from the main transcript
   alone and `$25.71` with its 24 subagent transcripts folded in. Every sibling is scanned, each
   with its own byte cursor, so the scan stays incremental.
5. **Speed tiers multiply the rate.** Rate tables publish `provider_specific_entry`
   (e.g. `{"us": 1.1, "fast": 2.0}`), and fast mode bills the same model at double. Totals are
   bucketed per `(model, speed)` and each bucket is priced with its multiplier.

| Reading | Meaning |
|---------|---------|
| `≈$4.18` | Self-priced from the rate table |
| `≈$4.18?` | Self-priced, but part of the session couldn't be priced exactly. It reads **low** when a model resolved to no entry, and **high** when only a cache rate was missing and those tokens fell back to the input rate |
| `$4.18` | No `≈`: Claude Code's own figure (price map absent, or `price_map: False`) |

Most rate entries publish no cache-read price (72% of the table), yet cache reads are ~90% of a
session's tokens. Charging them at the input rate is the only estimate available, and it overstates
by ~4×, so the figure gets a `?` instead of passing as exact. Gateway-served Claude ids
(`databricks/databricks-claude-*`, `gmi/anthropic/claude-*`, `bedrock/*/anthropic.claude-*`) hit
this: they resolve to their own entries, so they never fall through to a more complete one.

To see which entry a model resolves to:

```bash
.claude/scripts/status-line.py --price-check nebius/zai-org/GLM-5.2
.claude/scripts/status-line.py --refresh-prices      # force a refresh now
```

If a model resolves to the wrong entry, or to none, pin it in `CONFIG["price_aliases"]`:
`{"nebius/zai-org/GLM-5.2": "zai/glm-5.2"}`.

Rates are list prices, so the figure is an estimate, not an invoice. It ignores negotiated
discounts, subscription plans (where marginal cost is $0), and batch or priority tiers.

## Cache warmth

Claude Code prompt-caches your conversation. The cache TTL is **5 minutes, sliding**: every turn
resets it. Stay idle past it and your **next message misses the cache**. The whole conversation is
processed and written again at ~1.25× input cost, with higher latency, instead of a cheap ~0.1×
cache read.

The indicator estimates this from the time since your last turn:

| State | Idle time | Meaning |
|-------|-----------|---------|
| ● warm | `< 4 min` | Next turn is a cheap cache read |
| ◐ cooling | `4–5 min` | TTL about to lapse |
| ○ cold | `≥ 5 min` | Next turn reprocesses the whole conversation |

It's a **heuristic**. The API doesn't expose the real cache state, so the indicator reads the
transcript file's modification time. To keep it moving toward "cold" while you're idle, setup adds
`"refreshInterval": 30` to your `statusLine` settings, unless you already set one.

## Installation

```bash
/plugin install acf-mission-control@acf-tools
# Restart Claude Code — the status line auto-configures on first session.
```

On the first `SessionStart`, the plugin copies `status-line.py` into your repo at
`.claude/scripts/`, makes it executable, and points `statusLine` in `.claude/settings.json` at that
copy when no `statusLine` is configured yet. From then on the script is part of your repo: it keeps working after you uninstall the plugin,
and you can customize it per project.

**Requirements**: Python 3.6+ (standard library only). `git` is optional (branch display). A
terminal with ANSI color. The default `sleek` theme and the `text` theme use only standard Unicode
and need no special font; `emoji` and `nerd` are opt-in.

## Self-upgrading

The local copy doesn't go stale. On every `SessionStart` the setup hook compares the
`# mission-control-version:` marker in the shipped plugin with the one in your
`.claude/scripts/status-line.py` (semantic-version compare):

- **Plugin newer** → your copy is replaced, and the previous one is saved to `status-line.py.bak`,
  so you can diff a customized copy back in.
- **Same version** → nothing happens.
- **Local newer** → left alone (never downgraded).

New plugin releases reach your copy on their own. A `price_map: False` setting is carried into the
new copy; any other edit has to come back from the `.bak`. **To pin** your own version, bump the
marker in your local copy above the plugin's. **To opt out**, remove the `SessionStart` hook.

## Customization

Edit the `CONFIG` block at the top of `.claude/scripts/status-line.py`. Changes apply on the next
status-line update, with no reinstall.

```python
CONFIG = {
    "cost": True, "rate_limits": True, "git_dirty": True,
    "duration": True, "lines": True, "cache": True,
    "glyphs": "sleek", "color": True, "single_line": False, "bar_width": 10,
    "cache_ttl": 300, "ctx_warn": 70, "ctx_crit": 90,
    "cost_warn": 5.0, "cost_crit": 20.0,
    "price_map": True, "price_ttl": 86400, "price_aliases": {},
}
```

- Turn any optional segment on or off.
- `glyphs` picks the icon theme: `sleek` (default, monochrome geometric), `emoji` (the original
  pictographs), `nerd` (Nerd Font glyphs; needs a Nerd Font installed), or `text` (no icons, only
  color and labels). Each theme's glyphs live in the `GLYPHS` dict; edit a slot there to swap one
  icon.
- `single_line: True` collapses both rows into one.
- Tune thresholds, bar width, or the cache TTL (set it to `3600` if you use the 1-hour extended
  cache).
- `price_map: False` reverts the cost segment to Claude Code's own figure and stops all network
  access; `price_aliases` pins a model id to a rate-table key.
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
| Color codes shown literally | The terminal lacks ANSI support. Use iTerm2 / Windows Terminal / kitty, or set `NO_COLOR=1` |
| Percentage looks off vs `/context` | Expected: they're sampled at different moments, and `used_percentage` is input-only |
| Rate limits missing | Only present for Pro/Max after the first API response; hidden otherwise |
| Cache always "cold" | The indicator needs `refreshInterval` (added by setup) and a valid `transcript_path` |
| Branch missing | Not in a git repo, or `git` not installed |
| Cost shows `$0.00` (no `≈`) | **Check the installed version first**: `grep '# mission-control-version:' .claude/scripts/status-line.py` must be ≥1.3.0. A pre-1.3.0 copy has no self-pricing and echoes Claude Code's figure, which is `$0.00` for any model it can't price. The plugin upgrades from the *published* marketplace, so a version that exists only in your working tree never installs. If the version is fine, the rate table isn't cached: run `--refresh-prices` and check network access to raw.githubusercontent.com |
| Cost shows `≈$0.00` | The model resolved to a zero-rate entry (a free or placeholder tier sharing its name). Confirm with `--price-check <model-id>` and pin the right key in `price_aliases`. 1.3.1 drops zero-rate entries; on an older cache, `--refresh-prices` clears it |
| Cost shows a trailing `?` | Part of the session couldn't be priced exactly. Either a model has no rate entry (the figure reads low) or its entry publishes no cache rate, so those tokens were billed at the input rate (reads high, up to ~4×). Find it with `--price-check <model-id>`, then pin `price_aliases` |
| Cost looks 3-4× too high | A stale pre-1.3.0 copy is installed; confirm `# mission-control-version:` is ≥1.3.0 |
| Cost looks far too low on a session that ran subagents | Copies before 1.3.1 counted only the main transcript and skipped `<transcript>/subagents/`, which often carries most of the spend |

Test it directly with mock input:

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":25,"context_window_size":200000},"session_id":"test"}' | .claude/scripts/status-line.py
```

## Performance

Negligible. One optional `git` shell-out, cached per session for 5s (keyed on `session_id`, as
Claude Code recommends). Pricing reads a 200KB distilled rate table and parses **only the transcript
bytes appended since the last render**. State is kept in `/tmp` keyed by session, so a 3.8MB
transcript costs ~50ms warm and ~100ms on the first cold scan. Network fetches always run in a
detached process; the status line never blocks on one. It runs after each assistant message
(debounced 300ms), plus the 30s idle refresh for the cache indicator.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Email: acf@fib7.ai
