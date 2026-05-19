---
name: board
description: Convene a board of advisors — multi-persona panel synthesized per call, hypertailored to the decision. Use when the user asks for a "panel", "board of advisors", "multi-perspective analysis", or when a non-trivial decision spans 2+ dimensions and is hard to reverse. Composes 1–5 decision-specific personas (using persona-design/DESIGN.md), confirms them with the user, then runs each persona — in LLM mode as a parallel advisor.py call against the configured LLM pool, in local-team mode as a parallel Claude Agent subagent. Synthesis is the orchestrator's own turn, weighted by the user-chosen priority dimension.
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
3. Runs each persona — **N parallel calls in ONE orchestrator message**, one per persona:
   - **LLM mode**: N parallel `Bash` calls, each running `advisor.py` with that persona's system + assigned model. The orchestrator runs the commands itself and captures stdout/stderr directly — no subagent relay.
   - **Local-team mode**: N parallel `Agent` subagents, each roleplaying a persona (no external API). This is the only path that uses subagents.
4. Collects results; for multi-round panels, repeats with prior-round transcripts appended.
5. Produces synthesis as the orchestrator's own next turn (no subagent).

There is **no Python orchestrator** (no `board.py`). All orchestration is markdown + Claude tool calls. Parallelism is visible and cancellable in the UI.

## Reused from the advisor skill (DO NOT restate)

Refer to `../advisor/SKILL.md`:

- **Context-building protocol — the load-bearing step.** Same checklist + bloat audit applies to the user prompt the board sends to every persona.
- The `### Advisor (<model>) — … says:` rendering header.
- Stderr observability lines (`[advisor] sending: …`, `[advisor] model=…`, the zero-reasoning notice). Each `advisor.py` call's stderr carries these `[advisor]` lines; surface them aggregated.
- The failure-mode table for upstream HTTP errors.

The advisor skill's "do not probe env" rule applies to the **per-persona** invocation (each `advisor.py` call resolves its own env). The board skill's **routing decision** is different — it must call `advisor.py --check-env` first to see the project's `.env`. See "Pre-flight" below.

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

**Output discipline for this turn.** Emit ONLY the per-persona lines above plus the chosen `R` justification. Do NOT add `Cultures: …`, `Model split: 2x foo, 1x bar`, persona-count tallies, dimension recaps, or any other derived/decorative summary. Model and descriptor are already inline in each persona line; culture mix is a composition heuristic for you, not content for the user.

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

### 8. Run advisor.py — N parallel Bash calls in ONE message

Issue **a single orchestrator message containing N parallel `Bash` tool calls** (one per persona). There is no subagent and no relay — you wrote the persona/prompt tempfiles in step 7, you run the commands, you render the results in step 11.

Each call runs:

```bash
"$ADVISOR_BIN" --system-file /tmp/board-<persona-id>.sys --model <model> < /tmp/board-user-r1.txt
```

Substitute the literal `$ADVISOR_BIN` path resolved in pre-flight, the actual persona-id, and the assigned model. The calls run concurrently. `advisor.py` prints the advisor reply to **stdout** and `[advisor]` observability lines to **stderr** — keep the two separate when you render.

If a call exits non-zero, note the exit code; its slot is rendered with `[FAILED rc=N]` and its stderr (see Failure handling).

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

Write to `/tmp/board-user-r2.txt`. Issue another N parallel `Bash` calls in ONE message, same pattern, pointing at the new prompt file. Each persona only sees prior-round (not mid-round) takes. Repeat for each round up to `R`.

If a per-persona transcript is large, truncate to `~20000 / N` chars per persona to keep the round-2 prompt within size discipline.

### 10. Synthesis — orchestrator turn (no subagent)

After all rounds complete, **you (the orchestrator) produce the synthesis directly** as your own next turn. Use `persona-design/synthesizer.md` as your meta-prompt. Rules:

- Weight by the user's priority dimension; the persona whose lens covers it gets the most weight on that dimension specifically.
- Name disagreement explicitly — disagreement is signal, not a wording problem to paper over. Convergence across distinct lenses is the strongest signal; convergence within one lens (cross-model triangulation) is the next strongest.
- Calibrate confidence to convergence. Speak plainly where personas agreed; name uncertainty where they didn't.
- Before issuing the recommendation, name the strongest argument against it in one sentence (drawing from a dissenting persona where possible). If none of the personas surfaced one, say so explicitly — that itself is a flag.
- Escalate, don't soften. If a persona named a fallacy or specification gap in the asker's framing, carry it into the synthesis verbatim. "Mostly working" stays "broken"; "just needs X" stays "incomplete".
- End with a concrete recommendation, or — if the panel genuinely doesn't converge — a named tradeoff: the two paths and what each commits to. Do not split the difference into a vague middle.

The synthesizer is always Claude — not the advisor LLM. Diversity comes from the personas; integration comes from you.

### 11. Render output

```
## Round 1
### Advisor (<model>) — <Human Name 1> (<descriptor 1>) says:
<advisor reply — stdout, verbatim>

### Advisor (<model>) — <Human Name 2> (<descriptor 2>) says:
<advisor reply — stdout, verbatim>
…

## Round 2 (if R ≥ 2)
…

## Synthesis
<your synthesis>

## My take
<one short paragraph: agree with synthesis, where you'd push back, recommended next step>

[board] mode=<llm|local-team> personas=N rounds=R
```

**Strict template.** The output ends at the `[board]` line. No `Cultures:`, no `Model split:`, no persona-count tally, no parameter dump, no "Personas used:" recap. The `[board]` line is the only trailing metadata permitted. If you feel the urge to add a roster diagnostic, that's the urge to suppress.

## Local-team mode

Triggered when `advisor.py --check-env` exits non-zero (rc=2) — i.e. after walking the project's `.env` chain plus the orchestrator's shell env, either no api key (`LITELLM_API_KEY` / `OPENAI_API_KEY`) or no model (`ADVISOR_MODEL` / `OPENAI_MODEL`) could be resolved. Same workflow as steps 1–7 above (dimension extraction, roster confirmation, prompt building) — only step 8 differs.

**Tell the user explicitly** what's happening, in one short paragraph:

```
No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY or no ADVISOR_MODEL
in env or project .env). Running in local-team mode — each persona is a Claude subagent.
No external API calls.
```

### Step 8 (local-team)

Local-team mode is the **only** path that uses `Agent` subagents — there is no external endpoint, so each persona must be a Claude instance roleplaying. Dispatch N parallel `Agent` calls. Each subagent's prompt is the persona's full system text (Dimension / Lens / Bias / Blind spots / Output discipline) + this marker line + the user prompt:

> You are roleplaying as the advisor described above. Respond ONLY in that voice. Output discipline applies. Do not ask follow-up questions; if information is missing, name what's missing and proceed with stated assumptions.

Render with `(local)` instead of `(<model>)` in the headers. Cross-model triangulation is N/A — all "models" are Claude.

## Bloat guards (verbatim — do not soften)

- **Cap at 5 personas total.** Each cross-model clone counts as a separate slot.
- **Distinct dimensions per persona.** If two personas have ≥ 70% lens overlap AND share a model, merge or drop one. Cross-model clones of the same lens are exempt — that's intentional triangulation.
- **Cross-model cloning is an explicit choice with a stated reason.** Default to single-model per lens.
- **`R` is fixed at roster-confirmation time.** No autonomous mid-run extension. Disagreement after `R` rounds IS the signal.
- **Default `R = 1`** unless a specific signal in the criteria table warrants more. Justify the choice in one line.
- **If your synthesized roster maps 1:1 to a worked example in `persona-design/examples/`, you skipped dimension extraction.** Redo from step 2.
- **No roster meta-summary in user-facing output.** Culture mix and model-pool composition are *inputs to your composition decision*, not outputs. Never emit `Cultures: …`, `Model split: …`, persona-count tallies, or similar decorative summaries. The trailing `[board]` line is the only summary metadata permitted.

## Failure handling

Per-persona failures are isolated by design: if one `advisor.py` call fails, that persona's slot is rendered with `[FAILED rc=N]` and stderr; synthesis runs over the remaining N-1 takes. Don't retry the whole board for a single failure. If ALL personas fail, surface the common error and stop — likely an env or endpoint issue.

For specific upstream errors (HTTP 401, 404, rate limits, etc.), see the failure-modes table in `../advisor/SKILL.md`.

## Critical rules

- **Do not probe env outside the project.** No reading `~/.zshrc`, `~/.claude/`, `~/.config/`. The skill asks `advisor.py --check-env` (which runs the same dotenv chain as the LLM-path call) for the routing decision and the pool enumeration. Do not read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash — Claude Code's Bash tool does not auto-source project `.env`, so those reads silently misroute to local-team mode.
- **Cross-reference, don't restate** — the context-building protocol, observability conventions, and upstream-error handling all live in `../advisor/SKILL.md`.
- **Synthesize personas per call** — never reuse a roster from a worked example. Examples teach the *reasoning chain*, not the output.
- **Surface dimensions to the user BEFORE composing personas.** The roster confirmation later is a backup, not the main lever.
- **Cap at 5 personas. Default `R = 1`.** Both bumps require an explicit justification visible to the user.
- **N parallel calls in ONE orchestrator message** — `Bash` calls in LLM mode, `Agent` subagents in local-team mode. Sequential dispatch defeats the architecture.
- **Synthesis is YOUR turn, not a subagent call.** Avoids the synthesizer adopting a persona of its own.
