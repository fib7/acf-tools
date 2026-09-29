# acf-mission-control changelog

All notable changes to acf-mission-control. The format loosely follows Keep a Changelog.

## 1.3.1: the self-priced figure covers the whole session

1.3.0 added self-pricing so proxied models would stop reading `$0.00`. An audit before release showed
the figure could still be wrong, sometimes by 4x and sometimes still zero. This release fixes what it
can and marks the figure with `?` where it can't.

- **Subagent and workflow tokens are counted.** They live in sibling transcripts under
  `<transcript>/subagents/`, not in the transcript itself, so the previous total skipped them even
  though the code said it counted them. On a workflow-heavy session they can be several times the
  main thread: one measured session read `≈$6.03` when its real cost was `$25.71`. `scan_usage` now folds
  in every sibling transcript and keeps a byte cursor per file, so the scan stays incremental.
- **A zero rate no longer prices anything.** `distill_prices` kept any entry whose `input`/`output`
  costs were present, even at `0.0`, so free and placeholder tiers survived: 130 of them in a current
  table, 9 sharing a basename with a real model. A collision produced a confident `≈$0.00` that
  suppressed Claude Code's own figure, which is the exact bug self-pricing was added to remove.
  Distillation now drops such entries, and `session_cost` refuses to count one as priced even when it
  comes from an older cache.
- **Substituted cache rates are flagged.** 72% of published entries carry no cache-read price and
  90% none for cache writes, while cache reads are ~90%+ of a session's tokens. Billing them at the
  input rate is the only estimate available, and it overstates by ~4x, so it now raises the `?`
  marker instead of passing as fully priced. Gateway-served Claude ids hit this today
  (`databricks/databricks-claude-*`, `gmi/anthropic/claude-*`, `bedrock/*/anthropic.claude-*`, …):
  they resolve to their own entries, so the fallback that prefers a more complete entry never
  applies to them.
- **Speed multipliers are applied.** Rate tables publish `provider_specific_entry`
  (e.g. `{"us": 1.1, "fast": 2.0}`), and fast mode bills the same model at double. Totals are now
  bucketed per `(model, speed)`, and each bucket is priced with its own multiplier.
- **Context-window variants resolve.** `claude-opus-5[1m]` matched nothing, so a 1M-context session
  priced at `$0` with a silent `?`. A trailing bracket marks a variant of the same model, so when the
  exact id finds no entry, the lookup now retries with the bracket stripped.
- **JSONL is split on newlines only.** `str.splitlines()` also breaks on U+2028/U+2029/U+0085, which
  JSON encoders emit raw inside strings. A record containing one was torn into unparseable fragments,
  and because the byte offset still advanced, it was lost for good.
- **requestId dedup is exact.** The 64-entry ring could roll past an id and count it twice. Seen ids
  are now kept in full (bounded far above any real session).
- **The rate-table refresh runs the plugin's own script.** `setup-statusline.py` called
  `--refresh-prices` on the installed copy, and any copy older than 1.3.0 has no such flag. The call
  fell through to the renderer, failed on empty stdin, and the cache never refreshed. Nothing
  reported the failure.

## 1.3.0: self-priced session cost

Claude Code only knows rates for models it ships, so anything behind a gateway
(`nebius/zai-org/GLM-5.2`, `zai-org/GLM-5.2`) reported `$0.00` whatever it spent. The HUD now prices
the session itself: it sums the token usage in the transcript and multiplies it by LiteLLM's rate
table. Usage is deduplicated by `requestId`, because Claude Code writes one record per content block
and repeats the full usage in each, which makes a naive sum 3-4x too high. The table is cached under
`~/.cache/acf-mission-control/` and refreshed daily in a detached process, so the status line never
blocks on the network.

- Provider prefixes are treated as routing: segments are stripped left to right until an entry
  matches, then the bare model name is looked up wherever it is published.
- Self-priced figures are marked `≈`; a trailing `?` flags tokens spent at unknown rates.
- `--price-check <model-id>` shows the resolved entry; `--refresh-prices` forces a fetch.
- `CONFIG["price_aliases"]` pins a model id to a rate-table key; `price_map: False` reverts to Claude
  Code's own figure and stops all network access.
- With no cached table, the segment falls back to Claude Code's own figure.

## 1.2.0: sleek monochrome glyphs, themeable, colored anchors

The default glyph set is now monochrome geometric Unicode that needs no special font. Themes:
`sleek` (default), `emoji` (the original pictographs), `nerd` (Nerd Font), `text` (no icons).

## 1.1.0: modern two-line HUD, semantic color, cache warmth, self-upgrade

Two-line layout, a fuel gauge that knows about 1M-context models, per-model colors, a prompt-cache
warmth indicator, and the `SessionStart` self-upgrade that keeps `.claude/scripts/status-line.py`
in sync with the shipped plugin.
