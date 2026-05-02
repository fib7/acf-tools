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

> **For multi-dimensional decisions, see the `board` skill** (`../board/SKILL.md`). It convenes a panel of synthesized personas, each covering one dimension, and integrates them. Use this `advisor` skill when one second opinion is enough.

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

## Pre-flight: resolve the script and check env

The script auto-loads `.env` from CWD upward (stops at the first `.env`, a `.git` directory, or filesystem root). Already-set env vars are preserved — shell wins over `.env`. So as long as the user runs Claude from inside their project tree, no manual `source .env` is needed.

> **DO NOT pre-search for env vars outside the project tree.** The script already auto-loads `.env` from CWD upward, stopping at the first `.env`, a `.git` directory, or FS root. Already-exported shell vars are preserved. You **MUST NOT**:
> - read `$HOME/.claude/**`, `$HOME/.config/**`, `$HOME/.zshrc`, `$HOME/.bashrc`, or any file outside CWD's ancestor chain
> - run `env | grep` for keys (the script does this internally and reports what it found via the `[advisor] sending: dotenv=… ` line)
> - probe alternative env file locations (`~/.config/qlaude/env`, `~/.claude/settings.json`, etc.)
>
> If you need a programmatic probe, run `"$ADVISOR_BIN" --check-env` (exits 0 if env OK, 2 if missing — no HTTP call). Otherwise let the script run; if env is missing it will print `[advisor] missing API key: …` or `[advisor] missing model: …` and exit. Surface that error verbatim and tell the user to add the var to their project `.env` (or shell-export it).

`$CLAUDE_PLUGIN_ROOT` is unreliable in skill-spawned bash (substitution is broken in skill markdown — see anthropics/claude-code#9354). Use this layered resolver to find the script:

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-}"
if [ -z "$ADVISOR_BIN" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py" ]; then
  ADVISOR_BIN="${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py"
fi
if [ -z "$ADVISOR_BIN" ]; then
  ADVISOR_BIN=$(ls -1 "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | sort -V | tail -1)
fi
test -x "$ADVISOR_BIN" || { echo "advisor: not found (tried ACF_ADVISOR_BIN, CLAUDE_PLUGIN_ROOT, ~/.claude/plugins/cache); install via: /plugin install acf-advisor@acf-tools" >&2; exit 1; }
```

Resolution order: `$ACF_ADVISOR_BIN` (dev override) → `$CLAUDE_PLUGIN_ROOT/scripts/advisor.py` (best-effort) → highest-semver match in the plugin cache.

You don't need to pre-check the API key — the script will error with `[advisor] missing API key: …` if neither `LITELLM_API_KEY` nor `OPENAI_API_KEY` is set after auto-load. If that happens, tell the user to add the var to their `.env` (or shell-export it) and retry.

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

Pipe the prompt to `"$ADVISOR_BIN"` via stdin (handles arbitrary size; uv runs the script via the PEP 723 shebang).

```bash
cat <<'PROMPT' | "$ADVISOR_BIN"
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

**Combined invocation** (resolver + call in one bash block — easiest):

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-}"
[ -z "$ADVISOR_BIN" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py" ] && ADVISOR_BIN="${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py"
[ -z "$ADVISOR_BIN" ] && ADVISOR_BIN=$(ls -1 "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | sort -V | tail -1)
cat <<'PROMPT' | "$ADVISOR_BIN"
…your structured prompt here…
PROMPT
```

## Response handling

Show the advisor's reply to the user verbatim under a clear header, then add your own brief take:

```
### Advisor (<model>) says:

<verbatim advisor reply>

### My take:

<one short paragraph: agree/disagree, caveats, what to actually do>
```

Surface the stderr observability lines to the user so they see what was sent and how much it cost:

- `[advisor] sending: model=… effort=… thinking_budget=… dotenv=…` — confirms what was actually requested and which `.env` was loaded.
- `[advisor] model=… prompt=… completion=… total=… reasoning=…` — token usage (per-call cost). Thinking mode adds reasoning-token cost and latency by design — that's the tradeoff for considered answers.
- `[advisor] note: reasoning fields sent but upstream returned 0 reasoning tokens …` — informational; means the model or proxy didn't engage thinking. The reply is still valid; suggest `ADVISOR_REASONING_EFFORT=off` if the user wants to skip the cost on this model.

If the script printed a `--- reasoning ---` block on stderr, the user can see the advisor's chain of thought there; don't re-print it on stdout unless the user asks.

## Disable escape hatch

Thinking mode is **on by default** (`reasoning_effort=high`, `thinking.budget_tokens=8000`). For a one-off cheap call, the user can set `ADVISOR_REASONING_EFFORT=off` in the environment before invoking. Don't disable it on your own — the whole point of the advisor is considered answers.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `advisor: not found (tried ACF_ADVISOR_BIN, CLAUDE_PLUGIN_ROOT, ~/.claude/plugins/cache)` | plugin not installed in this Claude Code instance | Tell user to run `/plugin install acf-advisor@acf-tools`, or set `ACF_ADVISOR_BIN` to a checkout path |
| `[advisor] missing API key` | env not set and no `.env` found | Tell user to add `LITELLM_API_KEY` to `.env` in their project, or export it; verify the script loaded the right `.env` (see `dotenv=` in the `sending:` line) |
| `[advisor] missing model` | `ADVISOR_MODEL` not set | Ask user which model to use; suggest setting `ADVISOR_MODEL` in `.env` |
| `HTTP 401` | bad key | Verify key is current; surface error to user |
| `HTTP 404 model not found` | wrong model name for the endpoint | List available models, ask user to pick |
| `upstream rejected reasoning fields` (auto-retry) | non-reasoning model | The script retries without thinking; reply will still come through |
| `upstream rejected temperature override` (auto-retry) | reasoning-only model that doesn't accept `temperature` | Auto-retried with default temperature; reply will still come through |
| `note: reasoning fields sent but upstream returned 0 reasoning tokens` | model/proxy ignored thinking fields | Informational — reply is fine. If user wants to avoid the wasted round-trip cost on this model, set `ADVISOR_REASONING_EFFORT=off` |
| `network error` | endpoint unreachable | Confirm `LITELLM_BASE_URL` is correct and reachable |

## Critical rules

- **One-shot only**. Each invocation is independent. No conversation memory.
- **Never echo the API key** in any output, even on error.
- **Cap context at ~20KB**. Trim or summarize if larger; the advisor doesn't need the entire file.
- **Show the advisor's reply verbatim**. Don't paraphrase. Add your take separately so the user can compare.
- **Thinking on by default**. Don't pass `ADVISOR_REASONING_EFFORT=off` unless the user asked.
