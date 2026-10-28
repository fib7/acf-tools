# ACF Advisor Plugin

Ask another LLM for a second opinion from inside Claude Code, with thinking mode on. When a decision can go wrong in several distinct ways, convene a board instead: a panel of personas written for that one decision, run in parallel, and folded into a single recommendation.

Two skills share one code path:

- **`advisor`**: one second opinion. Claude assembles focused context, sends it to any OpenAI-compatible Chat Completions endpoint (LiteLLM, OpenAI, OpenRouter, an internal proxy) with thinking on, and shows you the reply verbatim, followed by its own take.
- **`board`** (since 1.1.0): a multi-persona panel for non-trivial decisions that span two or more dimensions. Claude writes 1–5 personas for the decision using the recipe in `persona-design/`, runs them in parallel for `R` rounds (fixed before the run, never extended during it), and writes a synthesis weighted toward the dimension you said matters most. A comma-delimited `ADVISOR_MODEL` gives it a pool of models: personas are assigned round-robin, and one critical lens can be run on several models so you can compare their answers (cross-model triangulation).

---

## What it does

### Single advisor

1. Claude invokes the `advisor` skill when you ask for a second opinion, or when it judges the question would benefit from one.
2. It builds focused context, keeps it under about 20 KB, and sends it with thinking on. Which reasoning fields go out depends on the model family (see [How It Works](#how-it-works)); if the upstream rejects them, the script retries without.
3. You get the advisor's reply verbatim, then Claude's own brief take.

### Board of advisors

1. Claude routes to the `board` skill when you ask for a panel, or when a non-trivial decision spans two or more distinct dimensions of correctness and is hard to reverse.
2. It shows the decision's dimensions as a numbered list and asks you to confirm them and pick the one that matters most (the priority dimension). This step shapes everything after it: by the time you see a roster, most of the decision has been made.
3. It writes one persona per confirmed dimension. Each gets a human first and last name with light humour, paired with a descriptor specific to this decision (`Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`, not "security auditor"), and named blind spots. Names mix cultures across the panel. Cross-model clones share a descriptor but get different names.
4. It picks `R`, the number of rounds: 1 by default, 2–5 when personas trade off against each other, the decision is irreversible, or coupled subsystems need iterating. You can override it.
5. It assigns models from the pool: round-robin by default, or cross-model triangulation when one lens is critical and the pool has models that reason differently.
6. It shows you the roster for confirmation, which costs no advisor calls. Then it writes one prompt file per persona and runs them as N parallel `Bash` calls to `advisor.py` in a single message.
7. It synthesizes the takes into one recommendation, weighted by your priority dimension.
8. You get each persona's reply under a `### Advisor (<model>) — <Human Name> (<descriptor>) says:` header, then the synthesis.

Don't use it for quick lookups Claude can answer itself or for work you asked Claude to do. For a trivial second opinion, use the single `advisor` skill.

### Without an endpoint: local-team mode (since 1.2.0)

If no LLM endpoint is configured (no `LITELLM_API_KEY` / `OPENAI_API_KEY`, or no `ADVISOR_MODEL` / `OPENAI_MODEL`, in the environment or the project `.env`), the `board` skill does not fail. It switches to local-team mode: each persona runs as a Claude subagent (`Agent` tool, `subagent_type: general-purpose`), all dispatched in parallel from one message, and the orchestrator writes the synthesis itself. Nothing is sent to an external advisor endpoint.

The skill tells you when this happens, in one short paragraph:

```
No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY or no ADVISOR_MODEL
in env or project .env). Running in local-team mode — each persona is a Claude subagent.
No external API calls.
```

Dimension extraction, the priority pick and roster confirmation work exactly as on the LLM path. Cross-model triangulation doesn't apply, since every "model" is Claude. Persona headers read `### Advisor (local) — <Human Name> (<descriptor>) says:`, and the output ends with `[board] mode=local-team personas=N rounds=R`.

To get the LLM path back, set `LITELLM_API_KEY` and `ADVISOR_MODEL` in your project `.env` and ask again. `--check-env` (since 1.2.0) shows which path you'll get, without making an HTTP call:

```bash
./acf-advisor/scripts/advisor.py --check-env
# exit 0 → LLM path. exit 2 → local-team fallback.
```

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

Everything is set through environment variables. A `.env` file can supply them (see below); there is no other config file.

| Purpose | Primary | Fallback / default |
|---|---|---|
| API key | `LITELLM_API_KEY` | `OPENAI_API_KEY` |
| Base URL | `LITELLM_BASE_URL` | `OPENAI_BASE_URL` (default: `https://api.openai.com/v1`) |
| Model **or** comma-delimited model pool | `ADVISOR_MODEL` | `OPENAI_MODEL` (no default; error if unset) |
| Reasoning effort | `ADVISOR_REASONING_EFFORT` | default `high`; values: `low`, `medium`, `high`, `off` |
| Thinking budget (tokens) | `ADVISOR_THINKING_BUDGET` | default `8000`; only the `claude_legacy_thinking` profile sends it |
| Override param-shape profile | `ADVISOR_PROFILE` | one of `claude_adaptive`, `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`; unset = regex-routed by family name |
| HTTP timeout (seconds) | `ADVISOR_TIMEOUT` | default `600`, minimum `300` (was `180` pre-v1.2.0) |
| Disable `.env` auto-load | `ADVISOR_NO_DOTENV=1` or `--no-dotenv` flag | auto-load on by default |
| Override advisor.py path (dev) | `ACF_ADVISOR_BIN` | resolver falls back to plugin cache |

### `ADVISOR_MODEL` as a model pool (since v1.1.0)

`ADVISOR_MODEL` takes either one model name (single-shot mode, as in v1.0.x) or a comma-delimited list, which declares a pool the board skill can spread personas across.

Example `.env`:
```
LITELLM_API_KEY=sk-...
LITELLM_BASE_URL=https://litellm.example.com/v1

# Single-model — both skills use this model.
ADVISOR_MODEL=claude-sonnet-4-6

# OR multi-model pool — single advisor uses the first; board distributes across all.
# ADVISOR_MODEL=gpt-5.5,gemini/gemini-3.1-pro-preview,claude-opus-4-6
```

How each skill uses the pool:

- **`advisor` skill / CLI**: uses the first entry. `--model X` always overrides it.
- **`board` skill**: reads the whole pool from `advisor.py --check-env`. Personas without a pinned model are assigned round-robin in roster order, wrapping when there are more personas than models. A pinned model should come from the pool: nothing checks the name before the call, so a typo like `claude-opus-4.7` for `claude-opus-4-7` goes to the endpoint as written.
- **One model, several personas**: allowed and useful. Two personas with different system prompts on the same model give different perspectives.
- **One persona, several models** (cross-model triangulation): also allowed. Two roster entries with the same `system` and `display_name`, distinct `id`s and different models run as independent advisors. Use it when one lens is decision-critical and the pool has models that reason differently; whether they agree on that lens is the diagnostic. Each clone takes a roster slot, so spend them deliberately.

### `.env` auto-load (since v1.0.1)

The script walks up from CWD looking for a `.env`, and stops at the first match, a `.git` directory, or the filesystem root. If it finds one, it loads that file (and a `.env.local` next to it, if present) into the process environment. **Variables already set are never overridden**: shell exports win, and `.env` only fills gaps. A stderr line confirms what was loaded: `[advisor] loaded env from /path/to/.env (3 new vars)`.

To disable: `--no-dotenv` flag or `ADVISOR_NO_DOTENV=1`.

The format is plain `KEY=VALUE`, with `#` comments and an optional `export` prefix; surrounding `"`/`'` quotes are stripped. There is **no** shell expansion or command substitution. If you need `$HOME`-style interpolation, source the file from your shell instead.

**Thinking mode is on by default**, on purpose: a considered answer is worth the extra latency and reasoning tokens. To turn it off for one cheap call, set `ADVISOR_REASONING_EFFORT=off`.

---

## Usage

You don't invoke the skill yourself; Claude does. Ask for it in plain words:

- *"Get a second opinion on this approach."*
- *"Ask the advisor whether channels or a mutex are better here."*
- *"Use the advisor skill to validate this migration plan."*

Claude then:
1. Builds a focused prompt from the relevant context.
2. Pipes it to `acf-advisor/scripts/advisor.py` on stdin.
3. Shows you the advisor's reply verbatim, followed by its own take.
4. Reports token usage from the `[advisor]` stderr line.

### Direct CLI use

The script also works on its own:

```bash
echo "What's a robust pattern for retry with jitter in Python?" \
  | ./acf-advisor/scripts/advisor.py
```

Or explicitly via uv:
```bash
uv run acf-advisor/scripts/advisor.py < prompt.txt
```

Override the model for one call:
```bash
echo "..." | ./acf-advisor/scripts/advisor.py --model gpt-5
```

---

### Driving the board by hand

There is **no Python orchestrator**. `board.py` was removed in v1.3.0, when the panel moved to
parallel Claude tool calls, so every advisor call, board or not, goes through the same CLI:

```bash
# resolve the CLI once (the skills do this in pre-flight)
ADVISOR_BIN="${ACF_ADVISOR_BIN:-./acf-advisor/scripts/advisor.py}"
[ -x "$ADVISOR_BIN" ] || ADVISOR_BIN="$(ls -1t "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | head -1)"

"$ADVISOR_BIN" --system-file <persona>.sys --model <model> < <prompt>.txt
```

The `board` skill writes those files into a private `mktemp -d` per run and issues N of these calls
in parallel from one message. To run a panel yourself, write the files and run the calls. There is
no manifest schema and no separate exit-code contract.

---

## How It Works

Both skills call one CLI, and the CLI is a thin wrapper over one library.

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

**Single advisor flow:**

```
User → Claude → advisor skill → advisor.py → POST /chat/completions → reply
```

**Board flow:**

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
| `lib/advisor.py` | Core module: `run_advisor()`, HTTP client, dotenv loader, retry logic, redaction. The one place this logic lives; `scripts/advisor.py` imports it. Stdlib-only. |
| `scripts/advisor.py` | uv PEP 723 thin CLI wrapper around `lib.advisor.run_advisor()`. CLI flags: `--system`/`--system-file` (mutually exclusive), `--model`, `--timeout`, `--no-dotenv`, `--debug`, `--check-env`. |
| `skills/advisor/SKILL.md` | The single second-opinion protocol. Canonical for the structured prompt format, observability conventions and the upstream-error table. |
| `skills/board/SKILL.md` | Panel workflow: dimension extraction → roster confirmation → parallel `advisor.py` calls → synthesis. Points to the advisor skill for the prompt format, error handling and observability instead of restating them. |
| `persona-design/DESIGN.md` | The 7-step persona recipe, plus a table of generic persona shapes and the decision-specific versions they should become. |
| `persona-design/persona-template.md` | Structured template for persona system prompts (Dimension / Lens / Bias / Blind spots / Output discipline). Every field is mandatory. |
| `persona-design/synthesizer.md` | Fixed meta-prompt the orchestrator follows when it writes the synthesis. It is static, not generated per call, so the synthesizer doesn't adopt a persona of its own. |
| `persona-design/convergence.md` | Fixed prompt for a convergence check. Nothing uses it yet; it is kept for a future revision. |
| `persona-design/examples/*.md` | Four worked panels (auth-redesign, perf-regression, data-migration, product-prioritization). Each walks from the original prompt to the extracted dimensions, the personas considered and rejected, the final roster, and the path and round-count choice. Read them for the *process*, not as templates. |

**Reasoning fields, routed by model family (see `MODEL_PARAM_PROFILES` in `lib/advisor.py`):**
- `claude_adaptive` (any `claude-(opus|sonnet|haiku)`): `thinking: {type: adaptive}` + `output_config: {effort}`.
- `gemini_thinking_level` (`gemini/gemini*`): `reasoning_effort` only; LiteLLM maps it to `thinking_level`.
- `openai_reasoning_only` (`gpt*`, `o1`, `o3`, …): `reasoning_effort` only.
- `claude_legacy_thinking` (opt-in via `ADVISOR_PROFILE`): the legacy `thinking: {type: enabled, budget_tokens: N}` block, for Claude 3 / 4.0–4.6.
- `default` (unknown alias): `reasoning_effort` only, the lowest common denominator. It never sends a legacy `thinking` block.

If the upstream still rejects the fields, the script retries on its own. On the Anthropic 400 that demands the adaptive shape, it swaps to `claude_adaptive`; on any other rejection it drops the reasoning fields and retries with a stderr warning.

---

## Troubleshooting

### `advisor: missing API key`

The script checks the process environment after `.env` auto-load. Diagnose:

```bash
# Was a .env loaded? Check the [advisor] sending: line — it shows dotenv=<path or 'none'>.
echo "ping" | ./acf-advisor/scripts/advisor.py 2>&1 | grep '\[advisor\] '
```

If it shows `dotenv=none`, you're not in a project with a `.env`, or auto-load is off (`--no-dotenv` / `ADVISOR_NO_DOTENV=1`). Either `cd` into the project, add a `.env`, or export the variable from your shell: `export LITELLM_API_KEY=…`.

If a `.env` was loaded and the variable is still missing, the file doesn't define it, or misspells it: `grep LITELLM_API_KEY .env`.

### `advisor: not found (tried ACF_ADVISOR_BIN, CLAUDE_PLUGIN_ROOT, ~/.claude/plugins/cache)`

The skill's path resolver couldn't find the script. Either the plugin isn't installed in this Claude Code instance (install it with `/plugin install acf-advisor@acf-tools`), or you're working from source, in which case point `ACF_ADVISOR_BIN` at your checkout:

```bash
export ACF_ADVISOR_BIN=/path/to/acf-tools/acf-advisor/scripts/advisor.py
```

### Why didn't I get reasoning tokens?

If the stderr line shows `reasoning=0` with the note `reasoning fields sent but upstream returned 0 reasoning tokens`, one of these is true:

- The model chose not to think on this prompt. Some reasoning models judge a prompt trivial and answer at once; `gpt-5.5` does this on a "ping".
- The proxy stripped `reasoning_effort` / `thinking` before forwarding.
- The model alias on your proxy points at a non-reasoning model.

To see which, run with `--debug` and inspect the request body and what the proxy returned:

```bash
echo "your real question" | ./acf-advisor/scripts/advisor.py --debug 2>&1 | head -40
```

To skip the thinking round-trip on a model that doesn't support it, set `ADVISOR_REASONING_EFFORT=off`.

### `advisor: missing model`

Set `ADVISOR_MODEL` to a model name your endpoint understands. With LiteLLM, that's whatever you configured in the proxy (e.g. `gpt-5`, `claude-sonnet-4-6`, `groq/llama-3.3-70b`).

### `HTTP 401`

The key is stale or wrong. Re-issue it or re-source your env.

### `HTTP 404 model not found`

The endpoint doesn't know that model name. List the models on your proxy and pick one.

### `upstream rejected reasoning fields; retrying without thinking mode`

Not an error. The upstream doesn't accept `reasoning_effort` / `thinking`, so the script retried without them, and the reply still came through. To silence it, set `ADVISOR_REASONING_EFFORT=off`.

### `uv: command not found`

Install uv with `curl -LsSf https://astral.sh/uv/install.sh | sh`, then reopen your shell.

### Connection / timeout

Check that `LITELLM_BASE_URL` is reachable: `curl -I "$LITELLM_BASE_URL/models" -H "Authorization: Bearer $LITELLM_API_KEY"`. If the model needs longer to think, raise `ADVISOR_TIMEOUT`.

---

## Privacy & Security

- The script never logs the API key, even on error.
- The full prompt, including any context Claude built, goes to the configured endpoint. Don't send secrets or customer data unless you trust that endpoint.
- No telemetry, and the plugin keeps no conversation history. Whatever your endpoint provider logs is between you and them.

---

## License

Copyright 2025-2026 Fibonacci Seven, LLC. Licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE).

---

## Changelog

- **v1.3.7**: the documentation caught up with the code, and two skill defects are fixed.
  - **`board.py` has not existed since v1.3.0**, when the panel moved to parallel Claude tool calls.
    The README still documented a "Direct CLI use of the board" section with a manifest schema and an
    exit-code contract, four env vars (`BOARD_PARALLELISM`, `BOARD_TOTAL_TIMEOUT_SECONDS`,
    `BOARD_MAX_ROUNDS`, `ACF_BOARD_BIN`) that no shipped code reads, an architecture diagram and a
    key-files row. Following any of it produced `no such file or directory`, or silently set nothing.
  - **The board wrote to fixed `/tmp/board-*` paths.** Two sessions on one machine convening
    overlapping boards share those names, so one session's prompt file could be overwritten between
    the write and the parallel reads. Its personas then answered the other session's question, and the
    result was rendered and synthesised under the first roster's heading with nothing to show the
    swap. Each run now gets a private `mktemp -d`.
  - **The advisor's heredoc used a fixed `PROMPT` delimiter.** Any assembled prompt with a line that
    is exactly `PROMPT` ended the heredoc early: the advisor answered a truncated prompt (typically
    missing "What I want from you"), and the shell ran the rest as commands. The skill now generates a
    delimiter per invocation and checks it against the prompt before emitting the call.

- **v1.3.3**: the routing decision now sees what the LLM-path call sees. This fixes a silent misroute to local-team mode in projects that set `LITELLM_API_KEY` / `ADVISOR_MODEL` in a project `.env`:
  - **Root cause**: the `board` skill's pre-flight read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash, but Claude Code's Bash tool inherits the orchestrator's process env, **not** the project `.env`. The skill always saw the env as missing and chose local-team mode, although the per-persona `advisor.py` call would have loaded the same `.env` and made LLM calls. `--check-env` was built for exactly this routing decision in v1.2.0, yet the skill text in the same release forbade it ("no `--check-env`"). Both branches of v1.3.x inherited the bug.
  - **`board/SKILL.md` pre-flight rewrite**: routing now goes through `"$ADVISOR_BIN" --check-env`. Exit 0 → LLM path, with the model pool parsed from the structured one-liner; exit 2 → local-team. The check runs inside `bash -c`, so array syntax works whatever the interactive shell is (Claude Code's is often zsh). The pool is iterated with `tr ',' '\n' | while read -r` instead of `IFS=',' read -ra`, because zsh does not word-split parameter expansions on `IFS` by default.
  - **`lib/advisor.py::check_env()`** emits a new `models=<csv>` field with the full pool from `parse_model_list()`. The existing `model=<first>` field is unchanged for backward compatibility. The skill prefers `models=` and falls back to `model=` against an older `advisor.py`.
  - **Critical-rules update**: the skill now says outright not to read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` from bash, because those reads silently misroute to local-team mode. The "do not probe env" rule still holds for the per-persona call; only the routing check may ask Python.
  - **Tests**: 3 new `CheckEnvTests` cases lock the `models=` field, pool-order preservation, and the exit-2 shape (no `models=`) when env is missing.
- **v1.3.2**: non-canonical aliases no longer fall through to the legacy thinking shape.
  - **Family-only regex, no version pins.** `MODEL_PARAM_PROFILES` matches provider/family names only (`claude-(opus|sonnet|haiku)`, `gemini`, `gpt|o\d+`), so future versions inherit the modern profile. The version-pinned `claude_47_adaptive` profile is renamed `claude_adaptive` to match.
  - **Safe `default` profile.** Unknown models now send only `reasoning_effort` (the OpenAI-shape lowest common denominator), never the legacy `thinking.type=enabled, budget_tokens=N` block. That legacy default broke modern Claude when LiteLLM aliases like `proxy/claude-opus-4-7` didn't match the v1.3.1 regex.
  - **`ADVISOR_PROFILE` env override.** Pin a profile when your gateway uses an alias the regex can't recognise: `ADVISOR_PROFILE=claude_adaptive` (or `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`). Unknown values warn once and fall back to regex routing.
  - **Shape-swap retry.** A new detector, `looks_like_anthropic_adaptive_required()`, recognises the literal `thinking.type.adaptive` / `output_config` 400 and retries the call pinned to `claude_adaptive`. That covers both alias-vs-regex misses and proxy translation gaps, and thinking stays on.
  - **`claude_legacy_thinking` is opt-in only.** It is out of auto-routing and reachable only through `ADVISOR_PROFILE=claude_legacy_thinking`, for users still on Claude 3 / 4.0–4.6.
  - **`lib/test_advisor.py`**: stdlib unittest covering profile resolution, payload shape per family, override behaviour, and the literal user-reported error string. Run it with `uv run python -m unittest discover acf-advisor/lib`.
- **v1.3.1**: model-aware parameters. `lib/advisor.py` resolves a profile per call from a `MODEL_PARAM_PROFILES` regex registry, and `build_payload()` dispatches on it instead of always sending both reasoning fields. Profiles: `claude_47_adaptive`, `claude_legacy_thinking`, `gemini_thinking_level`, `openai_reasoning_only`, `default`. Fixes hard 400s on `gemini/gemini-3.x-*` ("Cannot specify both `thinking` and `thinking_level`") and `claude-opus-4-7` ("`thinking.type.enabled` is not supported"). *(Superseded by v1.3.2: the version-pinned regex was incomplete, and aliases that didn't match leaked the legacy shape.)*
- **v1.2.0**: scope discipline, local-team fallback, provider-compatibility fixes, higher timeouts.
  - **Local-team fallback**: when no API endpoint resolves (no key or model after `.env` auto-load and the shell env), the `board` skill switches to local-team mode. Each persona runs as a parallel Claude subagent (`Agent` tool), the orchestrator writes the synthesis, and no external calls are made. The skill announces the switch. When env IS configured, the LLM path is unchanged.
  - **New `--check-env` flag** on `advisor.py`: resolves env (dotenv + shell) without any HTTP call. Exit 0 if `api_key + model` resolve, 2 if either is missing. Stderr gets a structured one-liner (`dotenv=… api_key=… model=… ok|missing=…`) that the board skill uses to choose its path.
  - **Skill scope discipline**: both skill files gained an explicit "DO NOT pre-search env outside the dotenv chain" rule. In earlier live use, the orchestrator improvised bash that read `$HOME/.claude/`, `$HOME/.config/`, `~/.zshrc` and the like; that is now strictly forbidden. Trust `--check-env`'s answer.
  - **Anthropic + thinking + temperature**: `looks_like_temperature_error()` now matches `"may only be set"`, which catches `claude-opus-4-7`'s 400 when temperature ≠ 1 with thinking on. The auto-retry drops the explicit temperature and Anthropic uses its default. Before, this was a hard 400.
  - **Gemini 3 thinking_level conflict**: a new `looks_like_thinking_budget_conflict()` heuristic with its own retry branch. LiteLLM maps `reasoning_effort` to `thinking_level` for Gemini 3 while we also send `thinking.budget_tokens`, so upstream errors with `thinking_level` / `Cannot specify both \`thinking\` …`. The retry drops ONLY `thinking.budget_tokens` and keeps `reasoning_effort`, so thinking stays on through `thinking_level`. This branch is checked BEFORE the broader `reasoning_field_error` branch, whose substrings overlap.
  - **Higher default timeouts**: per-call `run_advisor(timeout=)` 180 → **600s**, board manifest `limits.call_timeout_seconds` 180 → **600**, `BOARD_TOTAL_TIMEOUT_SECONDS` env default 900 → **1800**. Thinking-heavy reasoners on complex prompts were being silently dropped at 180s. The `ADVISOR_TIMEOUT` shell override is unchanged. The CLI's `[advisor] sending: …` line now includes `timeout=Ns`, so the effective per-call timeout is visible.
- **v1.1.0**: the board, backward-compatible at the existing CLI.
  - **New `board` skill**: convenes a multi-persona panel built for one specific decision. Personas are written per call from the 7-step recipe in `persona-design/DESIGN.md`. The release adds a mandatory dimension-extraction step (shown to the user before any persona is composed), a structured persona template (Dimension / Lens / Bias / Blind spots / Output discipline), a static synthesizer prompt, and 4 worked-example panels that show the reasoning chain.
  - **New `scripts/board.py` orchestrator**: validates a JSON manifest, runs personas in parallel via `ThreadPoolExecutor`, injects structured transcripts across `R` rounds, runs the final synthesis, and returns structured markdown plus aggregate cost broken down by model. Defined exit codes, clean on SIGINT/SIGTERM, a total board timeout. It makes NO direct HTTP calls; every call goes through `lib.advisor.run_advisor()`.
  - **New `lib/advisor.py` module**: the core logic (HTTP, auth, dotenv, retries, redaction) moves out of `scripts/advisor.py` and becomes the one copy both scripts share.
  - **`scripts/advisor.py` becomes a thin CLI wrapper.** CLI behavior is byte-for-byte unchanged for callers. It adds a `--system-file` flag (mutually exclusive with `--system`), which keeps prompt content out of `ps`. `looks_like_temperature_error()` now matches the `"deprecated"` substring, which catches newer Claude models that reject a custom temperature with that wording.
  - **`ADVISOR_MODEL` accepts a comma-delimited model pool.** A single value works as before. Several values declare the pool the board draws from: round-robin assignment, optional cross-model triangulation on a critical lens, one model allowed for several personas, one persona allowed on several models.
  - **New env vars**: `BOARD_PARALLELISM` (default 5), `BOARD_TOTAL_TIMEOUT_SECONDS` (default 900), `BOARD_MAX_ROUNDS` (default 5), `ACF_BOARD_BIN` (dev path override).
  - **Round count `R` is chosen by judgment**, not by an autonomous loop. Default `R=1`, with criteria for going higher when personas trade off, the decision is irreversible, and so on. `R` is fixed when the manifest is built; the run never extends it.
  - **No duplication at three layers**: one `lib/` module, one skill protocol (board cross-references advisor), one rendering idiom for per-persona output.
- **v1.0.1**: `.env` auto-load (CWD upward to the first `.git` boundary), a layered script-path resolver in the skill (`ACF_ADVISOR_BIN` → `CLAUDE_PLUGIN_ROOT` → plugin cache glob), a pre-flight `[advisor] sending: …` line, a post-flight zero-reasoning notice, and a `--debug` flag with key redaction. No API changes.
- **v1.0.0**: initial release.
