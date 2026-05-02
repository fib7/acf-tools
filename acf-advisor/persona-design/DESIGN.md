# Persona synthesis recipe

This file is the durable artifact. It defines a *process* for composing a panel hypertailored to a specific decision — not a catalog of pre-made personas. Personas are synthesized per call, named for the decision's specific nouns, and each cover exactly one dimension of correctness.

If you find yourself reaching for "the usual five" (pragmatist, skeptic, security, perf, architect), you have skipped the recipe. Start over from step 1.

---

## Step 1 — Extract decision dimensions (visible to user, BEFORE personas)

Read the question + context. List the dimensions of correctness this specific decision has. A dimension is a way the decision can fail. Concrete, decision-specific, with the failure mode named:

> NOT: "security"
> YES: "token expiry race during cutover when both old and new auth flows are live"

> NOT: "performance"
> YES: "GC pressure if the per-request allocation count rises >2x at p99"

> NOT: "operability"
> YES: "rollback safety if the migration discovers a corrupted row partway through"

Output the dimension list to the user as a numbered markdown list, with the failure mode named per dimension. **Wait for confirmation.** Ask: *"Which of these dimensions is most important to you? Synthesis will weight it."* The answer becomes `priority_dimension` in the manifest.

This step is the load-bearing one. The roster confirmation later is too late — by then the personas are composed and the user is rubber-stamping. The dimension list is where the real decision happens; surface it.

## Step 2 — Decide the path (single advisor vs panel)

| Dimensions identified | Path |
|---|---|
| 1 dominant dimension; rest are minor | Single specialized advisor (route to `advisor` skill with a synthesized persona via `--system-file`) |
| ≥ 2 distinct dimensions | Panel |
| Trivial / lookup-style question | Default advisor (existing skill, no persona synthesis needed) |

Single advisor is the cheapest non-trivial path — same cost as default but with a sharp lens.

## Step 3 — Decide the round count `R`

For the panel path, pick `R` from the criteria table in `skills/board/SKILL.md`. Default `R = 1`. Increase only when a specific signal in the decision context warrants it (personas trade off against each other, irreversible decision with second-order effects, coupled subsystems). Show the user the chosen `R` with a one-line justification at the roster confirmation step.

`R` is fixed at manifest-build time — no autonomous mid-run extension. If panelists disagree after `R` rounds, that disagreement IS the signal; surface it via synthesis.

## Step 4 — Compose one persona per confirmed dimension (use the template)

For each dimension on the confirmed list, write one persona using `persona-template.md`. Mandatory structured fields:

```
## Persona: {name — must reference a specific noun from the decision}
- **Dimension**: {the failure mode this persona guards against}
- **Lens**: {one sentence — what they look at}
- **Bias**: {one sentence — which direction they push}
- **Blind spots (by design)**: {what they refuse to opine on}
- **Output discipline**: direct, name what's wrong, no flattery, no filler
```

**Naming test**: if the persona name could apply to a different decision without changing any words, it is too generic. Rewrite. ("security skeptic" fails the test; "token-lifecycle skeptic for OAuth-A→B migration" passes.)

**Blind-spots field is non-negotiable.** A persona that opines on everything has no useful bias; it's just a generalist. Each persona must explicitly refuse to weigh in on dimensions outside its lens — that's what makes synthesis cleanly weight the takes later.

Cap at 5 personas. Merge or drop until ≤5.

## Step 5 — Decide model assignment

Read `available_models` (parsed from `ADVISOR_MODEL`).

- **Single model in pool** → all personas share it. Skip to step 6.
- **Multiple models in pool, default behavior** → leave each persona's `model: null`; board.py round-robins them across the pool in manifest order.
- **Pin a specific model to a specific lens** when there's a real reason (e.g. "this lens benefits from gpt-5.5's deep reasoning on long causal chains"). State the reason in the roster confirmation line.
- **Cross-model triangulation** (clone one lens across N models) when one specific dimension is decision-critical AND the pool has genuinely different reasoners. Two manifest entries with identical `system` + `display_name`, distinct `id`s, different `model`s. Cross-model agreement-or-disagreement on that lens is itself the diagnostic. Costs N roster slots — use deliberately.

## Step 6 — Show the roster, get confirmation

For each persona, one line:

> `<name>` [`<id>`] (`<model>`) — covers: `<dimension>`. Reason for this slot: `<one sentence>`.

If `R > 1`: a one-line justification for the chosen round count.

Wait for the user to approve, edit, or veto. **This step is fast and free of advisor cost.** Treat user feedback as load-bearing.

## Step 7 — Build the manifest, run the panel

Construct the JSON manifest matching `scripts/board.py`'s schema. Pipe to `board.py`. Render the output verbatim under headers (preserving the per-persona "Advisor (`<model>`) — `<name>` says:" pattern from the existing advisor skill — same idiom, multiplied). End with the synthesis block. Surface the `[board] aggregate:` cost line.

---

## Persona shapes that are too generic — and the specific versions they should become

These are warning signs. If your synthesized persona maps 1:1 to one of the left-hand items, you have not done the work yet. The right-hand column shows what specificity looks like for a real decision.

| Generic shape | What's wrong | Decision-specific version (example) |
|---|---|---|
| `pragmatist` | "Get it shipped" applies to every decision; carries no decision-specific signal | `YAGNI advocate for OAuth flow swap — argue against the rewrite if the existing flow's only bug is the cookie-domain edge case` |
| `skeptic` | Devil's-advocate-as-job-title — too vague to disagree usefully | `migration-rollback skeptic — assume the data backfill will find a corrupt row at row 1.2M; what's the recovery path?` |
| `security auditor` | Threat-models in the abstract; misses *which* threat model applies | `token-lifecycle skeptic — focus on token expiry races during cutover when old + new auth flows coexist` |
| `performance engineer` | "Make it fast" — no insight into which constant matters here | `cache-coherence specialist — if the new design adds an L2 cache layer between auth and the session store, model the staleness window and its consequences` |
| `systems architect` | Boundaries-and-coupling without a reason this decision needs them named | `inter-service contract auditor — does this change require a coordinated rollout across the auth, session, and gateway services? If yes, name the order` |
| `ops engineer` | "What about ops?" — no specific operational concern | `migration-on-call ergonomics — if this fails at 3am, what's the runbook? Is the rollback one command or a multi-step dance?` |
| `domain expert` | Tautological — what domain? | `oauth2-rfc-skeptic — read the migration plan against RFC 6749 §10 and name the assumptions it violates` |
| `contrarian` | Disagreement-as-a-job is performative, not informative | `single-tenant-fan in a multi-tenant proposal — argue the simpler architecture if tenant isolation isn't actually a requirement yet` |

The transformation pattern: generic role → **lens × decision-specific noun × failure mode**.

---

## What this recipe enforces

- **Decision-specificity by construction**: the dimension extraction step demands concrete failure modes, not abstract categories. The naming test on personas catches anything that slips through.
- **No "default 5"**: archetypes are absent from the artifact set on purpose. The list above is a warning, not a menu.
- **The user has visible levers at three points**: dimension confirmation (most important), roster confirmation, and post-synthesis recommendation review. Each lever is cheap to operate.
- **The synthesis call has a clean job**: integrate weighted by `priority_dimension`. It is not synthesizing personas; it is synthesizing *takes*. Two different problems.

---

## When in doubt: walk through a worked example

`examples/auth-redesign.md`, `examples/perf-regression.md`, `examples/data-migration.md`, and `examples/product-prioritization.md` show end-to-end synthesis: original decision prompt → extracted dimensions with reasoning → personas considered AND rejected with rationale → final structured roster → tier-of-path choice. Read these for the *reasoning chain*, not as templates to copy. Pattern-matching the output produces generic panels; pattern-matching the reasoning produces hypertailored ones.

If a new decision shape arrives that doesn't resemble any of the four examples, run the recipe from step 1 anyway. The examples cover infrastructure, performance, data, and product. Together they should generalize — but the recipe stands without them.
