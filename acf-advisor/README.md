# ACF Advisor Plugin

> Consult another LLM (with thinking mode on) for a second opinion. **Or convene a board of advisors** — multi-persona panel hypertailored to a specific decision.

Two skills, one shared code path.

- **`advisor`** — single second opinion. Claude builds focused context, pipes it to any OpenAI-compatible Chat Completions endpoint (LiteLLM / OpenAI / OpenRouter / internal proxy) with thinking mode on, returns the reply verbatim plus Claude's own take.
- **`board`** *(new in 1.1.0)* — multi-persona panel. For non-trivial decisions spanning ≥ 2 dimensions, Claude composes 1–5 hypertailored personas using the synthesis recipe in `persona-design/`, runs them in parallel for `R` rounds (deliberatively chosen, not autonomously extended), and integrates a synthesis weighted by the user-confirmed priority dimension. Supports a multi-model pool via comma-delimited `ADVISOR_MODEL` (round-robin auto-assignment, optional cross-model triangulation on the critical lens).

---

## What it does

### Single advisor (existing)

1. Claude invokes the `advisor` skill when you ask for a second opinion or judge the question would benefit from one.
2. Builds focused context, trims to a sensible size, pipes to the endpoint with thinking on (`reasoning_effort: "high"` + `thinking: {budget_tokens: 8000}`; auto-falls-back if the upstream rejects either).
3. Returns the advisor's reply verbatim, plus Claude's own brief take.

### Local-team fallback (new in 1.2.0)

When no LLM endpoint is configured (no `LITELLM_API_KEY` / `OPENAI_API_KEY` reachable via env or project `.env`, no `ADVISOR_MODEL` set), the `board` skill **does not error out**. Instead it falls back to local-team mode: each persona runs as a Claude subagent (`Agent` tool, `subagent_type: general-purpose`), dispatched in parallel from one message. Synthesis is produced directly by the orchestrator. **No external API calls.**

The skill tells you explicitly when this happens:

> No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY in env or project .env). Falling back to local-team mode — each persona will run as a Claude subagent. No external API calls.

The same dimension-extraction → priority pick → roster confirmation steps run as in the LLM path. Cross-model triangulation does not apply (all "models" are Claude). Per-persona output uses `### Advisor (local) — <Human Name> (<descriptor>) says:` headers; the cost line is `[board:local] mode=local-team personas=N rounds=R subagent_calls=N×R`.

To force the LLM path again, configure `LITELLM_API_KEY` + `ADVISOR_MODEL` in your project `.env` and re-invoke. The script's `--check-env` flag (also new in 1.2.0) lets you verify the resolution without making any HTTP call:

```bash
./acf-advisor/scripts/advisor.py --check-env
# exit 0 → LLM path. exit 2 → local-team fallback.
```

### Board of advisors (new in 1.1.0)

1. Claude routes to the `board` skill when a decision spans ≥ 2 distinct dimensions of correctness OR is hard-to-reverse OR you explicitly ask for a panel.
2. **Extracts decision dimensions** as a numbered list and asks you to confirm + pick the most important one (priority dimension). This step is the load-bearing one — by the time the roster is shown, the decision is mostly made.
3. **Composes personas** — one per confirmed dimension. Each gets a human first+last name with light humour paired with a decision-specific descriptor (e.g. `Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`, not "security auditor"), plus explicit blind spots. Names mix cultures across the panel; cross-model clones share the descriptor but get distinct human names.
4. **Picks `R`** by deliberative judgment (default 1; up to 5 when personas trade off, decision is irreversible, etc.). User can override.
5. **Distributes models** from the pool: round-robin by default, or cross-model triangulation when one specific lens is critical AND the pool offers genuinely different reasoners.
6. **Confirms the roster with you** (free, no advisor cost) → writes one prompt file per persona → runs them as N parallel `Bash` calls to `advisor.py` in a single message.
7. **Synthesizes** all takes into one recommendation, weighted by your priority dimension.
8. Returns per-persona transcripts (header form `### Advisor (<model>) — <Human Name> (<descriptor>) says:`) plus the synthesis block.

**Not** for: quick lookups Claude can answer directly, tasks you asked Claude to do, or as a default for trivial second opinions (use the single `advisor` skill).

---

## Installation

### Prerequisites

- **uv** on PATH. The advisor script uses a PEP 723 single-file shebang (`#!/usr/bin/env -S uv run --script`).
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- Env vars set in your shell **or** in a `.env` anywhere from CWD up to the first `.git` (auto-loaded since v1.0.1). See [Configuration](#configuration).

### Install the plugin

```bash
# from a directory containing acf-tools/
claude
```

In Claude Code:
```
/plugin marketplace add ./acf-tools
/plugin install acf-advisor@acf-tools
```

---

## Configuration

All configuration is via environment variables. No config files.

| Purpose | Primary | Fallback / default |
|---|---|---|
| API key | `LITELLM_API_KEY` | `OPENAI_API_KEY` |
| Base URL | `LITELLM_BASE_URL` | `OPENAI_BASE_URL` (default: `https://api.openai.com/v1`) |
| Model **or** comma-delimited model pool | `ADVISOR_MODEL` | `OPENAI_MODEL` (no default — error if unset) |
| Reasoning effort | `ADVISOR_REASONING_EFFORT` | default `high`; values: `low`, `medium`, `high`, `off` |
| Thinking budget (tokens) | `ADVISOR_THINKING_BUDGET` | default `8000` |
| Override param-shape profile | `ADVISOR_PROFILE` | one of `claude_adaptive`, `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`; unset = regex-routed by family name |
| HTTP timeout (seconds) | `ADVISOR_TIMEOUT` | default `600` (was `180` pre-v1.2.0) |
| Disable `.env` auto-load | `ADVISOR_NO_DOTENV=1` or `--no-dotenv` flag | auto-load on by default |
| Override advisor.py path (dev) | `ACF_ADVISOR_BIN` | resolver falls back to plugin cache |

### `ADVISOR_MODEL` as a model pool (since v1.1.0)

`ADVISOR_MODEL` accepts either a single model name (single-shot mode, unchanged from v1.0.x) or a comma-delimited list of model names (declaring a pool the board skill can distribute across).

Example `.env`:
```
LITELLM_API_KEY=sk-...
LITELLM_BASE_URL=https://litellm.example.com/v1

# Single-model — both skills use this model.
ADVISOR_MODEL=claude-sonnet-4-6

# OR multi-model pool — single advisor uses the first; board distributes across all.
# ADVISOR_MODEL=gpt-5.5,gemini/gemini-3.1-pro-preview,claude-opus-4-6
```

Pool semantics:

- **`advisor` skill / CLI**: uses the first entry. `--model X` always overrides.
- **`board` skill**: passes the full pool as `available_models` in the manifest. Personas with `model: null` get round-robin assignment from the pool (wraps when persona count > pool size). Personas with an explicit pinned model must use a name from the pool (validation catches typos like `claude-opus-4.7` vs `claude-opus-4-7`).
- **Same model, multiple personas**: allowed and useful. Two personas with different system prompts on the same model produce different perspectives.
- **Same persona, multiple models** (cross-model triangulation): also allowed. Two manifest entries with identical `system` + `display_name`, distinct `id`s, different `model` values are run as independent advisors. Useful when one specific lens is decision-critical and the pool has genuinely different reasoners — agreement-or-disagreement across models on that lens is itself the diagnostic. Costs roster slots; use deliberately.

### `.env` auto-load (since v1.0.1)

The script walks up from CWD looking for the first `.env`, stopping at the first match, a `.git` directory, or filesystem root. If found, it loads the file (and `.env.local` next to it, if present) into the process environment. **Already-set env vars are never overridden** — shell-exported wins, `.env` only fills gaps. A stderr line confirms what was loaded: `[advisor] loaded env from /path/to/.env (3 new vars)`.

To disable: `--no-dotenv` flag or `ADVISOR_NO_DOTENV=1`.

The format is plain `KEY=VALUE`, with `#` comments, optional `export` prefix, and surrounding `"`/`'` quotes stripped. **No** shell expansion or command substitution — if you need `$HOME` style interpolation, source via your shell instead.

**Thinking mode is on by default.** That's the point — considered answers are worth the extra latency and reasoning-token cost. To turn it off for a single cheap call: `ADVISOR_REASONING_EFFORT=off`.

---

## Usage

You don't invoke the skill directly — Claude does, when it's the right move. Trigger it by asking:

- *"Get a second opinion on this approach."*
- *"Ask the advisor whether channels or a mutex are better here."*
- *"Use the advisor skill to validate this migration plan."*

Claude will:
1. Build a focused prompt from the relevant context.
2. Pipe it to `acf-advisor/scripts/advisor.py` via stdin.
3. Show you the advisor's reply verbatim, followed by Claude's own take.
4. Surface token usage on the `[advisor]` stderr line.

### Direct CLI use

The script works standalone:

```bash
echo "What's a robust pattern for retry with jitter in Python?" \
  | ./acf-advisor/scripts/advisor.py
```

Or explicitly via uv:
```bash
uv run acf-advisor/scripts/advisor.py < prompt.txt
```

Override the model per-call:
```bash
echo "..." | ./acf-advisor/scripts/advisor.py --model gpt-5
```

---

### Driving the board by hand

There is **no Python orchestrator** — `board.py` was removed in v1.3.0, when the panel moved to
parallel Claude tool calls. Every advisor call, board or not, goes through the same CLI:

```bash
# resolve the CLI once (the skills do this in pre-flight)
ADVISOR_BIN="${ACF_ADVISOR_BIN:-./acf-advisor/scripts/advisor.py}"
[ -x "$ADVISOR_BIN" ] || ADVISOR_BIN="$(ls -1t "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | head -1)"

"$ADVISOR_BIN" --system-file <persona>.sys --model <model> < <prompt>.txt
```

The `board` skill writes those files into a private `mktemp -d` per run and issues N of these as
parallel `Bash` calls in one message. To drive a panel yourself, write the files and run the calls;
there is no manifest schema and no separate exit-code contract to satisfy.

---

## How It Works

**Two skills, one shared library, no script duplication.**

```
                          lib/advisor.py::run_advisor()
                          (HTTP, auth, dotenv, retries — single source of truth)
                                  ↑                        ↑
                                  │                        │
                  scripts/advisor.py ───────────────────┐
                  (thin CLI wrapper)                     │
                          ↑                              │
                          │                     (N parallel Bash calls,
                          │                      one per persona)
                          │                              ↑
              skills/advisor/SKILL.md         skills/board/SKILL.md
              (Q/Context/Considered/Want      (dimension extraction →
              prompt format,                   roster confirm →
              observability conventions,       manifest builder →
              upstream-error table —           cross-references advisor
              CANONICAL)                       skill, does NOT restate)
                          ↑                                ↑
                    user asks for                    user asks for a
                    second opinion                   panel / multi-perspective
```

**Single advisor flow** (unchanged from v1.0.x):

```
User → Claude → advisor skill → advisor.py → POST /chat/completions → reply
```

**Board flow** (new in v1.1.0):

```
User → Claude → board skill →
  step 1: extract dimensions, surface to user, get priority
  step 2: pick R via deliberative criteria
  step 3: compose 1–5 personas using persona-design/ recipe
  step 4: assign models from ADVISOR_MODEL pool
          (round-robin OR cross-model triangulation on priority lens)
  step 5: confirm roster + R with user
  step 6: write one .sys per persona + one prompt file, into a private mktemp -d
  step 6b: N parallel Bash calls to advisor.py in ONE message; repeat per round,
           injecting the prior round's transcript; then one synthesis call
  step 7: render verbatim under per-persona "### Advisor (model) — name says:" headers
          (same idiom as advisor skill — multiplied)
  step 8: + Claude's brief take
```

**Key files:**

| File | Purpose |
|---|---|
| `lib/advisor.py` | Core module: `run_advisor()`, HTTP client, dotenv loader, retry logic, redaction. Single source of truth — both scripts import from here. Stdlib-only. |
| `scripts/advisor.py` | uv PEP 723 thin CLI wrapper around `lib.advisor.run_advisor()`. CLI flags: `--system`/`--system-file` (mutually exclusive), `--model`, `--timeout`, `--no-dotenv`, `--debug`. |
| `skills/advisor/SKILL.md` | Single second-opinion protocol. Canonical for the structured prompt format, observability conventions, upstream-error table. |
| `skills/board/SKILL.md` | Panel workflow: dimension extraction → roster confirmation → manifest build. Cross-references the advisor skill — does NOT restate the prompt format, error handling, or observability. |
| `persona-design/DESIGN.md` | The 7-step synthesis recipe + "shapes too generic — and the specific versions they should become" anti-pattern table. Durable artifact. |
| `persona-design/persona-template.md` | Structured template for persona system prompts (Dimension / Lens / Bias / Blind spots / Output discipline). Mandatory fields. |
| `persona-design/synthesizer.md` | STATIC system prompt for the synthesis call. Not generated per call (avoids the synthesizer adopting a persona). |
| `persona-design/convergence.md` | STATIC prompt for convergence-checking. Shipped but unused in v1.1.0; reserved for a future revision. |
| `persona-design/examples/*.md` | Four worked panels (auth-redesign, perf-regression, data-migration, product-prioritization) showing reasoning chains: original prompt → extracted dimensions with reasoning → personas considered AND rejected → final roster → tier choice. Read for the *process*, not as templates. |

**Reasoning fields, routed by family (see `MODEL_PARAM_PROFILES` in `lib/advisor.py`):**
- `claude_adaptive` (any `claude-(opus|sonnet|haiku)`): `thinking: {type: adaptive}` + `output_config: {effort}`.
- `gemini_thinking_level` (`gemini/gemini*`): `reasoning_effort` only — LiteLLM auto-maps to `thinking_level`.
- `openai_reasoning_only` (`gpt*`, `o1`, `o3`, …): `reasoning_effort` only.
- `claude_legacy_thinking` (opt-in via `ADVISOR_PROFILE`): legacy `thinking: {type: enabled, budget_tokens: N}` for Claude 3 / 4.0–4.6.
- `default` (unknown alias): `reasoning_effort` only — safe lowest-common-denominator. Never sends a legacy `thinking` block.

If the upstream still rejects fields, the script auto-retries: shape-swap to `claude_adaptive` on the Anthropic adaptive-required 400; otherwise drop reasoning fields and retry with a stderr warning.

---

## Troubleshooting

### `advisor: missing API key`

The script checks the process environment after `.env` auto-load. Diagnose:

```bash
# Was a .env loaded? Check the [advisor] sending: line — it shows dotenv=<path or 'none'>.
echo "ping" | ./acf-advisor/scripts/advisor.py 2>&1 | grep '\[advisor\] '
```

If `dotenv=none` is shown, you're not in a project that has a `.env` (or auto-load is disabled via `--no-dotenv` / `ADVISOR_NO_DOTENV=1`). Either `cd` into the project, add a `.env`, or shell-export the var: `export LITELLM_API_KEY=…`.

If a `.env` was loaded but the var is still missing, the file doesn't define it (or has a typo): `grep LITELLM_API_KEY .env`.

### `advisor: not found (tried ACF_ADVISOR_BIN, CLAUDE_PLUGIN_ROOT, ~/.claude/plugins/cache)`

The skill's path resolver couldn't locate the script. Either the plugin isn't installed in this Claude Code instance (install with `/plugin install acf-advisor@acf-tools`), or you're working from source — set `ACF_ADVISOR_BIN` to your checkout:

```bash
export ACF_ADVISOR_BIN=/path/to/acf-tools/acf-advisor/scripts/advisor.py
```

### Why didn't I get reasoning tokens?

If the stderr line shows `reasoning=0` and you see the note `reasoning fields sent but upstream returned 0 reasoning tokens`, one of these is true:

- The model genuinely didn't engage thinking on this prompt (some reasoning models judge the prompt trivial and return immediately — the `gpt-5.5` model on a "ping" prompt is one such case).
- The proxy stripped `reasoning_effort` / `thinking` before forwarding.
- The model alias on your proxy points at a non-reasoning model.

To diagnose, run with `--debug` and inspect the actual request body and what the proxy returned:

```bash
echo "your real question" | ./acf-advisor/scripts/advisor.py --debug 2>&1 | head -40
```

If you want to skip the thinking round-trip entirely on a model that doesn't support it: `ADVISOR_REASONING_EFFORT=off`.

### `advisor: missing model`

Set `ADVISOR_MODEL` to a model name your endpoint understands. With LiteLLM, this is whatever you've configured in the proxy (e.g. `gpt-5`, `claude-sonnet-4-6`, `groq/llama-3.3-70b`).

### `HTTP 401`

Stale or wrong key. Re-issue / re-source.

### `HTTP 404 model not found`

The model name doesn't exist on this endpoint. List available models on your proxy and pick one.

### `upstream rejected reasoning fields; retrying without thinking mode`

Not an error — the script noticed the upstream doesn't accept `reasoning_effort` / `thinking` and retried without. The reply still came through. If you want this to be silent, set `ADVISOR_REASONING_EFFORT=off`.

### `uv: command not found`

Install uv: `curl -LsSf https://astral.sh/uv/install.sh | sh` and re-open your shell.

### Connection / timeout

Confirm `LITELLM_BASE_URL` is reachable: `curl -I "$LITELLM_BASE_URL/models" -H "Authorization: Bearer $LITELLM_API_KEY"`. Bump `ADVISOR_TIMEOUT` if the model genuinely takes a long time to think.

---

## Privacy & Security

- The script never logs the API key, even on error.
- The full prompt (including any context Claude built) is sent to the configured endpoint. Don't pipe secrets / customer data unless your endpoint is trusted.
- No telemetry. No conversation persistence on the plugin side. Whatever your endpoint provider logs is between you and them.

---

## License

Proprietary — Copyright 2025 Fibonacci Seven, LLC. See [LICENSE](LICENSE).

---

## Summary

Lean, env-var-driven, thinking-on-by-default. Two skills (`advisor` for single second opinions, `board` for hypertailored multi-persona panels), one shared core (`lib/advisor.py`), one POST per advisor call. When you want a considered take — solo or in concert — without leaving your session.

### Changelog

- **v1.3.7** — Documentation caught up with the code, and two skill defects fixed.
  - **`board.py` has not existed since v1.3.0**, when the panel moved to parallel Claude tool calls.
    The README still documented a "Direct CLI use of the board" section with a manifest schema and an
    exit-code contract, four env vars (`BOARD_PARALLELISM`, `BOARD_TOTAL_TIMEOUT_SECONDS`,
    `BOARD_MAX_ROUNDS`, `ACF_BOARD_BIN`) that no shipped code reads, an architecture diagram and a
    key-files row. Following any of it produced `no such file or directory`, or silently set nothing.
  - **The board wrote to fixed `/tmp/board-*` paths.** Two sessions on one machine convening
    overlapping boards share those names, so one session's prompt file could be overwritten between
    the write and the parallel reads — its personas then answer the other session's question, and the
    result is rendered and synthesised under the first roster's heading with nothing indicating the
    swap. Each run now gets a private `mktemp -d`.
  - **The advisor's heredoc used a fixed `PROMPT` delimiter.** Any assembled prompt containing a line
    that is exactly `PROMPT` terminates it early: the advisor answers a truncated prompt (typically
    missing "What I want from you"), and the remainder is handed to the shell as commands. The skill
    now generates a per-invocation delimiter and checks it against the prompt before emitting.

- **v1.3.3** — Routing-decision parity with the LLM-path call. Fixes a silent misroute to local-team mode when the plugin is installed in projects that configure `LITELLM_API_KEY` / `ADVISOR_MODEL` via a project `.env`:
  - **Root cause**: the `board` skill's pre-flight read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash — but Claude Code's Bash tool inherits the orchestrator process env, **not** the project `.env`. The skill therefore always saw missing env and chose local-team mode, even though the per-persona `advisor.py` invocation would have loaded the same `.env` and dispatched LLM calls. `--check-env` was designed for this exact routing decision in v1.2.0; the skill text in the same release contradictorily forbade its use ("no `--check-env`"). Both branches of v1.3.x inherited the bug.
  - **`board/SKILL.md` pre-flight rewrite**: the routing decision now goes through `"$ADVISOR_BIN" --check-env`. Exit 0 → LLM path, parse the structured one-liner for the model pool. Exit 2 → local-team. Wrapped in `bash -c` for array-syntax independence (Claude Code's interactive shell is often zsh). Pool iteration uses `tr ',' '\n' | while read -r` instead of `IFS=',' read -ra`, since zsh does not word-split parameter expansions on `IFS` by default.
  - **`lib/advisor.py::check_env()`**: emits new `models=<csv>` field with the full comma-delimited pool from `parse_model_list()`. Existing `model=<first>` field unchanged for backward-compat. Skill prefers `models=` and falls back to `model=` when running against an older `advisor.py`.
  - **Critical-rules update**: explicit "do not read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash — those reads silently misroute to local-team mode." The "do not probe env" rule still holds for the per-persona invocation; only the routing oracle is allowed to ask Python.
  - **Tests**: 3 new `CheckEnvTests` cases lock the `models=` field, pool-order preservation, and the exit-2 / no-`models=` shape on missing env.
- **v1.3.2** — Hardens the v1.3.1 routing so non-canonical aliases stop falling through to the legacy thinking shape:
  - **Family-only regex, no version pins**. `MODEL_PARAM_PROFILES` matches by provider/family name only (`claude-(opus|sonnet|haiku)`, `gemini`, `gpt|o\d+`); future versions inherit the modern profile. The version-pinned `claude_47_adaptive` profile is renamed `claude_adaptive` to reflect this.
  - **Safe `default` profile**. Unknown models now send only `reasoning_effort` (the OpenAI-shape lowest common denominator) — never the legacy `thinking.type=enabled, budget_tokens=N` block. That legacy default broke modern Claude when LiteLLM aliases like `proxy/claude-opus-4-7` didn't match the v1.3.1 regex.
  - **`ADVISOR_PROFILE` env override**. Pin a profile when your gateway uses an alias the regex can't recognise: `ADVISOR_PROFILE=claude_adaptive` (or any of `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`). Unknown values warn once and fall back to regex routing.
  - **Shape-swap retry**. New `looks_like_anthropic_adaptive_required()` detector recognises the literal `thinking.type.adaptive` / `output_config` 400 and retries the call pinned to `claude_adaptive` — rescues both alias-vs-regex misses and proxy translation gaps without losing thinking behaviour.
  - **`claude_legacy_thinking` is opt-in only**. Removed from auto-routing; reachable exclusively via `ADVISOR_PROFILE=claude_legacy_thinking` for users still on Claude 3 / 4.0–4.6.
  - **`lib/test_advisor.py`**: stdlib unittest covering profile resolution, payload shape per family, override behaviour, and the literal user-reported error string. Run with `uv run python -m unittest discover acf-advisor/lib`.
- **v1.3.1** — Proactive model-aware param construction. `lib/advisor.py` resolves a per-call profile from a `MODEL_PARAM_PROFILES` regex registry and `build_payload()` dispatches on it instead of always sending both reasoning fields. Profiles: `claude_47_adaptive`, `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`. Fixes hard 400s on `gemini/gemini-3.x-*` ("Cannot specify both `thinking` and `thinking_level`") and `claude-opus-4-7` ("`thinking.type.enabled` is not supported"). *(Superseded by v1.3.2 — version-pinned regex was incomplete; aliases that didn't match leaked the legacy shape.)*
- **v1.2.0** — Scope discipline + local-team fallback + provider-compat fixes + higher timeouts:
  - **Local-team fallback**: when no API endpoint is reachable (no key/model after `.env` auto-load + shell), the `board` skill switches to local-team mode — each persona runs as a parallel Claude subagent (`Agent` tool). Synthesis produced by the orchestrator. No external calls. Skill explicitly announces the mode switch. LLM path is unchanged when env IS configured.
  - **New `--check-env` flag** on `advisor.py`: probes env (dotenv + shell) without any HTTP call. Exit 0 if `api_key + model` resolve, 2 if missing. Stderr emits a structured one-liner (`dotenv=… api_key=… model=… ok|missing=…`) used by the board skill to choose the execution path.
  - **Skill scope discipline**: explicit "DO NOT pre-search env outside the dotenv chain" rule in both skill files. Prior live use surfaced the orchestrator improvising bash that read `$HOME/.claude/`, `$HOME/.config/`, `~/.zshrc`, etc. — strictly forbidden now. Trust `--check-env`'s answer.
  - **Anthropic + thinking + temperature**: `looks_like_temperature_error()` now matches `"may only be set"` — catches `claude-opus-4-7`'s 400 when temperature ≠ 1 with thinking on. Auto-retry drops the explicit temperature and Anthropic uses its default. Was: hard 400.
  - **Gemini 3 thinking_level conflict**: new `looks_like_thinking_budget_conflict()` heuristic + dedicated retry branch. When upstream errors with `thinking_level` / `Cannot specify both \`thinking\` …` (LiteLLM auto-maps `reasoning_effort` to `thinking_level` for Gemini 3 while we also send `thinking.budget_tokens`), drop ONLY `thinking.budget_tokens` and retry — keep `reasoning_effort` so thinking-on-via-thinking_level still works. Retry-branch ordering checks this BEFORE the broader `reasoning_field_error` branch (whose substrings overlap).
  - **Higher default timeouts**: per-call `run_advisor(timeout=)` 180 → **600s**, board manifest `limits.call_timeout_seconds` 180 → **600**, `BOARD_TOTAL_TIMEOUT_SECONDS` env default 900 → **1800**. Thinking-heavy reasoners on complex prompts were being silently dropped at 180s. `ADVISOR_TIMEOUT` shell override unchanged. The CLI's `[advisor] sending: …` line now includes `timeout=Ns` so the effective per-call timeout is visible.
- **v1.1.0** — Major capability addition (backward-compatible at the existing CLI):
  - **New `board` skill**: convene a multi-persona panel hypertailored to a specific decision. Personas synthesized per call from `persona-design/DESIGN.md`'s 7-step recipe. Mandatory dimension-extraction step (visible to user before persona composition) + structured persona template (Dimension / Lens / Bias / Blind spots / Output discipline) + static synthesizer prompt + 4 worked-example panels showing reasoning chains.
  - **New `scripts/board.py` orchestrator**: validates JSON manifest, runs personas in parallel via `ThreadPoolExecutor`, manages `R`-round structured transcript injection, runs final synthesis, returns structured markdown + aggregate cost broken down by model. Defined exit codes; SIGINT/SIGTERM-clean; total board timeout. NO direct HTTP — delegates to `lib.advisor.run_advisor()` for every call.
  - **New `lib/advisor.py` module**: extracts core logic from `scripts/advisor.py` (HTTP, auth, dotenv, retries, redaction). Single source of truth shared by both scripts.
  - **`scripts/advisor.py` refactored to thin CLI wrapper**. CLI behavior byte-for-byte unchanged for callers. Adds `--system-file` flag (mutually exclusive with `--system`); avoids leaking prompt content via `ps`. `looks_like_temperature_error()` now matches `"deprecated"` substring (catches the new Claude models that reject custom temperature with that wording).
  - **`ADVISOR_MODEL` accepts a comma-delimited model pool**. Backward-compat: a single value works as before. Multi-value declares the candidate pool used by the board (round-robin auto-assignment, optional cross-model triangulation on a critical lens; same model allowed for multiple personas; same persona allowed across multiple models).
  - **New env vars**: `BOARD_PARALLELISM` (default 5), `BOARD_TOTAL_TIMEOUT_SECONDS` (default 900), `BOARD_MAX_ROUNDS` (default 5), `ACF_BOARD_BIN` (dev path override).
  - **Round count `R` chosen by deliberative judgment**, not autonomous loops. Default `R=1`; criteria for higher values when personas trade off, decisions are irreversible, etc. `R` is fixed at manifest-build time — no autonomous mid-run extension.
  - **DRY enforced at three layers**: same `lib/` module, same skill protocol (board cross-references advisor), same per-persona output rendering idiom.
- **v1.0.1** — `.env` auto-load (CWD upward to first `.git` boundary), layered script-path resolver in the skill (`ACF_ADVISOR_BIN` → `CLAUDE_PLUGIN_ROOT` → plugin cache glob), pre-flight `[advisor] sending: …` line, post-flight zero-reasoning notice, `--debug` flag with key redaction. No API changes.
- **v1.0.0** — Initial release.
