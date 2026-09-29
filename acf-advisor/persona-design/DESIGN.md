# Persona synthesis recipe

How to compose a board panel for one specific decision. This is a *process*, not a catalog of ready-made personas: you write the personas per call, name them after the decision's own nouns, and give each one exactly one dimension of correctness.

If you catch yourself reaching for "the usual five" (pragmatist, skeptic, security, perf, architect), you have skipped the recipe. Start over from step 1.

---

## Step 1: Extract decision dimensions (show the user, BEFORE any persona)

Read the question and its context, then list the dimensions of correctness this decision has. A dimension is a way the decision can fail. Make each one concrete and specific to the decision, with the failure mode named:

> Too vague: "security"
> Specific: "token expiry race during cutover when both old and new auth flows are live"

> Too vague: "performance"
> Specific: "GC pressure if the per-request allocation count rises >2x at p99"

> Too vague: "operability"
> Specific: "rollback safety if the migration discovers a corrupted row partway through"

Show the user the dimensions as a numbered markdown list, with the failure mode named for each. **Wait for confirmation**, and ask: *"Which of these dimensions is most important to you? Synthesis will weight it."* The answer is the priority dimension.

Everything later rests on this step. Roster confirmation comes too late to shape the panel: by then the personas exist and the user is rubber-stamping them. The real decision happens on the dimension list, so put it in front of the user.

## Step 2: Decide the path (single advisor or panel)

| Dimensions identified | Path |
|---|---|
| 1 dominant dimension; rest are minor | Single specialized advisor (route to `advisor` skill with a synthesized persona via `--system-file`) |
| ≥ 2 distinct dimensions | Panel |
| Trivial / lookup-style question | Default advisor (existing skill, no persona synthesis needed) |

A single specialized advisor is the cheapest non-trivial path: it costs the same as the default advisor and brings a sharper lens.

## Step 3: Decide the round count `R`

For a panel, pick `R` from the criteria table in `skills/board/SKILL.md`. The default is `R = 1`. Go higher only when something specific in the decision calls for it: personas that trade off against each other, an irreversible decision with second-order effects, coupled subsystems. Show the user the chosen `R` with a one-line justification when you confirm the roster.

`R` is fixed at roster confirmation, and the run never extends it on its own. If panelists still disagree after `R` rounds, the disagreement IS the signal; report it in the synthesis.

## Step 4: Compose one persona per confirmed dimension (use the template)

For each confirmed dimension, write one persona using `persona-template.md`. The structured fields are mandatory:

```
## Persona: {name — must reference a specific noun from the decision}
- **Dimension**: {the failure mode this persona guards against}
- **Lens**: {one sentence — what they look at}
- **Bias**: {one sentence — which direction they push}
- **Blind spots (by design)**: {what they refuse to opine on}
- **Output discipline**: state the position you'd defend; calibrate confidence symmetrically; name the strongest counter to your own recommendation; name fallacies in the asker's reasoning (false dichotomy, strawman, circular, appeal to authority, etc.); no padding, recap, hedges, or smoothing labels
```

**Naming test**: if the persona's descriptor could apply to a different decision without changing a word, it is too generic, so rewrite it. "Security skeptic" fails; "token-lifecycle skeptic for OAuth-A→B migration" passes.

Each persona also gets a **human first + last name** with light humour, joined to the descriptor by an em dash: `Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`. Mix cultures across the panel (Japanese, Indian, Persian, Slavic, Nordic, Latin, African, etc.); a board of five Anglo names reads like a stock photo. The descriptor carries the specificity. The name is the handle the user remembers across roster confirmation, transcripts and synthesis. Cross-model clones share the descriptor but get distinct names. The "Persona name" section of `persona-template.md` has the full rules.

**The blind-spots field is required.** A persona that opines on everything has no useful bias; it is a generalist. Each persona must explicitly refuse to weigh in on dimensions outside its lens, because that refusal is what lets synthesis weight the takes cleanly later.

Cap the panel at 5 personas. Merge or drop until you have 5 or fewer.

## Step 5: Decide model assignment

Read the model pool (parsed from `ADVISOR_MODEL`).

- **One model in the pool**: every persona uses it. Skip to step 6.
- **Several models, default behavior**: leave each persona's model unpinned; the board assigns them round-robin from the pool in roster order.
- **Pin a specific model to a specific lens** only for a real reason (e.g. "this lens benefits from gpt-5.5's deep reasoning on long causal chains"), and state the reason on the roster confirmation line.
- **Cross-model triangulation** (one lens cloned across N models): use it when one dimension is decision-critical AND the pool has models that reason differently. The clones are roster entries with the same `system` and `display_name`, distinct `id`s and different models. Whether the models agree on that lens is itself the diagnostic. It costs N roster slots, so use it deliberately.

## Step 6: Show the roster and get confirmation

Show one line per persona, in the format from `skills/board/SKILL.md` step 6:

> `<Human Name> — <descriptor> [<id>] (<model>). Covers: <dimension>. Reason for this slot: <one sentence>.`

If `R > 1`, add a one-line justification for the round count.

Wait for the user to approve, edit or veto. **This step is quick and costs no advisor calls.** Take the user's feedback seriously; it overrides your draft.

## Step 7: Run the panel

Write each persona's system prompt to its own `.sys` file and the shared user prompt to one file, both in the run's private `mktemp -d` directory. Then run one `advisor.py` call per persona, as parallel `Bash` calls in a single message (steps 7–11 of `skills/board/SKILL.md` have the exact commands). Render each reply verbatim under the advisor skill's header, one per persona: `### Advisor (<model>) — <Human Name> (<descriptor>) says:`. Write the synthesis yourself, and end with the `[board]` line.

---

## Generic persona shapes and their specific versions

Treat these as warning signs. If a persona you wrote maps 1:1 to an item in the left-hand column, you haven't done the work yet. The right-hand column shows what specificity looks like for a real decision.

| Generic shape | What's wrong | Decision-specific version (example) |
|---|---|---|
| `pragmatist` | "Get it shipped" applies to every decision and carries no decision-specific signal | `YAGNI advocate for OAuth flow swap — argue against the rewrite if the existing flow's only bug is the cookie-domain edge case` |
| `skeptic` | Devil's advocate as a job title: too vague to disagree usefully | `migration-rollback skeptic — assume the data backfill will find a corrupt row at row 1.2M; what's the recovery path?` |
| `security auditor` | Threat-models in the abstract; misses *which* threat model applies | `token-lifecycle skeptic — focus on token expiry races during cutover when old + new auth flows coexist` |
| `performance engineer` | "Make it fast", with no insight into which constant matters here | `cache-coherence specialist — if the new design adds an L2 cache layer between auth and the session store, model the staleness window and its consequences` |
| `systems architect` | Boundaries and coupling, with no reason this decision needs them named | `inter-service contract auditor — does this change require a coordinated rollout across the auth, session, and gateway services? If yes, name the order` |
| `ops engineer` | "What about ops?", with no specific operational concern | `migration-on-call ergonomics — if this fails at 3am, what's the runbook? Is the rollback one command or a multi-step dance?` |
| `domain expert` | Tautological: which domain? | `oauth2-rfc-skeptic — read the migration plan against RFC 6749 §10 and name the assumptions it violates` |
| `contrarian` | Disagreement as a job is performance, not information | `single-tenant-fan in a multi-tenant proposal — argue the simpler architecture if tenant isolation isn't actually a requirement yet` |

The pattern: generic role → **lens × decision-specific noun × failure mode**.

With human names attached, the right-hand entries become handles people remember:

- `pragmatist` → `Yui Yagni — YAGNI advocate for OAuth flow swap`
- `skeptic` → `Reza Rezervi — migration-rollback skeptic for the user_credentials backfill`
- `security auditor` → `Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration`
- `performance engineer` → `Aditi Cachari — cache-coherence specialist for the new L2 between auth and session store`

---

## What the recipe enforces

- **Specificity by construction.** Dimension extraction demands concrete failure modes, not categories, and the naming test catches any persona that slips through anyway.
- **No "default 5".** The artifact set has no archetypes, on purpose. The table above is a warning, not a menu.
- **Three points where the user can steer**: dimension confirmation (the one that matters most), roster confirmation, and review of the recommendation after synthesis. Each costs the user a moment.
- **Synthesis has one job**: combine what the personas said, weighted by the priority dimension. Composing the personas was step 4's problem, not the synthesizer's.

---

## When in doubt, read a worked example

`examples/auth-redesign.md`, `examples/perf-regression.md`, `examples/data-migration.md` and `examples/product-prioritization.md` each run end to end: the original decision prompt, the extracted dimensions with reasoning, the personas considered and rejected with rationale, the final roster, and the choice of path and round count. Read them for the *reasoning chain*, not as templates. Copy their output and you get generic panels; copy their reasoning and you get panels built for your decision.

If your decision looks like none of the four, run the recipe from step 1 anyway. The examples cover infrastructure, performance, data and product, but the recipe does not depend on them.
