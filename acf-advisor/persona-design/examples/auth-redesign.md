# Worked example: auth redesign (OAuth migration)

This file shows the **reasoning chain** behind a panel, not only the roster it produced. Read it for the *process*, not as a template. Your decision is almost certainly different, so copy the reasoning, not the personas.

---

## 1. Original decision prompt (verbatim)

> We're migrating our user-facing auth from a homegrown session-cookie system to OAuth 2.0 with refresh tokens, fronting the same internal user store. The migration will be staged: 10% of users on the new flow for two weeks, then 50%, then 100%. Both flows will be live during cutover. Should we issue OAuth tokens that look identical to old session cookies (transparent migration), or use distinct token formats (explicit migration with per-user opt-in)? Hard-to-reverse once chosen.

## 2. Extracted dimensions, with reasoning

I read the prompt twice and asked: "what are all the ways this decision can fail?"

1. **Token-shape detection during cutover.** Both flows are live, sessions can carry tokens from either, and any code that branches on token shape will misroute. *Failure mode named:* a request with a token issued by Flow A is checked by code that assumes Flow B, and either bypasses auth or rejects valid tokens.
2. **Rollback safety after partial cutover.** If we hit 50% and discover a bug, can we route everyone back to the old flow without invalidating sessions for the 50% who already migrated? *Failure mode named:* mass re-login required, user trust hit, support flood.
3. **Refresh-token handling vs old session lifetime model.** OAuth refresh tokens have different expiry/revoke semantics from the old long-lived sessions. *Failure mode named:* user sessions silently expire (or refuse to expire) in ways that don't match the old SLA.
4. **Internal-service contracts.** Every service that consumes the user store and parses session cookies has to handle both formats during cutover. *Failure mode named:* a service somewhere in the call graph hard-codes the old cookie shape and silently fails on new tokens.

I considered a fifth, "user-facing UX of the migration", but the question is about the token format, not migration UX. UX is downstream of the format decision and independent of it. **Dropped, not in scope.**

I confirmed dimensions 1–4 with the user. Priority dimension: **rollback safety** (the user said irreversibility is the main worry).

## 3. Path decision

Four distinct dimensions, decision is hard-to-reverse, dimensions can trade off (transparent format helps cutover but hurts rollback; explicit format does the inverse). → **Panel.**

`R` selection: dimensions 1 and 2 trade off directly (a transparent token format makes detection trivial and rollback hard; distinct formats make detection harder and rollback cleaner). That's a "personas trade off" signal → `R = 2`: one round of independent takes, then one where each persona sees the others' takes and can rebut.

## 4. Personas considered AND rejected

The personas I considered for each dimension, and why I picked the one I did:

**For dimension 1 (token-shape detection):**
- *generic security auditor*: too broad. It would talk about threats in the abstract and miss the cutover-specific issue.
- *token-lifecycle skeptic for OAuth-A→B migration*: focused on the concrete cutover failure mode. **PICKED.**
- *RFC 6749 §10 reader*: narrow; it would catch some issues but little else. Considered as a cross-model triangulation candidate (see step 5).

**For dimension 2 (rollback safety):**
- *generic operations engineer*: fails the naming test.
- *migration-rollback skeptic for the 50% cutover stage*: tests the specific rollback case the user is worried about. **PICKED.**
- *blue-green deployment advocate*: would push for parallel infra, but the question is about token format, not deployment topology. Out of scope.

**For dimension 3 (refresh-token semantics vs old session lifetime):**
- *session-lifetime auditor for the homegrown→OAuth model gap*: focuses on the specific semantics gap. **PICKED.**
- *OAuth library maintainer*: too deep in implementation detail.

**For dimension 4 (internal-service contracts):**
- *generic systems architect*: too broad.
- *inter-service token-parser auditor for the user-store call graph*: focuses on this specific call graph. **PICKED.**

## 5. Cross-model decision

The user's `ADVISOR_MODEL` had `gpt-5.5,claude-opus-4-6,gemini/gemini-3.1-pro-preview`. Three models in pool, four personas. Round-robin would assign one persona per model with one wrap.

I considered cross-model triangulation on dimension 2 (rollback safety), since the user named it as the priority. Cloning that lens across two models costs an extra slot and brings the panel to 5 personas. Decided **yes**: the priority dimension is exactly where cross-model agreement is worth the most.

Final assignment:
- Tomoe Tokunaga — token-lifecycle skeptic → gpt-5.5 (round-robin)
- Ravi Rückbau — migration-rollback skeptic [instance 1] → claude-opus-4-6 (priority dimension; first triangulation)
- Anika Anulova — migration-rollback skeptic [instance 2] → gemini-3.1-pro-preview (priority dimension; second triangulation; distinct human name from instance 1)
- Selma Sessione — session-lifetime auditor → gpt-5.5 (round-robin wrap)
- Kwame Konnektor — inter-service token-parser auditor → claude-opus-4-6 (round-robin wrap)

## 6. Final roster

```
## Persona: Tomoe Tokunaga — token-lifecycle skeptic for OAuth-A→B migration
- **Dimension**: token-shape detection during 10%/50%/100% cutover when both flows issue tokens that flow through the same gateway
- **Lens**: every code path that parses or branches on token shape; for each, "what if it was issued by the OTHER flow?"
- **Bias**: explicit token-version field + dual-issuer trust; refuse to rely on implicit detection
- **Blind spots (by design)**: refuses to opine on rollback strategy (covered by rollback persona), refresh-token semantics (covered by session-lifetime persona), or service-graph propagation (covered by inter-service persona)
- **Output discipline**: direct, name what's wrong, no flattery, no filler

## Persona: Ravi Rückbau — migration-rollback skeptic for the 50% cutover stage [instance 1: gpt-5.5 perspective]
- **Dimension**: rollback safety if a bug surfaces at 50%; can we route everyone back to old flow without mass re-login?
- **Lens**: the specific 50% rollback scenario; for transparent vs distinct token formats, walk through the unwinding
- **Bias**: distinct token formats with explicit per-user opt-out, even at higher migration cost; minimize the rollback blast radius
- **Blind spots (by design)**: refuses to opine on cutover detection mechanics or service-graph contract issues
- **Output discipline**: direct, name what's wrong, no flattery, no filler

## Persona: Anika Anulova — migration-rollback skeptic for the 50% cutover stage [instance 2: claude perspective]
[same body as instance 1; different model assigned at runtime for cross-model triangulation on the priority dimension. Distinct human name so the user can tell whose take is whose in the transcript.]

## Persona: Selma Sessione — session-lifetime auditor for the homegrown→OAuth model gap
- **Dimension**: refresh-token vs old long-lived session expiry/revoke semantics gap
- **Lens**: every place where the old code assumes session-cookie lifetime semantics; check whether OAuth refresh-token semantics produce the same observable user behavior
- **Bias**: short OAuth access-token lifetimes + reliable refresh; explicit warning to users at first new-flow login about the change
- **Blind spots (by design)**: refuses to opine on token format choice or rollback strategy
- **Output discipline**: direct, name what's wrong, no flattery, no filler

## Persona: Kwame Konnektor — inter-service token-parser auditor for the user-store call graph
- **Dimension**: services downstream of auth that hard-code the old cookie shape and would silently fail on new tokens
- **Lens**: trace every consumer of the session-cookie format; identify each parsing site
- **Bias**: gateway-level token normalization (translate new → old shape at the edge for the cutover window); minimize per-service migration burden
- **Blind spots (by design)**: refuses to opine on auth flow or rollback design
- **Output discipline**: direct, name what's wrong, no flattery, no filler
```

## 7. Path and round-count rationale

Panel. Five personas (one per dimension, plus the cross-model clone), `R = 2` (dimensions 1 and 2 trade off), priority dimension = rollback safety, cross-model triangulation on that dimension. Estimated cost: 5 personas × 2 rounds = 10 advisor calls; the synthesis is the orchestrator's own turn.

The user might have argued for a single round at lower cost. The recipe still recommended `R=2` because dimensions 1 and 2 trade off directly. Round 1 produces independent positions. Round 2 lets the rollback skeptics see the token-lifecycle take and rebut it (or update) on the cost they're imposing, and lets the token-lifecycle skeptic see the rollback constraint and adjust.

Had the round-1 takes clearly converged on "explicit format with token-version field", with no real disagreement on cost, the user could have overridden `R` down to 1. `R=2` was a judgment made up front, not something the run decided.

---

## What this example teaches

- Dimension extraction mattered most. Four dimensions, each with a concrete failure mode, shaped everything after them.
- Generic role names ("security auditor", "operations engineer") came up for every dimension and were rejected every time. Every persona in the final roster is specific to this decision.
- Cross-model triangulation costs slots; spend them on the priority dimension.
- `R > 1` came from a real trade-off between dimensions, not from a default "let's debate."
- The **blind spots** fields matter: they are what lets synthesis weight the takes cleanly by the priority dimension.
