# Worked example: data migration cutover

## 1. Original decision prompt (verbatim)

> Migrating user_profiles (50M rows) from MySQL to Postgres. Strategy under debate: (A) dual-write for 6 weeks, then read-cutover, then turn off MySQL; (B) one-shot offline migration during a 4-hour maintenance window. We have a hard SLA of "no maintenance > 2h" in our enterprise contract. Risk tolerance: low — corrupted profile data is a customer-trust hit we cannot recover from.

## 2. Extracted dimensions, with reasoning

1. **SLA compliance for the maintenance window** — Strategy B is 4h; SLA caps at 2h. *Failure mode named:* contract violation; legal/sales escalation.
2. **Dual-write consistency for 6 weeks** — Strategy A keeps both DBs synced for an extended window. *Failure mode named:* one-side write succeeds, other fails, divergence accumulates silently.
3. **Read-cutover correctness when both DBs are live** — Strategy A's cutover moment. *Failure mode named:* a read returns stale data because the dual-write was async or failed for that row.
4. **Rollback path if corruption is detected mid-migration** — both strategies. *Failure mode named:* discovering corruption at hour 3 of 4 (Strategy B) or week 4 of 6 (Strategy A) and not having a clean rollback.
5. **Schema-difference handling** — MySQL and Postgres differ on null semantics, timestamp precision, charset. *Failure mode named:* silent data shape changes that violate downstream invariants.

User-confirmed all 5. Priority: **rollback path** ("low risk tolerance, customer-trust hit unrecoverable").

## 3. Path decision

5 dimensions, hard-to-reverse, dimensions trade off (Strategy A is better for SLA but worse for consistency window; Strategy B inverse). → **Panel** with 5 personas (cap). `R = 3`: dimensions trade off AND the decision is genuinely irreversible AND second-order effects across dimensions are likely (e.g. how rollback design interacts with schema-difference handling).

## 4. Personas considered AND rejected

**Dim 1 (SLA):**
- *contract-compliance auditor for the 2h maintenance SLA* — focused. **PICKED.**
- *legal advisor* — out of scope for engineering panel.

**Dim 2 (dual-write consistency for 6 weeks):**
- *dual-write divergence skeptic for the 6-week window* — focused. **PICKED.**
- *eventual-consistency theorist* — too abstract.

**Dim 3 (read-cutover correctness):**
- *cutover-moment correctness auditor* — focused. **PICKED.**
- *read-after-write tester* — narrower; subsumed by above.

**Dim 4 (rollback path):**
- *migration-rollback skeptic for both strategies' failure modes* — focused. **PICKED** (priority dimension).
- *backup/restore mechanic* — too tactical.

**Dim 5 (schema differences):**
- *MySQL→Postgres schema-difference auditor for user_profiles* — focused. **PICKED.**
- *generic db schema reviewer* — fails naming test.

## 5. Cross-model decision

Pool: `gpt-5.5,claude-opus-4-6,gemini/gemini-3.1-pro-preview`. 3 models, 5 personas. Round-robin gives `[m0, m1, m2, m0, m1]`.

Considered cloning the rollback persona (priority dimension) across all 3 models for triangulation — but that would push to 7 personas, over the cap. Instead: clone rollback persona across 2 models (gpt-5.5 and claude-opus-4-6 — different reasoning styles), drop the schema-difference persona to 4 total, and accept that schema differences will be covered by the dual-write divergence skeptic's blind-spot border.

Wait — that's a recipe violation. Each persona must cover one dimension. Dropping the schema-difference persona means dimension 5 is uncovered. Reverting: keep all 5 distinct personas, no cross-model clone. Round-robin assignment as above.

This rejection itself is informative — it shows the cap-at-5 + cross-model-clone trade-off, and how to back out when they conflict.

Final assignment:
- Hina Slasaki — contract-compliance auditor → gpt-5.5
- Dragan Driftović — dual-write divergence skeptic → claude-opus-4-6
- Camille Coupure — cutover-moment correctness auditor → gemini-3.1-pro-preview
- Reza Rezervi — migration-rollback skeptic → gpt-5.5 (wrap)
- Sanjay Schemavarna — MySQL→Postgres schema-difference auditor → claude-opus-4-6 (wrap)

## 6. Final roster (manifest input — abbreviated)

Each persona follows `persona-template.md` with: dimension, lens, bias, ≥2 named blind spots, output discipline.

- **Hina Slasaki — contract-compliance auditor for the 2h maintenance SLA** — Bias: any plan that requires >2h is a non-starter; argue for Strategy A or a sub-2h variant of B. Blind spots: refuses to opine on consistency or rollback mechanics.
- **Dragan Driftović — dual-write divergence skeptic for the 6-week window** — Bias: argue for compensating reads (read-from-old, async write to new) over true dual-write to limit divergence surface. Blind spots: SLA, schema mapping.
- **Camille Coupure — cutover-moment correctness auditor** — Bias: dark-launch reads from new for 1 week before flipping; refuse to flip until a delta-check job reports zero diff. Blind spots: SLA, rollback.
- **Reza Rezervi — migration-rollback skeptic** — Bias: every step must be reversible WITHOUT data loss; if a step isn't, design a forward-recovery plan instead. Blind spots: SLA, schema mapping.
- **Sanjay Schemavarna — MySQL→Postgres schema-difference auditor for user_profiles** — Bias: explicit casting + integrity checks at the boundary; refuse implicit conversions for nullables, timestamps, and charsets. Blind spots: SLA, dual-write mechanics.

## 7. Tier choice rationale

Panel, `R = 3`, priority dimension = rollback. Three rounds because: (1) dimensions trade off in non-obvious ways (Strategy A's better SLA story interacts with its longer divergence window in ways one round can't explore); (2) the rollback persona is the priority lens, and other personas need a chance to react to its objections (round 2) and integrate (round 3); (3) decision is genuinely irreversible.

Estimated cost: 5 personas × 3 rounds + 1 synthesis = 16 calls. Justified by the irreversibility + customer-trust framing.

---

## What this example teaches

- The cap-at-5 persona limit can conflict with cross-model triangulation desire. When that conflict happens, prefer dimension coverage over triangulation.
- `R = 3` is rare. It's appropriate here because the decision is irreversible AND the dimensions interact in non-obvious ways.
- The dimension extraction picked up dimension 5 (schema differences) that the user didn't explicitly mention. The recipe is supposed to surface dimensions the user didn't think of; this example shows that.
