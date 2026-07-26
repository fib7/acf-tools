# Mission Control - Claude Code Status Line

**Ground Control to Major Tom... your context fuel is color-coded.** 🚀

A two-line "Mission Control" HUD for Claude Code: an accurate, 1M-context-aware
fuel gauge plus the telemetry that actually changes how you work — session cost,
rate limits, git state, and a prompt-cache-warmth indicator no other status line
surfaces.

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
| window | `context_window.context_window_size` | `200k` or `1M` — auto-detected |
| cost | transcript usage × LiteLLM rates | `≈` marks a self-priced figure (see below); falls back to `cost.total_cost_usd` |
| duration | `cost.total_duration_ms` | Session wall-clock |
| +/- lines | `cost.total_lines_added/removed` | Lines changed this session |
| ● cache | transcript mtime vs 5-min TTL | Warmth heuristic (see below) |
| 5h / 7d | `rate_limits.*.used_percentage` | Pro/Max only; auto-hidden otherwise |

Core segments (model, dir, branch, fuel bar) are always shown. The rest are
toggleable and auto-hide when their data is absent.

Glyphs are themeable via `CONFIG["glyphs"]` (default `sleek`) — see
[Customization](#customization).

## Color: semantic, not decorative

Each hue means one thing, so critical state jumps out and routine metadata recedes.

| Color | Meaning |
|-------|---------|
| Per-model | 🟣 Opus · 🔵 Sonnet (cyan) · 🟢 Haiku · 🔷 Fable — spot "I'm on the wrong model" instantly |
| Green / Yellow / Red | Health zones, reused for the fuel bar **and its %**, rate limits, cost, and cache warmth |
| Anchor glyphs | Line-1 icons carry a stable identity hue so segments are findable at a glance — model `◆` in its family color, dir `▸` blue, branch `⎇` cyan (line-art themes `sleek`/`nerd`) |
| Dim | Recessive metadata (separators, directory, window size, duration) |
| Bright cyan | A `1M` window (capability highlight) |

**Fuel zones**: green `<70%` · yellow `70–89%` · red `≥90%` (auto-compact triggers
well above the old 70% red). **Cost**: dim `<$5` · yellow `≥$5` · red `≥$20`.

Color is never the *only* signal — bar glyphs (`█`/`░`) and numbers carry the same
information, so colorblind and no-color terminals lose nothing. Honors the
`NO_COLOR` environment variable and a `CONFIG['color']` master switch.

## Cost that survives a proxy

Claude Code only prices models it ships rates for. Point it at a gateway —
LiteLLM, OpenRouter, Bedrock, a self-hosted endpoint — and `cost.total_cost_usd`
reads **$0.00** for the whole session no matter how much you spend.

Mission Control prices the session itself instead:

1. Rates come from [LiteLLM's model price table](https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json)
   (~2.5k models), distilled to the five token-billing fields and cached under
   `~/.cache/acf-mission-control/`. Refreshed once a day, always detached — the
   status line never waits on the network.
2. Provider prefixes are treated as routing, not identity: `nebius/zai-org/GLM-5.2`
   is GLM-5.2 served by nebius. Segments are dropped left to right until an entry
   matches, then the bare model name is looked up wherever it's published.
3. Tokens come from the session transcript, deduplicated by request — Claude Code
   writes one record per content block and repeats the whole request's usage in
   each, so naive summing overstates cost 3-4×. Cache reads and 5-minute vs 1-hour
   cache writes are billed at their own rates.
4. **Subagents count.** Subagent and workflow conversations are written to sibling
   transcripts under `<transcript>/subagents/`, not into the transcript itself. On
   a workflow-heavy session they routinely outweigh the main thread — one measured
   session read `≈$6.03` from the main transcript alone and `$25.71` with its 24
   subagent transcripts folded in. Every sibling is scanned, each with its own byte
   cursor so the scan stays incremental.
5. **Speed is a multiplier, not a model.** Rate tables publish
   `provider_specific_entry` (e.g. `{"us": 1.1, "fast": 2.0}`) — fast mode bills the
   same model at double. Totals bucket per `(model, speed)` and price accordingly.

| Reading | Meaning |
|---------|---------|
| `≈$4.18` | Self-priced from the rate table |
| `≈$4.18?` | Self-priced, but part of the session couldn't be priced exactly — reads **low** when a model resolved to no entry, **high** when only a cache rate was missing and those tokens fell back to the input rate |
| `$4.18` | No `≈`: Claude Code's own figure (price map absent, or `price_map: False`) |

A rate entry that publishes no cache-read price is the common case, not the
exception — 72% of the table — while cache reads are ~90% of a session's tokens.
Charging them at the input rate is the only estimate available, but it overstates
by ~4×, so the `?` is raised rather than letting the figure pass as authoritative.
This is reachable on gateway-served Claude ids (`databricks/databricks-claude-*`,
`gmi/anthropic/claude-*`, `bedrock/*/anthropic.claude-*`), which resolve to
themselves and so never fall through to a more complete entry.

Diagnose a mapping without guessing:

```bash
.claude/scripts/status-line.py --price-check nebius/zai-org/GLM-5.2
.claude/scripts/status-line.py --refresh-prices      # force a refresh now
```

If a model resolves to the wrong entry — or to none — pin it in
`CONFIG["price_aliases"]`: `{"nebius/zai-org/GLM-5.2": "zai/glm-5.2"}`.

Rates are list prices, so the figure is an estimate, not an invoice: it ignores
negotiated discounts, subscription plans (where marginal cost is $0), and batch
or priority tiers.

## Cache warmth — the unique signal

Claude Code prompt-caches your conversation. The cache TTL is **5 minutes,
sliding** (every turn resets it). Idle past it and your **next message is a cache
miss**: the whole conversation is re-processed and re-written at ~1.25× input cost
with higher latency, instead of a cheap ~0.1× cache read.

The indicator estimates this from how long since your last turn:

| State | Idle time | Meaning |
|-------|-----------|---------|
| ● warm | `< 4 min` | Next turn is a cheap cache read |
| ◐ cooling | `4–5 min` | TTL about to lapse |
| ○ cold | `≥ 5 min` | Next turn reprocesses the whole conversation |

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
display). A terminal with ANSI color (the default `sleek`/`text` glyph themes use
only standard Unicode — no special font; the `emoji` and `nerd` themes are opt-in).

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
    "glyphs": "sleek", "color": True, "single_line": False, "bar_width": 10,
    "cache_ttl": 300, "ctx_warn": 70, "ctx_crit": 90,
    "cost_warn": 5.0, "cost_crit": 20.0,
    "price_map": True, "price_ttl": 86400, "price_aliases": {},
}
```

- Toggle any optional segment on/off.
- `glyphs` picks the icon theme — `sleek` (default, monochrome geometric),
  `emoji` (the original pictographs), `nerd` (Nerd-Font glyphs — needs a Nerd
  Font installed), or `text` (no icons; color + labels only). Each theme's glyph
  table lives in the `GLYPHS` dict; edit a slot there to swap a single icon.
- `single_line: True` collapses both rows into one.
- Tune thresholds, bar width, or the cache TTL (set to `3600` if you use the
  1-hour extended cache).
- `price_map: False` reverts the cost segment to Claude Code's own figure and
  stops all network access; `price_aliases` pins a model id to a rate-table key.
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
| Cost shows `$0.00` (no `≈`) | **Check the installed version first** — `grep '# mission-control-version:' .claude/scripts/status-line.py` must be ≥1.3.0. A pre-1.3.0 copy has no self-pricing at all and just echoes Claude Code's figure, which is `$0.00` for any model it can't price. Note the plugin upgrades from the *published* marketplace, so a version that exists only in your working tree will never install. If the version is fine, the rate table isn't cached — run `--refresh-prices` and check network access to raw.githubusercontent.com |
| Cost shows `≈$0.00` | The model resolved to a zero-rate entry (a free or placeholder tier sharing its name). Confirm with `--price-check <model-id>` and pin the right key in `price_aliases`. Fixed in 1.3.1, which drops zero-rate entries — on an older cache, `--refresh-prices` clears it |
| Cost shows a trailing `?` | Part of the session couldn't be priced exactly: either a model has no rate entry (figure reads low) or its entry publishes no cache rate, so those tokens billed at the input rate (reads high, up to ~4×). Find it with `--price-check <model-id>`, then pin `price_aliases` |
| Cost looks 3-4× too high | A stale pre-1.3.0 copy is installed; confirm `# mission-control-version:` is ≥1.3.0 |
| Cost looks far too low on a session that ran subagents | Pre-1.3.1 copies counted only the main transcript and skipped `<transcript>/subagents/`, which often carries most of the spend |

Test it directly with mock input:

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":25,"context_window_size":200000},"session_id":"test"}' | .claude/scripts/status-line.py
```

## Performance

Negligible. One optional `git` shell-out, cached per session for 5s (keyed on
`session_id`, per Claude Code's recommended pattern). Cost pricing reads a 200KB
distilled rate table and parses **only the transcript bytes appended since the
last render** — state is kept in `/tmp` keyed by session, so a 3.8MB transcript
costs ~50ms warm, ~100ms on the first cold scan. Network fetches always run in a
detached process; the status line itself never blocks on one. Runs after each
assistant message (debounced 300ms) plus the 30s idle refresh for the cache
indicator.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Email: acf@fib7.ai

---

**Mission Control out.** 🚀
