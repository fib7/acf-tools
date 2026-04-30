# ACF Advisor Plugin

> Consult another LLM (with thinking mode on) for a second opinion.

A lean plugin that ships a single `advisor` skill. Claude builds focused context from your project and pipes it to any OpenAI-compatible Chat Completions endpoint — LiteLLM, OpenAI, OpenRouter, an internal proxy — for an independent take. Thinking / reasoning mode is enabled by default.

---

## What It Does

1. **Adds the `advisor` skill** — Claude invokes it when you ask for a second opinion or it judges the question would benefit from one.
2. **Builds context for you** — restates the question, gathers relevant files/errors/decisions, trims to a sensible size.
3. **Calls the endpoint with thinking on** — sends both `reasoning_effort: "high"` (OpenAI o-series style) and `thinking: {type: enabled, budget_tokens: 8000}` (Anthropic-via-LiteLLM style). Falls back gracefully if the upstream rejects either field.
4. **Returns both perspectives** — the advisor's reply verbatim, plus Claude's own brief take.

**Not** for: quick lookups Claude can answer directly, or tasks you asked Claude to do (don't let it outsource its job).

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
| Model | `ADVISOR_MODEL` | `OPENAI_MODEL` (no default — error if unset) |
| Reasoning effort | `ADVISOR_REASONING_EFFORT` | default `high`; values: `low`, `medium`, `high`, `off` |
| Thinking budget (tokens) | `ADVISOR_THINKING_BUDGET` | default `8000` |
| HTTP timeout (seconds) | `ADVISOR_TIMEOUT` | default `180` |
| Disable `.env` auto-load | `ADVISOR_NO_DOTENV=1` or `--no-dotenv` flag | auto-load on by default |
| Override script path (dev) | `ACF_ADVISOR_BIN` | resolver falls back to plugin cache |

Example `.env`:
```
LITELLM_API_KEY=sk-...
LITELLM_BASE_URL=https://litellm.example.com/v1
ADVISOR_MODEL=claude-sonnet-4-6
```

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

## How It Works

**One file, one skill, one call.**

```
User asks for a second opinion
    ↓
Claude invokes the `advisor` skill
    ↓
Skill: pre-flight env check
    ↓
Skill: build context (Question / Context / What I've considered / What I want)
    ↓
Skill: resolve $ADVISOR_BIN (override → CLAUDE_PLUGIN_ROOT → cache glob)
    ↓
Skill: cat <<EOF | "$ADVISOR_BIN"
    ↓
advisor.py: POST {BASE_URL}/chat/completions
            with reasoning_effort + thinking fields
    ↓
advisor.py: prints reply to stdout, usage to stderr
    ↓
Claude shows reply verbatim + own take
```

**Key files:**

| File | Purpose |
|---|---|
| `scripts/advisor.py` | uv PEP 723 script; stdlib-only HTTP client |
| `skills/advisor/SKILL.md` | When to use, how to build context, invocation pattern |

**Reasoning fields, both styles:**
- `reasoning_effort` (string `low`/`medium`/`high`) — OpenAI o-series.
- `thinking: {type: enabled, budget_tokens: N}` — Anthropic via LiteLLM.

LiteLLM and most OpenAI-compatible proxies pass through fields they don't recognize. If the upstream rejects them, the script auto-retries once without and warns on stderr.

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

Lean, env-var-driven, thinking-on-by-default. One skill, one script, one POST. When you want a considered second opinion without leaving your session.

### Changelog

- **v1.0.1** — `.env` auto-load (CWD upward to first `.git` boundary), layered script-path resolver in the skill (`ACF_ADVISOR_BIN` → `CLAUDE_PLUGIN_ROOT` → plugin cache glob), pre-flight `[advisor] sending: …` line, post-flight zero-reasoning notice, `--debug` flag with key redaction. No API changes.
- **v1.0.0** — Initial release.
