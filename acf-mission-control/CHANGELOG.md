# Changelog — acf-mission-control

All notable changes to acf-mission-control. Format loosely follows Keep a Changelog.

## 1.3.1 — the self-priced figure is now the whole session

1.3.0 shipped self-pricing so proxied models would stop reading `$0.00`. Auditing it before
release found the figure could still be wrong — sometimes by 4x, sometimes still zero. This
release makes it honest, and marks it when it can't be.

- **Subagent and workflow tokens are counted.** They live in sibling transcripts under
  `<transcript>/subagents/`, not in the transcript itself, so the previous total simply
  skipped them — while the code claimed otherwise. On a workflow-heavy session they can be
  several times the main thread: one measured session read `≈$6.03` and actually cost
  `$25.71`. `scan_usage` now folds in every sibling transcript, keeping a per-file byte
  cursor so the scan stays incremental.
- **A zero rate no longer prices anything.** `distill_prices` kept an entry when `input`/
  `output` costs were merely *present*, so free and placeholder tiers priced at `0.0`
  survived — 130 of them in a current table, 9 sharing a basename with a real model. A
  collision produced a confident `≈$0.00` that *suppressed* Claude Code's own figure: the
  exact bug self-pricing exists to remove. Such entries are now dropped at distill time, and
  `session_cost` refuses to count one as priced even from an older cache.
- **Substituted cache rates are disclosed.** 72% of published entries carry no cache-read
  price and 90% none for cache writes, while cache reads are ~90%+ of a session's tokens.
  Billing them at the input rate is the only estimate available but overstates by ~4x — it
  now raises the `?` marker instead of passing as fully priced. Reachable today on
  gateway-served Claude ids (`databricks/databricks-claude-*`, `gmi/anthropic/claude-*`,
  `bedrock/*/anthropic.claude-*`, …), which resolve to themselves and so never benefit from
  the completeness-preferring fallback.
- **Speed multipliers are applied.** Rate tables publish `provider_specific_entry`
  (e.g. `{"us": 1.1, "fast": 2.0}`); fast mode bills the same model at double. Totals now
  bucket per `(model, speed)` and price each on its own multiplier.
- **Context-window variants resolve.** `claude-opus-5[1m]` matched nothing, so a 1M-context
  session priced at `$0` with a silent `?`. A trailing bracket is a variant marker, not a
  different model, and is now stripped after an exact attempt.
- **JSONL is split on newlines only.** `str.splitlines()` also breaks on U+2028/U+2029/
  U+0085, which JSON encoders emit raw inside strings; a record carrying one was torn into
  unparseable fragments and — because the byte offset still advanced — lost for good.
- **requestId dedup is exact.** The 64-entry ring could roll past an id and double count it;
  seen ids are now persisted in full (bounded far above any real session).
- **The rate-table refresh runs the plugin's own script.** `setup-statusline.py` invoked
  `--refresh-prices` on the *installed* copy, which for anything pre-1.3.0 has no such flag —
  it fell through to the renderer, failed on empty stdin, and the cache silently never
  refreshed.

## 1.3.0 — self-priced session cost

Claude Code only knows rates for models it ships, so anything behind a gateway
(`nebius/zai-org/GLM-5.2`, `zai-org/GLM-5.2`) reported `$0.00` regardless of spend. The HUD
now sums transcript token usage — deduplicated by `requestId`, since Claude Code writes one
record per content block and repeats the full usage in each, which inflates naive sums 3-4x —
and multiplies it by LiteLLM's rate table, cached under `~/.cache/acf-mission-control/` and
refreshed daily in a detached process so the status line never blocks on the network.

- Provider prefixes are routing, not identity: segments are stripped left to right until an
  entry matches, then the bare model name is looked up wherever it is published.
- Self-priced figures are marked `≈`; a trailing `?` flags tokens burned at unknown rates.
- `--price-check <model-id>` shows the resolved entry; `--refresh-prices` forces a fetch.
- `CONFIG["price_aliases"]` pins a model id to a rate-table key; `price_map: False` reverts
  to Claude Code's own figure and stops all network access.
- With no cached table the segment degrades to Claude Code's own figure.

## 1.2.0 — sleek monochrome glyphs, themeable, colored anchors

Default glyph set is now monochrome geometric Unicode needing no special font. Themes:
`sleek` (default), `emoji` (the original pictographs), `nerd` (Nerd Font), `text` (no icons).

## 1.1.0 — modern two-line HUD, semantic color, cache warmth, self-upgrade

Two-line layout, 1M-context-aware fuel gauge, per-model colors, prompt-cache warmth
indicator, and the `SessionStart` self-upgrade that keeps `.claude/scripts/status-line.py`
in sync with the shipped plugin.
