---
name: board
description: Convene a board of advisors — multi-persona panel synthesized per call, hypertailored to the decision. Use when the user asks for a "panel", "board of advisors", "multi-perspective analysis", or when a non-trivial decision spans 2+ dimensions and is hard to reverse. Composes 1–5 decision-specific personas (using persona-design/DESIGN.md), confirms them with the user, runs them in parallel via scripts/board.py over an OpenAI-compatible endpoint pool (comma-delimited ADVISOR_MODEL), optionally for multiple rounds when personas trade off against each other, and renders a synthesis weighted by the user-chosen priority dimension.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Agent
---

# board - Convene a board of advisors

## When to use

- The user asks for a "panel", "board", "multi-perspective", "second opinions plural", or "convene the board".
- The user asks for a single second opinion (route to the `advisor` skill) but the question is genuinely multi-dimensional → escalate to a panel and tell the user.
- A non-trivial decision spans **2+ distinct dimensions of correctness** AND is hard to reverse (architecture, security, irreversible migrations, irreversible product calls).
- One specific dimension is decision-critical AND the user has multiple models in `ADVISOR_MODEL` → cross-model triangulation on that lens.

## When NOT to use

- Trivial second opinions — route to the `advisor` skill (default `DEFAULT_SYSTEM_PROMPT`).
- Single-dimensional non-trivial questions — route to the `advisor` skill with ONE synthesized specialized persona via `--system-file`. Same cost as default, sharper signal. (See "Single specialized advisor" below.)
- The user explicitly asked YOU to do the analysis — don't outsource it.
- Looping calls — board is one-shot, no conversation memory across invocations.

## Reused from the advisor skill (DO NOT restate)

The board skill **composes** the advisor skill mechanically — same code path via `lib.advisor.run_advisor()`, same protocol document. Do not duplicate any of these here. Refer to `../advisor/SKILL.md`:

- The structured user-prompt format: `## Question / ## Context / ## What I've considered / ## What I want from you`.
- Stderr observability conventions (`[advisor] sending: …`, `[advisor] model=…`, the zero-reasoning notice). Board emits the same per-persona, prefixed `[board:<persona_id>]`.
- The failure-mode table for upstream HTTP errors (rate limits, model-not-found, reasoning-fields rejection, temperature deprecation).
- Output-rendering convention: the advisor's reply verbatim under a clear header. The board uses the same idiom multiplied — one `### Advisor (<model>) — <persona> says:` block per persona per round, ending with a `## Synthesis` block.
- The path-resolver pattern (env override → `CLAUDE_PLUGIN_ROOT` → plugin cache glob), reproduced below for `$BOARD_BIN` and `$ADVISOR_BIN`.

If you find yourself about to write a structured-prompt template, an upstream-error table, or stderr observability conventions in this file — STOP. Cross-reference instead.

## Pre-flight: resolve script paths and probe env

```bash
ADVISOR_BIN="${ACF_ADVISOR_BIN:-}"
[ -z "$ADVISOR_BIN" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py" ] && ADVISOR_BIN="${CLAUDE_PLUGIN_ROOT}/scripts/advisor.py"
[ -z "$ADVISOR_BIN" ] && ADVISOR_BIN=$(ls -1 "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/advisor.py 2>/dev/null | sort -V | tail -1)
test -x "$ADVISOR_BIN" || { echo "advisor: not found; install via: /plugin install acf-advisor@acf-tools" >&2; exit 1; }

BOARD_BIN="${ACF_BOARD_BIN:-}"
[ -z "$BOARD_BIN" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" ] && BOARD_BIN="${CLAUDE_PLUGIN_ROOT}/scripts/board.py"
[ -z "$BOARD_BIN" ] && BOARD_BIN=$(ls -1 "$HOME"/.claude/plugins/cache/*/acf-advisor/*/scripts/board.py 2>/dev/null | sort -V | tail -1)
test -x "$BOARD_BIN" || { echo "board: not found; install via: /plugin install acf-advisor@acf-tools" >&2; exit 1; }

# Probe env. Exit 0 → LLM path. Exit 2 → local-team fallback (see below).
"$ADVISOR_BIN" --check-env; ENV_RC=$?
```

> **DO NOT pre-search for env vars outside the project tree.** The script already auto-loads `.env` from CWD upward, stopping at the first `.env`, a `.git` directory, or FS root. Already-exported shell vars are preserved. You **MUST NOT**:
> - read `$HOME/.claude/**`, `$HOME/.config/**`, `$HOME/.zshrc`, `$HOME/.bashrc`, or any file outside CWD's ancestor chain
> - run `env | grep` for keys (the `--check-env` line shows what was resolved)
> - probe alternative env file locations (`~/.config/qlaude/env`, `~/.claude/settings.json`, etc.)
>
> Trust `--check-env`'s answer. If it returns 2, branch to local-team fallback below. Do **not** fish for env in random places.

Read `ADVISOR_MODEL` (comma-delimited list); split into the `available_models` array for the manifest. A single-value env yields a single-element pool. **Only read `ADVISOR_MODEL` when `ENV_RC == 0`** — local-team mode does not use it (no models, just subagents).

## Execution path: LLM or local-team

| `--check-env` exit | Path | What runs the personas |
|---|---|---|
| 0 | LLM path (default) | `board.py` → `lib.advisor.run_advisor()` per persona, parallel via `ThreadPoolExecutor`. The "Workflow" section below applies as written. |
| 2 | Local-team fallback | Each persona becomes a parallel `Agent` tool call (`subagent_type: general-purpose`). No external API. Step 7 is replaced — see "Local-team fallback" below. |

## Local-team fallback

Triggered when `ENV_RC == 2`. The board still runs — just with no external API calls. Personas become local Claude subagents.

### When local-team applies

- No `LITELLM_API_KEY` / `OPENAI_API_KEY` reachable via env or project `.env` after `load_dotenv()`.
- AND/OR no `ADVISOR_MODEL` / `OPENAI_MODEL` set.

The user typically has not configured an LLM endpoint for this project yet. **Do not nag them to configure one** — proceed with local-team. If they later configure env, the LLM path activates automatically (no plugin reinstall needed).

### Workflow (replaces step 7+8 of the LLM workflow)

1. **Tell the user explicitly** what's happening, in one short paragraph:

   ```
   No external advisor endpoint configured (no LITELLM_API_KEY/OPENAI_API_KEY in env or
   project .env). Falling back to local-team mode — each persona will run as a Claude
   subagent. No external API calls.
   ```

2. **Same as steps 1–6 of the LLM workflow**: extract dimensions → priority pick → roster confirmation. These are skill-side and don't need API access.

3. **Dispatch round 1**: ONE message containing N parallel `Agent` tool calls (one per persona). Each call uses:
   - `subagent_type: "general-purpose"`
   - `description`: `Advisor: <display_name>` (≤ 5 words, e.g. `Advisor: token-lifecycle skeptic`)
   - `prompt`: the persona's full system text (Dimension / Lens / Bias / Blind spots / Output discipline) + the marker line below + the same `## Question / ## Context / ## What I've considered / ## What I want from you` user prompt the LLM path uses.

   **Marker line** (verbatim, after the persona system text and before the user prompt):

   > You are roleplaying as the advisor described above. Respond ONLY in that voice. Output discipline applies. Do not ask follow-up questions; if information is missing, name what's missing and proceed with stated assumptions.

4. **Round k + 1** (only if `R ≥ 2`): NEW Agent dispatch per persona (subagents have no memory across calls). The prompt appends the structured prior-round transcript exactly as `board.py` does:

   ```
   ## Prior round (k=N) takes
   ### Persona: <display_name> [<id>]
   <verbatim>
   ```

   Each persona only sees prior-round (not mid-round) takes. Truncate per-take to `max_prompt_chars / personas` if needed.

5. **Synthesis**: YOU (the orchestrator) produce the synthesis directly — one Claude turn, NOT another `Agent` dispatch. Use `persona-design/synthesizer.md` as your meta-prompt: weight by the user's priority dimension, name disagreement, no flattery, no filler. The orchestrator IS the synthesizer in this mode.

6. **Render**: same idiom as the LLM path, with `(<model>)` replaced by `(local)`:

   ```
   ### Advisor (local) — <persona_display_name> says:

   <verbatim subagent reply>
   ```

   For `R ≥ 2`, group by round under `## Round 1` / `## Round 2` headers as the LLM path does. End with `## Synthesis` block.

7. **Cost line** (replaces `[board] aggregate: …`): print to user-visible output a single line at the end:

   ```
   [board:local] mode=local-team personas=N rounds=R subagent_calls=N×R
   ```

### Local-team constraints

| Rule | Reason |
|---|---|
| All persona-cap and naming-test rules from the LLM path **still apply**. | Local-team is the same panel design, different runtime. |
| **Cross-model triangulation is N/A.** All "models" are Claude. | Pool size = 0. There's no diversity to triangulate. If you would have used cloning across models in the LLM path, just keep one persona — cloning Claude across cloned slots adds noise, not signal. |
| **R is fixed at manifest-build time** (same as LLM path). | No autonomous mid-run extension, ever. |
| **`board.py` is NOT invoked** in local-team mode. | The orchestrator is pure skill markdown + Agent tool calls. No JSON manifest is built; no `[board]` stderr lines. |
| **Synthesis is a Claude turn, not an Agent call.** | Avoids the synthesizer adopting a persona of its own. |

## Workflow

### 1. Decide the path

| Path | When | Action |
|---|---|---|
| Default advisor | Trivial second opinion | Route to `../advisor/SKILL.md`. Stop here. |
| Single specialized advisor | Non-trivial, ONE dimension | Synthesize ONE persona (per `persona-design/persona-template.md`); call `"$ADVISOR_BIN" --system-file <persona-file>`. Render with the existing advisor protocol. Stop here. |
| Panel | Non-trivial, ≥ 2 dimensions | Continue below. |

### 2. Extract decision dimensions (FIRST, BEFORE any persona)

Read `persona-design/DESIGN.md` step 1. Extract dimensions of correctness — concrete, with named failure modes per dimension. Show the user a numbered markdown list:

```
I identify these dimensions in your decision:
1. <dimension> — failure mode: <named consequence>
2. <dimension> — failure mode: <named consequence>
...

Which is most important to you? Synthesis will weight it.
```

**Wait for the user's confirmation/edit AND priority pick.** This step is the load-bearing one — by the time the roster is composed, the decision is mostly made. Don't skip it for time.

### 3. Pick `R` (round count) using the criteria table

| Signal in the decision context | Target `R` |
|---|---|
| Single dominant dimension; rest are minor | 1 |
| Multiple independent dimensions; little overlap | 1 |
| Two or more dimensions that *trade off against each other* (perf vs. correctness, latency vs. throughput, ergonomics vs. safety) | 2 |
| Decision is genuinely irreversible AND personas may have non-obvious second-order effects | 3 |
| Decision is high-stakes AND involves coupled subsystems needing iterative refinement (rare) | 4–5 (capped at `BOARD_MAX_ROUNDS`) |

`R` is fixed at manifest-build time. **No autonomous mid-run extension.** Show the user the chosen `R` with a one-line justification at step 5; user can override.

### 4. Compose personas (one per confirmed dimension)

Follow `persona-design/DESIGN.md` step 4 + `persona-design/persona-template.md`. Cap at 5. **Apply the naming test**: if a persona name could apply to a different decision without changing any words, rewrite. Each persona's system prompt MUST include all five template fields, especially **Blind spots (by design)** with at least 2 named.

### 5. Cross-model decision

| Pool size | Decision |
|---|---|
| 1 model | All personas share it. Skip cross-model triangulation. |
| 2+ models, default | Round-robin assignment from the pool in manifest order. board.py wraps if persona count > pool size. |
| 2+ models, explicit pin | If a specific lens benefits from a specific model's reasoning style, set `personas[i].model` and state the reason at confirmation. |
| 2+ models, **cross-model triangulation** | Clone the priority-dimension lens across 2–3 models (same `system` + `display_name`, distinct `id`s). The cross-model agreement-or-disagreement on that lens is itself the diagnostic. Costs roster slots — use deliberately. |

### 6. Show the roster, get confirmation

For each persona, one line:

```
<name> [<id>] (<model>) — covers: <dimension>. Reason for this slot: <one sentence>.
```

Plus the chosen `R` with one-line justification. If you used cross-model cloning, name it explicitly:

```
NOTE: <persona-name> cloned across <models> for cross-model triangulation on the priority dimension.
```

Wait for user approve/edit/veto. **This step is free of advisor cost.**

### 7. Build the manifest, run the panel

**If `ENV_RC == 2`, skip this step entirely — execute the Local-team fallback (above) instead.** Steps 1–6 still apply; only the dispatch mechanism differs. Do NOT build a manifest, do NOT invoke `board.py`.

Manifest schema (validated by `board.py` before any LLM call):

```
{
  "schema_version": 1,
  "user_prompt": "...",                    // structured Q/Context/Considered/Want
  "priority_dimension": "...",             // from step 2
  "available_models": ["m1", "m2", ...],   // parsed from ADVISOR_MODEL
  "personas": [
    {
      "id": "regex_safe_id",               // [A-Za-z0-9_.-]{1,64}, unique
      "display_name": "human-readable",
      "system": "<filled-in template>",    // from persona-template.md
      "model": "m1" | null                 // null = round-robin auto-assign
    }, ...
  ],
  "rounds": <R>,
  "synthesizer_system": null,              // omit to use the static persona-design/synthesizer.md
  "synthesizer_model": null,               // omit to use available_models[0]
  "limits": {                              // optional
    "call_timeout_seconds": 180,
    "max_stdout_chars": 200000,
    "max_prompt_chars": 120000,
    "max_transcript_chars": 600000
  }
}
```

Pipe to `board.py`:

```bash
cat /tmp/board-manifest.json | "$BOARD_BIN" > /tmp/board-output.md 2> /tmp/board-stderr.log
RC=$?
```

### 8. Render output to the user

`board.py` already emits structured markdown (per-round per-persona blocks using the existing advisor protocol's `### Advisor (<model>) — <persona> says:` header pattern, then a `## Synthesis` block). Show it verbatim.

Surface the aggregate cost line from `[board] aggregate: ...` stderr — broken down by model. Include any `status=degraded` notice.

After showing the panel output, add **your own brief take** in 2–3 sentences: do you agree with the synthesis, where would you push back, what's the recommended next step?

## Bloat guards (verbatim — do not soften)

- **Cap at 5 personas total.** Each cross-model clone counts as a separate slot.
- **Distinct dimensions per persona.** If two personas have ≥ 70% lens overlap AND share a model, merge or drop one. Cross-model clones of the same lens are exempt — that's intentional triangulation.
- **Cross-model cloning is an explicit choice with a stated reason.** Default to single-model per lens. Reach for cloning only when one specific lens is critical AND the pool offers genuinely different reasoners.
- **`R` is fixed at manifest-build time.** No autonomous mid-run extension. Disagreement after `R` rounds IS the signal — surface it via synthesis, don't run more rounds for show.
- **Default `R = 1`** unless a specific signal in the criteria table warrants more. Justify the choice in one line; the user sees and can override.
- **If your synthesized roster maps 1:1 to a worked example in `persona-design/examples/`, you skipped the dimension extraction.** Redo from step 2.

## Failure handling

`board.py` defines exit codes (see its docstring). On non-zero, surface the meaning to the user:

| Exit | Meaning |
|---|---|
| 0 | Synthesis succeeded (possibly degraded — failures listed inline; check stderr for `status=degraded`) |
| 10 | Invalid manifest — report all `[board] invalid manifest: …` lines verbatim and re-build |
| 20 | Zero persona successes in some round — likely a global config issue (bad endpoint, bad models); investigate `[advisor]` retry messages |
| 30 | Synthesis call failed — partial transcripts are still on stdout, surface them with the synthesis-failure note |
| 124 | Total board timeout exceeded — partial synthesis ran; report what completed |
| 130 | Interrupted (SIGINT/SIGTERM) — clean exit |

Per-persona failures are isolated by design: if one persona's call raises, board.py captures it inline and synthesis runs over remaining `N-1` takes. Don't retry the whole board for a single failure.

## Critical rules

- **Cross-reference, don't restate** — the prompt format, observability conventions, and upstream-error handling all live in `../advisor/SKILL.md`. Read it; don't duplicate.
- **Synthesize personas per call** — never reuse a roster from a worked example. The examples teach the *reasoning chain*, not the output.
- **Surface dimensions to the user BEFORE composing personas.** The roster confirmation later is a backup, not the main lever.
- **State the priority dimension** in the manifest. The synthesizer prompt weights by it.
- **Cap at 5 personas. Default `R = 1`.** Both bumps require an explicit justification visible to the user.
- **Per-persona render uses the existing advisor protocol's idiom.** Don't invent new rendering — multiplicity is the only difference.
