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
- Env vars set in your shell (or sourced from a `.env`) — see [Configuration](#configuration).

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

Example `.env`:
```
LITELLM_API_KEY=sk-...
LITELLM_BASE_URL=https://litellm.example.com/v1
ADVISOR_MODEL=claude-sonnet-4-6
```

Source it: `set -a && source .env && set +a` (or use your shell's loader).

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
Skill: cat <<EOF | $CLAUDE_PLUGIN_ROOT/scripts/advisor.py
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

```bash
# Confirm vars are set in *your* shell (Claude inherits them)
env | grep -E '(LITELLM|OPENAI)_API_KEY'
```

If nothing, source your `.env`: `set -a && source .env && set +a`.

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
