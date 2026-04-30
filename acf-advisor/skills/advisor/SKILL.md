---
name: advisor
description: Consult another LLM (with thinking/reasoning mode on) for a second opinion. Use when stuck on a design decision, want to validate an approach, or need domain expertise outside Claude's strengths. Builds focused context and calls an OpenAI-compatible endpoint configured via env vars (LITELLM_API_KEY/LITELLM_BASE_URL/ADVISOR_MODEL or OPENAI_* fallbacks). Thinking mode is on by default.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# advisor - Consult another LLM for a second opinion

## When to use

- The user asks for a "second opinion", "another model's take", "what would GPT/Gemini/Claude-via-LiteLLM say".
- You're about to make a non-trivial design decision and want a sanity check.
- The domain is outside your strengths (niche library, recent change, specialized math/legal/etc.).
- You're stuck debugging and want a fresh framing.
- Before a risky / hard-to-reverse change, want an independent review.

## When NOT to use

- Simple lookups you can answer directly.
- Tasks the user explicitly asked **you** to do — don't outsource your job.
- When env vars aren't set and the user hasn't asked you to consult an external model.
- Looping calls (this is one-shot; no conversation memory).

## Pre-flight check

Before invoking, verify the API key is present:

```bash
test -n "$LITELLM_API_KEY" || test -n "$OPENAI_API_KEY" || \
  echo "advisor: no API key set (LITELLM_API_KEY / OPENAI_API_KEY)"
```

If neither is set, **stop** and tell the user: "advisor needs `LITELLM_API_KEY` (or `OPENAI_API_KEY`) and `ADVISOR_MODEL` in the environment. Source your `.env` or export them, then retry."

## Context-building protocol

The advisor LLM has zero context about this conversation. Build a focused prompt:

1. **One-sentence question** at the top.
2. **Relevant artifacts** — read with Read/Grep, include only what's needed. Cap total context at ~20KB; if larger, summarize.
3. **What you've considered** — your current take, alternatives ruled out, why.
4. **What you want from the advisor** — "agree/disagree", "list risks", "name an alternative", etc.

Assemble into a single text blob:

```
## Question
<one sentence>

## Context
<files / errors / prior decisions, trimmed>

## What I've considered
<your current thinking + ruled-out alternatives>

## What I want from you
<concrete ask>
```

## Invocation

Pipe the prompt to the script via stdin (handles arbitrary size). The script lives at `$CLAUDE_PLUGIN_ROOT/scripts/advisor.py` and is executed via uv (the shebang invokes `uv run --script`).

```bash
cat <<'PROMPT' | "$CLAUDE_PLUGIN_ROOT/scripts/advisor.py"
## Question
Should I use a goroutine + channel or a sync.Mutex for this counter?

## Context
<paste the relevant ~50 lines>

## What I've considered
Mutex is simpler; channel feels idiomatic but I'm not sure it's worth the complexity here.

## What I want from you
A direct recommendation and the one risk I'm most likely missing.
PROMPT
```

**Heredoc rules**: use `'PROMPT'` (single-quoted) so `$`, backticks, and backslashes inside the prompt aren't expanded.

## Response handling

Show the advisor's reply to the user verbatim under a clear header, then add your own brief take:

```
### Advisor (<model>) says:

<verbatim advisor reply>

### My take:

<one short paragraph: agree/disagree, caveats, what to actually do>
```

Surface the `[advisor] model=… prompt=… completion=… reasoning=…` line from stderr so the user sees token usage. Thinking mode adds reasoning-token cost and latency by design — that's the tradeoff for considered answers.

If the script printed a `--- reasoning ---` block on stderr, the user can see the advisor's chain of thought there; don't re-print it on stdout unless the user asks.

## Disable escape hatch

Thinking mode is **on by default** (`reasoning_effort=high`, `thinking.budget_tokens=8000`). For a one-off cheap call, the user can set `ADVISOR_REASONING_EFFORT=off` in the environment before invoking. Don't disable it on your own — the whole point of the advisor is considered answers.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `[advisor] missing API key` | env not set | Tell user to source `.env` or export `LITELLM_API_KEY` |
| `[advisor] missing model` | `ADVISOR_MODEL` not set | Ask user which model to use; suggest setting `ADVISOR_MODEL` |
| `HTTP 401` | bad key | Verify key is current; surface error to user |
| `HTTP 404 model not found` | wrong model name for the endpoint | List available models, ask user to pick |
| `upstream rejected reasoning fields` (auto-retry) | non-reasoning model | The script retries without thinking; reply will still come through |
| `network error` | endpoint unreachable | Confirm `LITELLM_BASE_URL` is correct and reachable |

## Critical rules

- **One-shot only**. Each invocation is independent. No conversation memory.
- **Never echo the API key** in any output, even on error.
- **Cap context at ~20KB**. Trim or summarize if larger; the advisor doesn't need the entire file.
- **Show the advisor's reply verbatim**. Don't paraphrase. Add your take separately so the user can compare.
- **Thinking on by default**. Don't pass `ADVISOR_REASONING_EFFORT=off` unless the user asked.
