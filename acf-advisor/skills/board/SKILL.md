---
name: board
description: Convene a board of advisors, a multi-persona panel composed per call and tailored to the decision. Use when the user asks for a "panel", "board of advisors", "multi-perspective analysis", or when a non-trivial decision spans 2+ dimensions and is hard to reverse. Composes 1–5 decision-specific personas (using persona-design/DESIGN.md), confirms them with the user, then runs every persona in parallel, in LLM mode as an advisor.py call against the configured LLM pool and in local-team mode as a Claude Agent subagent. Synthesis is the orchestrator's own turn, weighted by the priority dimension the user picked.
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
- The user asks for a single second opinion (the `advisor` skill's job) but the question spans 2+ distinct dimensions → escalate to a panel and tell the user.
- A non-trivial decision spans **2+ distinct dimensions of correctness** and is hard to reverse (architecture, security, irreversible migrations, irreversible product calls).
- One dimension decides the outcome and the user has 2+ models in `ADVISOR_MODEL` → cross-model triangulation on that lens.

## When NOT to use

- Trivial second opinions: route to the `advisor` skill.
- Single-dimensional non-trivial questions: route to the `advisor` skill with one synthesized specialized persona via `--system-file`.
- The user explicitly asked **you** to do the analysis. Do it; don't outsource it.

## Architecture (read this first)

The board skill only orchestrates. After the user approves the roster, you:

1. Write each persona's system prompt to a tempfile.
2. Write the shared user prompt (built with the context-building protocol below) to a tempfile.
3. Run every persona at once, **N parallel calls in one orchestrator message**, one per persona:
   - **LLM mode**: N parallel `Bash` calls, each running `advisor.py` with that persona's system prompt and assigned model. You run the commands yourself and read stdout/stderr directly. No subagent relays them.
   - **Local-team mode**: N parallel `Agent` subagents, each roleplaying one persona (no external API). This is the only path that uses subagents.
4. Collect the results. For a multi-round panel, repeat with the prior round's transcripts appended.
5. Write the synthesis as your own next turn (no subagent).

There is **no Python orchestrator** (no `board.py`). All orchestration is this markdown plus Claude tool calls, so the user sees each parallel call in the UI and can cancel it.

## Reused from the advisor skill (do not restate)

These live in `../advisor/SKILL.md`:

- **Context-building protocol**, the step that decides answer quality. The same checklist and bloat audit apply to the user prompt the board sends to every persona.
- The `### Advisor (<model>) — … says:` rendering header.
- Stderr observability lines (`[advisor] sending: …`, `[advisor] model=…`, the zero-reasoning notice). Every `advisor.py` call writes these `[advisor]` lines to stderr; show them aggregated.
- The failure-mode table for upstream HTTP errors.

The advisor skill's "do not probe env" rule covers the **per-persona** invocation, where each `advisor.py` call resolves its own env. The board's **routing decision** is different: you need the project's `.env` to make it, so call `advisor.py --check-env` first. See "Pre-flight" below.

Do not write a context-building checklist, an upstream-error table or stderr observability conventions into this file. Point to the advisor skill instead.

## Pre-flight: resolve advisor.py and route via `--check-env`

`advisor.py` runs via `uv` (PEP 723 shebang) and loads `.env` from the CWD upward on its own. **Do not read shell rc files or `~/.claude/`, and do not `env | grep` for keys.** Do use `advisor.py --check-env` for the routing decision. It runs the same dotenv chain as the real LLM-path call, so its answer matches what each per-persona invocation will see. Reading `${ADVISOR_MODEL}` or `${LITELLM_API_KEY}` directly from bash does **not** see the project `.env`, because Claude Code's Bash tool inherits the orchestrator's process env and not the project dotenv. Those reads route to local-team mode by mistake, with no error.

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-${CLAUDE_PLUGIN_ROOT:-}/scripts/advisor.py}"
[ -x "$ADVISOR_BIN" ] || ADVISOR_BIN="$(ls -1t "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | head -1)"
test -x "$ADVISOR_BIN" || { echo "advisor: not found; install via /plugin install acf-advisor@acf-tools" >&2; exit 1; }
# One private directory per board run. Fixed /tmp/board-* names are shared by every session on the
# machine, so two overlapping boards can read each other's prompt files.
BOARD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/board.XXXXXXXX")"
echo "BOARD_TMP=$BOARD_TMP"
```

Carry `$BOARD_TMP` through every later step and remove it when the board is done.

One call decides the route and lists the model pool. Wrap it in `bash -c` so the array syntax works whatever the orchestrator's interactive shell is (Claude Code's Bash tool may run zsh):

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

Read `MODE=` and `POOL_CSV=` from stdout; they drive the rest of the skill. `CHECK_RC=2` is the only condition for local-team fallback. Each per-persona `advisor.py` invocation loads the same `.env` itself. `--check-env` mirrors that load for routing and does not replace it.

To iterate the pool in both bash and zsh, split with `tr` and read line by line (zsh does not word-split parameter expansions on `IFS` by default):

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
| Single specialized advisor | Non-trivial, one dimension | Synthesize one persona per `persona-design/persona-template.md` (human name plus descriptor), then call `"$ADVISOR_BIN" --system-file <persona-file>`. Render with the existing advisor protocol, header form `### Advisor (<model>) — <Human Name> (<descriptor>) says:`. Stop here. |
| Panel | Non-trivial, ≥ 2 dimensions | Continue below. |

### 2. Extract decision dimensions (first, before any persona)

Read step 1 of `persona-design/DESIGN.md`. Extract the dimensions of correctness: concrete ones, each with a named failure mode. Show the user a numbered list:

```
I identify these dimensions in your decision:
1. <dimension> — failure mode: <named consequence>
2. <dimension> — failure mode: <named consequence>
...

Which is most important to you? Synthesis will weight it.
```

**Wait until the user confirms or edits the list and picks a priority.** Do not hurry this step. By the time the roster is composed, most of the decision has been made.

### 3. Pick `R` (round count) using the criteria table

| Signal in the decision context | Target `R` |
|---|---|
| Single dominant dimension; rest are minor | 1 |
| Multiple independent dimensions; little overlap | 1 |
| Two or more dimensions that *trade off against each other* (perf vs. correctness, latency vs. throughput, ergonomics vs. safety) | 2 |
| Decision is irreversible and personas may have non-obvious second-order effects | 3 |
| Decision is high-stakes and involves coupled subsystems needing iterative refinement (rare) | 4–5 |

`R` is fixed when the user confirms the roster. **Never extend it yourself mid-run.** Show the user the chosen `R` with a one-line justification at step 6.

### 4. Compose personas (one per confirmed dimension)

Follow step 4 of `persona-design/DESIGN.md` and `persona-design/persona-template.md`. Cap the panel at 5. **Apply the naming test**: if the descriptor would fit a different decision word for word, rewrite it. Each persona's name has two halves joined by an em dash: a **human first and last name** with light humour, then a decision-specific descriptor (e.g. `Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`). Mix cultures across the panel (Japanese, Indian, Persian, Slavic, Nordic, Latin, African and others). Do not produce a roster of five Anglo names. Cross-model clones share the descriptor but get distinct human names. Each persona's system prompt MUST include all five template fields, especially **Blind spots (by design)** with at least two named.

### 5. Cross-model decision

| Pool size | Decision |
|---|---|
| 1 model | All personas share it. Skip cross-model triangulation. |
| 2+ models, default | Round-robin assignment from the pool in roster order. |
| 2+ models, explicit pin | If a lens benefits from one model's reasoning style, pin that model and state the reason at confirmation. |
| 2+ models, **cross-model triangulation** | Clone the priority-dimension lens across 2–3 models (same `system` + `display_name`, distinct `id`s). Whether the models agree on that lens is itself the diagnostic. |

### 6. Show the roster, get confirmation

For each persona, one line:

```
<Human Name> — <descriptor> [<id>] (<model>). Covers: <dimension>. Reason for this slot: <one sentence>.
```

Add the chosen `R` with a one-line justification. If you cloned a lens across models, say so, and check that each clone has a distinct human name.

**Output discipline for this turn.** Emit only the per-persona lines above and the `R` justification. Do not add `Cultures: …`, `Model split: 2x foo, 1x bar`, persona-count tallies, dimension recaps or any other derived or decorative summary. Each persona line already carries its model and descriptor, and the culture mix is a composition heuristic for you, not content for the user.

Wait for the user to approve, edit or veto. **No advisor call has run yet, so this step has no advisor cost.**

### 7. Build the per-persona user prompt

Apply the **Context-building protocol** from `../advisor/SKILL.md` (mandatory checklist, bloat audit, size discipline) to assemble one user prompt that every persona sees. Use exactly the structure the advisor protocol specifies:

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

Write the assembled prompt to `$BOARD_TMP/user-r1.txt` and each persona's system prompt to
`$BOARD_TMP/<persona-id>.sys`.

**Use the private directory from pre-flight, never a fixed `/tmp/board-*` path.** Two sessions on
one machine convening overlapping boards share those names. Session B's write can land after A
wrote its prompt but before A's parallel `advisor.py` calls open it. A's personas then answer B's
question, and A renders and synthesises the result under its own roster heading, with nothing
anywhere showing the swap.

### 8. Run advisor.py: N parallel Bash calls in one message

Send **one orchestrator message containing N parallel `Bash` tool calls**, one per persona. No subagent or relay is involved: you wrote the persona and prompt tempfiles in step 7, you run the commands, and you render the results in step 11.

Each call runs:

```bash
"$ADVISOR_BIN" --system-file "$BOARD_TMP/<persona-id>.sys" --model <model> < "$BOARD_TMP/user-r1.txt"
```

Substitute the literal `$ADVISOR_BIN` path resolved in pre-flight, the actual persona-id and the assigned model. The calls run concurrently. `advisor.py` prints the advisor reply to **stdout** and `[advisor]` observability lines to **stderr**. Keep the two apart when you render.

If a call exits non-zero, note the exit code. Its slot is rendered with `[FAILED rc=N]` and its stderr (see Failure handling).

### 9. Multi-round (R ≥ 2)

Once the round-1 replies are in, build the round-2 user prompt by appending the prior round's transcripts:

```
<round-1 user prompt>

## Prior round (k=1) takes
### Persona: <Human Name> — <descriptor> [<id>]
<verbatim>

### Persona: <Human Name> — <descriptor> [<id>]
<verbatim>
…
```

Write it to `$BOARD_TMP/user-r2.txt`. Issue another N parallel `Bash` calls in one message, same pattern, pointing at the new prompt file. A persona sees replies from earlier rounds only, never one from the round in progress. Repeat for each round up to `R`.

If a persona's transcript is large, truncate it to `~20000 / N` chars so the round-2 prompt stays within size discipline.

### 10. Synthesis: orchestrator turn (no subagent)

After the last round, **you (the orchestrator) write the synthesis directly** as your next turn, with `persona-design/synthesizer.md` as your meta-prompt. Rules:

- Weight by the user's priority dimension. On that dimension, the persona whose lens covers it gets the most weight.
- Name disagreement explicitly and do not smooth it over in the wording. Convergence across distinct lenses is the strongest signal; convergence within one lens (cross-model triangulation) is the next strongest.
- Calibrate confidence to convergence. Speak plainly where personas agreed and name the uncertainty where they didn't.
- Before giving the recommendation, state the strongest argument against it in one sentence, drawn from a dissenting persona where possible. If no persona raised one, say so. That absence is a warning sign in itself.
- Escalate, don't soften. If a persona named a fallacy or a specification gap in the asker's framing, carry it into the synthesis verbatim. "Mostly working" stays "broken"; "just needs X" stays "incomplete".
- End with a concrete recommendation or, if the panel does not converge, a named tradeoff: the two paths and what each commits to. Do not split the difference into a vague middle.

You write the synthesis; the advisor LLM never does. The personas supply the range of views and you integrate them.

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

**Strict template.** The output ends at the `[board]` line. No `Cultures:`, no `Model split:`, no persona-count tally, no parameter dump, no "Personas used:" recap. The `[board]` line is the only trailing metadata allowed, so a roster diagnostic has no place in the output.

## Local-team mode

Runs when `advisor.py --check-env` exits non-zero (rc=2): after walking the project's `.env` chain and the orchestrator's shell env, it resolved no API key (`LITELLM_API_KEY` / `OPENAI_API_KEY`) or no model (`ADVISOR_MODEL` / `OPENAI_MODEL`). Steps 1–7 above (dimension extraction, roster confirmation, prompt building) stay the same. Only step 8 differs.

**Tell the user explicitly** what is happening, in one short paragraph:

```
No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY or no ADVISOR_MODEL
in env or project .env). Running in local-team mode — each persona is a Claude subagent.
No external API calls.
```

### Step 8 (local-team)

Local-team mode is the **only** path that uses `Agent` subagents. There is no external endpoint, so each persona has to be a Claude instance roleplaying it. Dispatch N parallel `Agent` calls. Each subagent's prompt is the persona's full system text (Dimension / Lens / Bias / Blind spots / Output discipline), then this marker line, then the user prompt:

> You are roleplaying as the advisor described above. Respond ONLY in that voice. Output discipline applies. Do not ask follow-up questions; if information is missing, name what's missing and proceed with stated assumptions.

Render with `(local)` instead of `(<model>)` in the headers. Cross-model triangulation does not apply, since every persona runs on Claude.

## Bloat guards (do not soften)

- **Cap at 5 personas total.** Each cross-model clone counts as a separate slot.
- **Distinct dimensions per persona.** If two personas have ≥ 70% lens overlap and share a model, merge them or drop one. Cross-model clones of one lens are exempt, because that overlap is the triangulation.
- **Cross-model cloning is an explicit choice with a stated reason.** Default to one model per lens.
- **`R` is fixed when the user confirms the roster.** Never extend it yourself mid-run. If the personas still disagree after `R` rounds, that disagreement is the finding.
- **Default `R = 1`** unless a specific signal in the criteria table calls for more. Justify the choice in one line.
- **If your roster maps 1:1 onto a worked example in `persona-design/examples/`, you skipped dimension extraction.** Redo from step 2.
- **No roster meta-summary in user-facing output.** Culture mix and model-pool composition feed *your composition decision*. They are not output. Never emit `Cultures: …`, `Model split: …`, persona-count tallies or similar summaries. The trailing `[board]` line is the only summary metadata allowed.

## Failure handling

One persona's failure does not touch the others. If one `advisor.py` call fails, render that persona's slot with `[FAILED rc=N]` and its stderr, and run the synthesis over the remaining N-1 replies. Don't retry the whole board for one failure. If every persona fails, show the common error and stop: the env or the endpoint is the likely cause.

For specific upstream errors (HTTP 401, 404, rate limits and so on), see the failure-modes table in `../advisor/SKILL.md`.

## Critical rules

- **Do not probe env outside the project.** No reading `~/.zshrc`, `~/.claude/` or `~/.config/`. Ask `advisor.py --check-env` (it runs the same dotenv chain as the LLM-path call) for the routing decision and the model pool. Do not read `${ADVISOR_MODEL}` / `${LITELLM_API_KEY}` directly from bash. Claude Code's Bash tool does not source the project `.env`, so those reads route to local-team mode by mistake, with no error.
- **Cross-reference, don't restate.** The context-building protocol, observability conventions and upstream-error handling all live in `../advisor/SKILL.md`.
- **Synthesize personas per call.** Never reuse a roster from a worked example: the examples teach the *reasoning chain*, not the output.
- **Show the user the dimensions before composing personas.** The roster confirmation later is a backup, not the main check.
- **Cap at 5 personas. Default `R = 1`.** Raising either needs an explicit justification the user can see.
- **N parallel calls in one orchestrator message**: `Bash` calls in LLM mode, `Agent` subagents in local-team mode. Dispatching them one at a time throws away the parallelism the design is built on.
- **The synthesis is your turn, not a subagent call,** so the synthesizer never adopts a persona of its own.
