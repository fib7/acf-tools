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
- Looping calls (this is one-shot; no conversation memory).

## Pre-flight: resolve advisor.py

`advisor.py` runs via `uv` (PEP 723 shebang) and auto-loads `.env` from the CWD upward. The script handles env resolution itself. **Do not probe env, do not read shell rc files, do not grep for keys.** If env is missing, the script exits with `[advisor] missing API key: …` or `[advisor] missing model: …` — surface that error verbatim to the user and tell them to add the missing var to their project `.env`.

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-${CLAUDE_PLUGIN_ROOT:-}/scripts/advisor.py}"
[ -x "$ADVISOR_BIN" ] || ADVISOR_BIN="$(ls -1t "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | head -1)"
test -x "$ADVISOR_BIN" || { echo "advisor: not found; install via /plugin install acf-advisor@acf-tools" >&2; exit 1; }
```

That's it. Pipe your prompt to `"$ADVISOR_BIN"`. The script handles dotenv, env validation, the HTTP call, and retries.

## Context-building protocol — the load-bearing step

The advisor LLM has zero context — what you assemble is all it gets, and answer quality is upper-bounded by it. **Invest real effort here.** A perfect prompt against a weak context gets a mediocre answer. A strong context against a sharp question gets the second opinion you're paying for.

### Mandatory checklist (every field is required)

1. **Question** — one sentence, sharp and answerable as stated.
   - BAD: "What do you think about our auth design?"
   - GOOD: "Given a 50M-row users table, weekly schema migrations, and a hard requirement that no migration takes a write-lock > 30s, should we use shadow tables + dual-write or expand-contract with online DDL — and what's the second-order failure mode I'm most likely missing?"
   - The question must encode the constraints that make the obvious answers wrong.

2. **Context** — every load-bearing fact, nothing else.
   - **Code**: paste actual relevant excerpts (with file:line citations), not summaries. If a function's body matters for the reasoning, include it. If only the signature matters, include only the signature.
   - **Errors**: paste verbatim error messages, stack traces, log lines. Not paraphrases.
   - **Numbers**: concrete values that bound the problem (sizes, latencies, QPS, row counts, deadlines).
   - **Constraints**: what rules out the obvious answers — performance budget, compliance, backwards compatibility, team capacity, deadline.
   - **Architecture**: surrounding system shape *only insofar as it constrains the answer*. Not a tour of the repo.

3. **What I've considered** — alternatives you've evaluated AND ruled out, with reasons.
   - Format: "Considered X — ruled out because Y."
   - Prevents the advisor from wasting a turn proposing what you've already discarded.
   - If you haven't considered alternatives yet, do that work first, before calling the advisor.

4. **Decision dimensions and priority** — which trade-offs are in play and which matters most.
   - Name the top 1–2 dimensions and which is paramount. The advisor will weight its answer accordingly.

5. **What I want from you** — concrete, named ask. Pick from:
   - "Recommend one of {A, B, C} and name the second-order risk."
   - "List the failure modes of approach X I haven't named."
   - "Give me the strongest counterargument to my plan."
   - "Identify the load-bearing assumption that, if wrong, breaks this whole approach."
   - Avoid open-ended "what do you think?" — it produces vague answers.

### Bloat audit — do this before sending

Re-read the assembled prompt. For every paragraph, ask: **"Would the advisor's answer change if I deleted this?"**

- No → delete it.
- Yes → keep it; consider if it should be sharper or expanded.

Specifically strip:

- Framing/throat-clearing prose ("As you may know…", "Some background…", "Just to set context…")
- File contents that are referenced but not central — summarize in one line instead
- Conversation history (the advisor doesn't care how you got here)
- Restated constraints (say each constraint once, in the place it's load-bearing)
- "Here's some background" sections that are actually background

### Size discipline

Cap total assembled context at ~20KB. If load-bearing facts exceed 20KB, the question is too broad — narrow it. (If you're tempted to send 50KB, you're probably asking two questions; split into two advisor calls.)

### Final structure

```
## Question
<one sharp sentence>

## Context
<load-bearing facts only — code, errors, numbers, constraints, architecture-as-it-constrains>

## What I've considered
- Considered X — ruled out because Y.
- Considered Z — ruled out because W.

## Decision dimensions
1. <dimension> (priority)
2. <dimension>

## What I want from you
<one of the named asks above>
```

## Invocation

Pipe the assembled prompt to `"$ADVISOR_BIN"` via stdin. Heredoc with single-quoted delimiter so `$`, backticks, and backslashes are not expanded:

```bash
cat <<'PROMPT' | "$ADVISOR_BIN"
## Question
…

## Context
…

## What I've considered
…

## Decision dimensions
…

## What I want from you
…
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

Surface the stderr observability lines so the user sees what was sent and how much it cost:

- `[advisor] sending: model=… effort=… thinking_budget=… timeout=… dotenv=…` — confirms what was requested and which `.env` was loaded.
- `[advisor] model=… prompt=… completion=… total=… reasoning=…` — token usage. Thinking mode adds reasoning-token cost and latency by design.
- `[advisor] note: reasoning fields sent but upstream returned 0 reasoning tokens …` — informational; means the model or proxy didn't engage thinking. Reply is still valid; suggest `ADVISOR_REASONING_EFFORT=off` if the user wants to skip the cost on this model.

If the script printed a `--- reasoning ---` block on stderr, the user can see the advisor's chain of thought there; don't re-print it on stdout unless asked.

## Disable escape hatch

Thinking mode is **on by default** (`reasoning_effort=high`, `thinking.budget_tokens=8000`). For a one-off cheap call, the user can set `ADVISOR_REASONING_EFFORT=off` in the environment. Don't disable it on your own — the whole point of the advisor is considered answers.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `advisor: not found` | plugin not installed | Tell user to run `/plugin install acf-advisor@acf-tools`, or set `ACF_ADVISOR_BIN` to a checkout path |
| `[advisor] missing API key` | env not set and no `.env` found | Tell user to add `LITELLM_API_KEY` to `.env` in their project, or shell-export it; verify the script loaded the right `.env` (see `dotenv=` in the `sending:` line) |
| `[advisor] missing model` | `ADVISOR_MODEL` not set | Ask user which model to use; suggest setting `ADVISOR_MODEL` in `.env` |
| `HTTP 401` | bad key | Verify key is current; surface error to user |
| `HTTP 404 model not found` | wrong model name for the endpoint | List available models, ask user to pick |
| `upstream rejected reasoning fields` (auto-retry) | non-reasoning model | The script retries without thinking; reply will still come through |
| `note: reasoning fields sent but upstream returned 0 reasoning tokens` | model/proxy ignored thinking fields | Informational. If user wants to avoid the wasted round-trip, set `ADVISOR_REASONING_EFFORT=off` |
| `network error` | endpoint unreachable | Confirm `LITELLM_BASE_URL` is correct and reachable |

## Critical rules

- **Do not probe env outside the project.** No reading `~/.zshrc`, `~/.claude/`, `~/.config/`. The script handles env. If something is missing, the script tells you.
- **One-shot only.** Each invocation is independent. No conversation memory.
- **Never echo the API key** in any output, even on error.
- **Cap context at ~20KB** and run the bloat audit before sending.
- **Show the advisor's reply verbatim.** Don't paraphrase. Add your take separately so the user can compare.
- **Thinking on by default.** Don't pass `ADVISOR_REASONING_EFFORT=off` unless the user asked.
