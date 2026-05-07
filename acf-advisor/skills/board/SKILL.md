---
name: board
description: Convene a board of advisors — multi-persona panel synthesized per call, hypertailored to the decision. Use when the user asks for a "panel", "board of advisors", "multi-perspective analysis", or when a non-trivial decision spans 2+ dimensions and is hard to reverse. Composes 1–5 decision-specific personas (using persona-design/DESIGN.md), confirms them with the user, then dispatches each persona as a parallel Claude Agent subagent that calls advisor.py against the configured LLM pool. Synthesis is the orchestrator's own turn, weighted by the user-chosen priority dimension.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - Agent
---

# board - Convene a board of advisors

## When to use

- The user asks for a "panel", "board", "multi-perspective", "second opinions plural", or "convene the board".
- The user asks for a single second opinion (route to the `advisor` skill) but the question is genuinely multi-dimensional → escalate to a panel and tell the user.
- A non-trivial decision spans **2+ distinct dimensions of correctness** AND is hard to reverse (architecture, security, irreversible migrations, irreversible product calls).
- One specific dimension is decision-critical AND the user has multiple models in `ADVISOR_MODEL` → cross-model triangulation on that lens.

## When NOT to use

- Trivial second opinions — route to the `advisor` skill.
- Single-dimensional non-trivial questions — route to the `advisor` skill with ONE synthesized specialized persona via `--system-file`.
- The user explicitly asked YOU to do the analysis — don't outsource it.

## Architecture (read this first)

The board skill is a pure orchestrator. After the user approves the roster, the skill:

1. Writes each persona's system prompt to a tempfile.
2. Writes the shared user prompt (built per the context-building protocol below) to a tempfile.
3. Dispatches **N parallel `Agent` tool calls in ONE message** — one per persona. Each subagent shells out to `advisor.py` with that persona's system + assigned model and returns the reply verbatim.
4. Collects subagent returns; for multi-round panels, repeats the dispatch with prior-round transcripts appended.
5. Produces synthesis as the orchestrator's own next turn (no subagent).

There is **no Python orchestrator** (no `board.py`). All orchestration is markdown + Claude tool calls. Parallelism is visible and cancellable in the UI.

## Reused from the advisor skill (DO NOT restate)

Refer to `../advisor/SKILL.md`:

- **Context-building protocol — the load-bearing step.** Same checklist + bloat audit applies to the user prompt the board sends to every persona.
- The `### Advisor (<model>) — … says:` rendering header.
- Stderr observability lines (`[advisor] sending: …`, `[advisor] model=…`, the zero-reasoning notice). Each subagent will report these in its return; surface them aggregated.
- The failure-mode table for upstream HTTP errors.

The advisor skill's "do not probe env" rule applies to the **per-persona** invocation (each subagent just shells out). The board skill's **routing decision** is different — it must call `advisor.py --check-env` first to see the project's `.env`. See "Pre-flight" below.

If you find yourself about to write a context-building checklist, an upstream-error table, or stderr observability conventions in this file — STOP. Cross-reference instead.

## Pre-flight: resolve advisor.py and route via `--check-env`

`advisor.py` runs via `uv` (PEP 723 shebang) and auto-loads `.env` from CWD upward. **Do not read shell rc files or `~/.claude/` and do not `env | grep` for keys** — but DO use `advisor.py --check-env` for the routing decision: it runs the same dotenv chain as the real LLM-path call, so its answer matches what the per-persona invocation will see. Direct `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` reads from bash do **not** see the project `.env` (Claude Code's Bash tool inherits the orchestrator process env, not the project dotenv) and will silently misroute to local-team mode.

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-${CLAUDE_PLUGIN_ROOT:-}/scripts/advisor.py}"
[ -x "$ADVISOR_BIN" ] || ADVISOR_BIN="$(ls -1t "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | head -1)"
test -x "$ADVISOR_BIN" || { echo "advisor: not found; install via /plugin install acf-advisor@acf-tools" >&2; exit 1; }
```

Single oracle for routing AND pool enumeration. Use `bash -c` so array syntax works regardless of the orchestrator's interactive shell (Claude Code's Bash tool may run zsh):

```bash
bash -c '
  CHECK_OUT="$("'"$ADVISOR_BIN"'" --check-env 2>&1)"
  CHECK_RC=$?
  echo "$CHECK_OUT" >&2

  if [ "$CHECK_RC" -eq 0 ]; then
    # Prefer models=<csv> (full pool); fall back to model=<first> for older builds.
    POOL_CSV="$(printf "%s\n" "$CHECK_OUT" | sed -n "s/.*[[:space:]]models=\\([^ ]*\\).*/\\1/p" | tail -1)"
    [ -z "$POOL_CSV" ] && POOL_CSV="$(printf "%s\n" "$CHECK_OUT" | sed -n "s/.*[[:space:]]model=\\([^ ]*\\).*/\\1/p" | tail -1)"
    echo "MODE=llm"
    echo "POOL_CSV=$POOL_CSV"
  else
    echo "MODE=local-team"
    echo "POOL_CSV="
  fi
'
```

Capture `MODE=` and `POOL_CSV=` from stdout to drive the rest of the skill. `CHECK_RC=2` is the only condition for local-team fallback. Per-persona `advisor.py` invocations will load the same `.env` themselves — `--check-env` is the routing mirror, not a substitute.

To iterate the pool portably (works in both bash and zsh — zsh does not word-split parameter expansions on `IFS` by default, so use `tr` + line-read):

```bash
echo "$POOL_CSV" | tr ',' '\n' | while IFS= read -r m; do
  [ -n "$m" ] && echo "  - $m"
done
```

## Workflow

### 1. Decide the path

| Path | When | Action |
|---|---|---|
| Default advisor | Trivial second opinion | Route to `../advisor/SKILL.md`. Stop here. |
| Single specialized advisor | Non-trivial, ONE dimension | Synthesize ONE persona (per `persona-design/persona-template.md` — human name + descriptor); call `"$ADVISOR_BIN" --system-file <persona-file>`. Render with the existing advisor protocol, header form `### Advisor (<model>) — <Human Name> (<descriptor>) says:`. Stop here. |
| Panel | Non-trivial, ≥ 2 dimensions | Continue below. |

### 2. Extract decision dimensions (FIRST, BEFORE any persona)

Read `persona-design/DESIGN.md` step 1. Extract dimensions of correctness — concrete, with named failure modes per dimension. Show the user a numbered list:

```
I identify these dimensions in your decision:
1. <dimension> — failure mode: <named consequence>
2. <dimension> — failure mode: <named consequence>
...

Which is most important to you? Synthesis will weight it.
```

**Wait for the user's confirmation/edit AND priority pick.** This step is load-bearing — by the time the roster is composed, the decision is mostly made.

### 3. Pick `R` (round count) using the criteria table

| Signal in the decision context | Target `R` |
|---|---|
| Single dominant dimension; rest are minor | 1 |
| Multiple independent dimensions; little overlap | 1 |
| Two or more dimensions that *trade off against each other* (perf vs. correctness, latency vs. throughput, ergonomics vs. safety) | 2 |
| Decision is genuinely irreversible AND personas may have non-obvious second-order effects | 3 |
| Decision is high-stakes AND involves coupled subsystems needing iterative refinement (rare) | 4–5 |

`R` is fixed at roster-confirmation time. **No autonomous mid-run extension.** Show the user the chosen `R` with a one-line justification at step 5.

### 4. Compose personas (one per confirmed dimension)

Follow `persona-design/DESIGN.md` step 4 + `persona-design/persona-template.md`. Cap at 5. **Apply the naming test**: if the descriptor could apply to a different decision without changing any words, rewrite. Each persona gets two halves joined by an em dash: a **human first + last name** with light humour AND a decision-specific descriptor (e.g. `Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`). Mix cultures across the panel — Japanese, Indian, Persian, Slavic, Nordic, Latin, African, etc.; do not produce a roster of five Anglo names. Cross-model clones share the descriptor but get distinct human names. Each persona's system prompt MUST include all five template fields, especially **Blind spots (by design)** with at least 2 named.

### 5. Cross-model decision

| Pool size | Decision |
|---|---|
| 1 model | All personas share it. Skip cross-model triangulation. |
| 2+ models, default | Round-robin assignment from the pool in roster order. |
| 2+ models, explicit pin | If a specific lens benefits from a specific model's reasoning style, pin and state the reason at confirmation. |
| 2+ models, **cross-model triangulation** | Clone the priority-dimension lens across 2–3 models (same `system` + `display_name`, distinct `id`s). Cross-model agreement-or-disagreement on that lens is itself the diagnostic. |

### 6. Show the roster, get confirmation

For each persona, one line:

```
<Human Name> — <descriptor> [<id>] (<model>). Covers: <dimension>. Reason for this slot: <one sentence>.
```

Plus the chosen `R` with a one-line justification. If you used cross-model cloning, name it explicitly — and confirm each clone has a distinct human name.

Wait for user approve/edit/veto. **This step is free of advisor cost.**

### 7. Build the per-persona user prompt

Apply the **Context-building protocol** from `../advisor/SKILL.md` (mandatory checklist + bloat audit + size discipline) to assemble ONE user prompt that all personas will see. Structure exactly as the advisor protocol specifies:

```
## Question
<one sharp sentence>

## Context
<load-bearing facts only>

## What I've considered
- Considered X — ruled out because Y.

## Decision dimensions
1. <priority dimension>
2. <other dimensions>

## What I want from you
<concrete, named ask — same for all personas; persona system prompts shape HOW each one answers>
```

Write the assembled prompt to `/tmp/board-user-r1.txt`. Write each persona's system prompt to `/tmp/board-<persona-id>.sys`.

### 8. Dispatch — N parallel Agent subagents in ONE message

Issue **a single orchestrator message containing N parallel `Agent` tool calls** (one per persona). Each call:

- `subagent_type: "general-purpose"`
- `description`: `Advisor: <Human Name>` (≤ 5 words)
- `prompt`: the deterministic instruction below. The subagent's only job is to shell out and return the result. **No env probing, no synthesis, no opinion of its own.**

  > You are a mechanical wrapper. Execute exactly the bash command below, capture stdout and stderr, and return them verbatim. Do not summarize, do not paraphrase, do not add commentary. Do not probe env. Do not read shell rc files. Do not run any other tool.
  >
  > Return your result in this exact format:
  >
  > ```
  > ### Advisor (<model>) — <Human Name> (<descriptor>) says:
  >
  > <stdout verbatim>
  >
  > <stderr filtered to [advisor] lines, verbatim>
  > ```
  >
  > If the command exits non-zero, return the exit code, stdout, and stderr verbatim under the same header with `[FAILED rc=N]` prepended.
  >
  > The bash command:
  >
  > ```bash
  > "$ADVISOR_BIN" --system-file /tmp/board-<persona-id>.sys --model <model> < /tmp/board-user-r1.txt
  > ```
  >
  > (Substitute the literal `$ADVISOR_BIN` path resolved by the orchestrator, the actual persona-id, and the assigned model.)

### 9. Multi-round (R ≥ 2)

After collecting round-1 returns, build the round-2 user prompt by appending prior-round transcripts:

```
<round-1 user prompt>

## Prior round (k=1) takes
### Persona: <Human Name> — <descriptor> [<id>]
<verbatim>

### Persona: <Human Name> — <descriptor> [<id>]
<verbatim>
…
```

Write to `/tmp/board-user-r2.txt`. Dispatch another N parallel `Agent` calls in ONE message, same pattern, pointing at the new prompt file. Each persona only sees prior-round (not mid-round) takes. Repeat for each round up to `R`.

If a per-persona transcript is large, truncate to `~20000 / N` chars per persona to keep the round-2 prompt within size discipline.

### 10. Synthesis — orchestrator turn (no subagent)

After all rounds complete, **you (the orchestrator) produce the synthesis directly** as your own next turn. Use `persona-design/synthesizer.md` as your meta-prompt. Rules:

- Weight by the user's priority dimension.
- Name disagreement explicitly (don't paper over it — disagreement is signal).
- No flattery, no filler.
- End with a concrete recommendation or, if the panel is genuinely split, a named tradeoff for the user to choose.

The synthesizer is always Claude — not the advisor LLM. Diversity comes from the personas; integration comes from you.

### 11. Render output

```
## Round 1
### Advisor (<model>) — <Human Name 1> (<descriptor 1>) says:
<verbatim subagent reply>

### Advisor (<model>) — <Human Name 2> (<descriptor 2>) says:
<verbatim subagent reply>
…

## Round 2 (if R ≥ 2)
…

## Synthesis
<your synthesis>

## My take
<one short paragraph: agree with synthesis, where you'd push back, recommended next step>

[board] mode=<llm|local-team> personas=N rounds=R
```

## Local-team mode

Triggered when `advisor.py --check-env` exits non-zero (rc=2) — i.e. after walking the project's `.env` chain plus the orchestrator's shell env, either no api key (`LITELLM_API_KEY` / `OPENAI_API_KEY`) or no model (`ADVISOR_MODEL` / `OPENAI_MODEL`) could be resolved. Same workflow as steps 1–7 above (dimension extraction, roster confirmation, prompt building) — only step 8 differs.

**Tell the user explicitly** what's happening, in one short paragraph:

```
No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY or no ADVISOR_MODEL
in env or project .env). Running in local-team mode — each persona is a Claude subagent.
No external API calls.
```

### Step 8 (local-team)

Dispatch N parallel `Agent` calls. Each subagent's prompt is the persona's full system text (Dimension / Lens / Bias / Blind spots / Output discipline) + this marker line + the user prompt:

> You are roleplaying as the advisor described above. Respond ONLY in that voice. Output discipline applies. Do not ask follow-up questions; if information is missing, name what's missing and proceed with stated assumptions.

Render with `(local)` instead of `(<model>)` in the headers. Cross-model triangulation is N/A — all "models" are Claude.

## Bloat guards (verbatim — do not soften)

- **Cap at 5 personas total.** Each cross-model clone counts as a separate slot.
- **Distinct dimensions per persona.** If two personas have ≥ 70% lens overlap AND share a model, merge or drop one. Cross-model clones of the same lens are exempt — that's intentional triangulation.
- **Cross-model cloning is an explicit choice with a stated reason.** Default to single-model per lens.
- **`R` is fixed at roster-confirmation time.** No autonomous mid-run extension. Disagreement after `R` rounds IS the signal.
- **Default `R = 1`** unless a specific signal in the criteria table warrants more. Justify the choice in one line.
- **If your synthesized roster maps 1:1 to a worked example in `persona-design/examples/`, you skipped dimension extraction.** Redo from step 2.

## Failure handling

Per-persona failures are isolated by design: if one subagent's `advisor.py` invocation fails, that persona's slot is rendered with `[FAILED rc=N]` and stderr; synthesis runs over the remaining N-1 takes. Don't retry the whole board for a single failure. If ALL personas fail, surface the common error and stop — likely an env or endpoint issue.

For specific upstream errors (HTTP 401, 404, rate limits, etc.), see the failure-modes table in `../advisor/SKILL.md`.

## Critical rules

- **Do not probe env outside the project.** No reading `~/.zshrc`, `~/.claude/`, `~/.config/`. The skill asks `advisor.py --check-env` (which runs the same dotenv chain as the LLM-path call) for the routing decision and the pool enumeration. Do not read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash — Claude Code's Bash tool does not auto-source project `.env`, so those reads silently misroute to local-team mode.
- **Cross-reference, don't restate** — the context-building protocol, observability conventions, and upstream-error handling all live in `../advisor/SKILL.md`.
- **Synthesize personas per call** — never reuse a roster from a worked example. Examples teach the *reasoning chain*, not the output.
- **Surface dimensions to the user BEFORE composing personas.** The roster confirmation later is a backup, not the main lever.
- **Cap at 5 personas. Default `R = 1`.** Both bumps require an explicit justification visible to the user.
- **N parallel subagents in ONE orchestrator message.** Sequential dispatch defeats the architecture.
- **Synthesis is YOUR turn, not a subagent call.** Avoids the synthesizer adopting a persona of its own.
