# Worked example: product feature prioritization (non-infrastructure)

This example exists deliberately to break the pattern of the other three (auth, perf, data — all infrastructure). The synthesis recipe must work outside the infra domain. If your decision doesn't resemble any of the four examples, the recipe still applies — start at step 1 of `DESIGN.md`.

## 1. Original decision prompt (verbatim)

> Q4 roadmap has 3 candidate features for a 6-week build window:
> (A) Inline AI summarization in the activity feed (heavy ML cost; 2 customer pilots already requested it)
> (B) Bulk-export to CSV (consistently in top-5 support requests; engineering-trivial; ~1 week)
> (C) New onboarding flow (drives trial-to-paid; data shows 40% drop-off at step 3)
> Pick one. Trade-off: revenue (C) vs. customer-relationship-strategic (A) vs. ops-cost-reduction (B).

## 2. Extracted dimensions, with reasoning

This is a product/strategy decision, not a code decision. The dimensions look different — but the recipe is the same. Each dimension is a way the decision can fail.

1. **Revenue impact in the next 1-2 quarters** — C drives trial-to-paid; A may unlock pilot deals; B reduces ops cost (indirect revenue). *Failure mode named:* picking the option with weak revenue signal in a quarter where revenue is the bonus driver.
2. **Strategic positioning vs. competitors** — A (AI features) is what competitors are shipping; not having it may cost deals beyond the 2 named pilots. *Failure mode named:* falling visibly behind on a category-defining capability.
3. **Customer-trust impact of NOT shipping** — B is a 2-year-running top-5 request; not shipping it again signals "we don't listen." *Failure mode named:* erosion of paying-customer relationships.
4. **Engineering-cost vs. value ratio** — B is 1 week, leaves 5 weeks for a smaller follow-on. C is full 6 weeks with deep UX work. A may exceed 6 weeks if ML infra needs hardening. *Failure mode named:* picking A and missing the deadline OR picking C and discovering at week 4 it's actually 8 weeks of work.
5. **Reversibility of the choice** — picking one means deferring the others to next quarter. *Failure mode named:* picking C and losing the pilot deals from A; picking A and bleeding paying-customer trust on B.

User-confirmed: 1, 2, 3, 4, 5. Priority dimension: **engineering-cost-vs-value ratio** (the user said "we've been burned by 2x slipping estimates this year").

## 3. Path decision

5 dimensions, hard-to-reverse-within-quarter, dimensions trade off (revenue vs. customer trust vs. competitive positioning), decision is high-stakes (Q4 plan). → **Panel** with 5 personas. `R = 2`: dimensions trade off AND the user has a specific concern about engineering estimates that should inform the priority weighting in synthesis.

## 4. Personas considered AND rejected

**Dim 1 (revenue):**
- *generic product manager* — fails the naming test; carries no decision-specific bias.
- *trial-to-paid revenue lens for option C* — focused on the conversion-funnel claim. **PICKED.**

**Dim 2 (strategic positioning):**
- *AI-feature competitive lens for option A* — focused on the category-defining narrative. **PICKED.**
- *generic strategist* — too vague.

**Dim 3 (customer trust of NOT shipping):**
- *paying-customer voice for the bulk-export ask* — focused on the 2-year request history. **PICKED.**
- *generic CS advocate* — fails the naming test.

**Dim 4 (engineering-cost-vs-value):**
- *engineering-estimate skeptic for Q4's three options* — focused on the "we've slipped 2x" framing. **PICKED** (priority dimension).
- *cost accountant* — too narrow.

**Dim 5 (reversibility / opportunity cost):**
- *opportunity-cost auditor for next-quarter deferrals* — focused on what each "not picked" option costs in the next quarter. **PICKED.**
- *generic strategist* — already considered for dim 2; rejected.

## 5. Cross-model decision

Pool: `gpt-5.5,claude-opus-4-6,gemini/gemini-3.1-pro-preview`.

Considered cross-model triangulation on dim 4 (priority). Engineering-estimate skepticism is the kind of lens where different models genuinely have different priors (some lean conservative, some optimistic on dev velocity). Decided **yes** — clone the engineering-estimate skeptic across two models. That pushes to 6 personas total — over the cap of 5.

Resolution: drop the strategic-positioning persona (dim 2). Reasoning: of the 5 dimensions, strategic positioning is the most speculative and least tied to the user's stated priority. The synthesis can surface "no one on the panel covered competitive positioning" as an explicit gap in the synthesis output.

This is a deliberate trade-off and surfaced to the user at roster confirmation:

> "Note: dropping the AI-feature competitive lens to fit cross-model triangulation on the priority dimension (engineering-cost-vs-value). If you want competitive coverage, override and I'll drop the cross-model clone instead."

User accepted the trade.

Final assignment (5 personas, two are same-lens different-model):
- trial-to-paid revenue lens → gpt-5.5
- paying-customer voice for bulk-export → claude-opus-4-6
- engineering-estimate skeptic [instance 1] → gpt-5.5 (priority)
- engineering-estimate skeptic [instance 2] → gemini-3.1-pro-preview (priority, triangulation)
- opportunity-cost auditor → claude-opus-4-6

## 6. Final roster (manifest input — abbreviated)

- **trial-to-paid revenue lens for option C** — Bias: argue for C if the 40% drop-off is on a step that's truly fixable in 6 weeks. Blind spots: refuses to opine on engineering cost or competitive positioning.
- **paying-customer voice for the bulk-export ask** — Bias: argue for B as the cheapest way to repair customer trust; will accept C only if revenue impact is well-quantified. Blind spots: revenue specifics, engineering risk.
- **engineering-estimate skeptic [instance 1: gpt-5.5]** — Bias: stated estimates are likely 1.5–2x optimistic; pick the option whose ESTIMATE × 2 still fits the window. Blind spots: revenue, customer trust, strategic positioning.
- **engineering-estimate skeptic [instance 2: gemini-3.1-pro-preview]** — same content, different model for triangulation on the priority dimension.
- **opportunity-cost auditor for next-quarter deferrals** — Bias: argue for the option whose deferral cost (over 1 quarter) is smallest. Blind spots: revenue mechanics, engineering risk, customer-trust specifics.

## 7. Tier choice rationale

Panel, `R = 2`, priority dimension = engineering-cost-vs-value ratio. Cross-model clone on the priority lens. Strategic-positioning dimension dropped to fit budget — surfaced as an explicit gap.

Estimated cost: 5 personas × 2 rounds + 1 synthesis = 11 calls.

---

## What this example teaches

- The recipe works for product/strategy decisions, not just technical ones. The shape of "dimensions = ways the decision can fail" generalizes.
- Cross-model triangulation may force a coverage trade-off. Make it deliberate and visible — ask the user.
- Sometimes a dimension gets dropped. Surface that gap in synthesis ("no panel coverage on X") rather than silently widening some other persona's lens to cover it.
- The priority dimension drove both persona selection AND the decision to triangulate. The user's framing ("we've been burned 2x on estimates") was load-bearing.
