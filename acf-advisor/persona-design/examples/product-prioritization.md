# Worked example: product feature prioritization (non-infrastructure)

The other three examples (auth, perf, data) are all infrastructure. This one is a product decision, there to show that the recipe works outside infra. If your decision resembles none of the four, the recipe still applies: start at step 1 of `DESIGN.md`.

## 1. Original decision prompt (verbatim)

> Q4 roadmap has 3 candidate features for a 6-week build window:
> (A) Inline AI summarization in the activity feed (heavy ML cost; 2 customer pilots already requested it)
> (B) Bulk-export to CSV (consistently in top-5 support requests; engineering-trivial; ~1 week)
> (C) New onboarding flow (drives trial-to-paid; data shows 40% drop-off at step 3)
> Pick one. Trade-off: revenue (C) vs. customer-relationship-strategic (A) vs. ops-cost-reduction (B).

## 2. Extracted dimensions, with reasoning

This is a product/strategy decision, not a code decision. The dimensions look different, but the recipe is the same: each dimension is a way the decision can fail.

1. **Revenue impact in the next 1-2 quarters.** C drives trial-to-paid, A may close the pilot deals, B reduces ops cost (indirect revenue). *Failure mode named:* picking the option with weak revenue signal in a quarter where revenue is the bonus driver.
2. **Strategic positioning vs. competitors.** A (AI features) is what competitors are shipping; not having it may cost deals beyond the 2 named pilots. *Failure mode named:* falling visibly behind on a category-defining capability.
3. **Customer-trust impact of NOT shipping.** B has been a top-5 request for 2 years; not shipping it again signals "we don't listen." *Failure mode named:* erosion of paying-customer relationships.
4. **Engineering-cost vs. value ratio.** B takes 1 week and leaves 5 for a smaller follow-on. C takes the full 6 weeks, with deep UX work. A may run past 6 weeks if the ML infra needs hardening. *Failure mode named:* picking A and missing the deadline OR picking C and discovering at week 4 it's actually 8 weeks of work.
5. **Reversibility of the choice.** Picking one defers the others to next quarter. *Failure mode named:* picking C and losing the pilot deals from A; picking A and bleeding paying-customer trust on B.

User-confirmed: 1, 2, 3, 4, 5. Priority dimension: **engineering-cost-vs-value ratio** (the user said "we've been burned by 2x slipping estimates this year").

## 3. Path decision

5 dimensions, hard to reverse within the quarter, dimensions that trade off (revenue vs. customer trust vs. competitive positioning), and high stakes (the Q4 plan). → **Panel** with 5 personas. `R = 2`: the dimensions trade off AND the user has a specific worry about engineering estimates that should shape the priority weighting in synthesis.

## 4. Personas considered AND rejected

**Dim 1 (revenue):**
- *generic product manager*: fails the naming test and carries no decision-specific bias.
- *trial-to-paid revenue lens for option C*: focused on the conversion-funnel claim. **PICKED.**

**Dim 2 (strategic positioning):**
- *AI-feature competitive lens for option A*: focused on the category-defining narrative. **PICKED.**
- *generic strategist*: too vague.

**Dim 3 (customer trust of NOT shipping):**
- *paying-customer voice for the bulk-export ask*: focused on the 2-year request history. **PICKED.**
- *generic CS advocate*: fails the naming test.

**Dim 4 (engineering-cost-vs-value):**
- *engineering-estimate skeptic for Q4's three options*: focused on the "we've slipped 2x" framing. **PICKED** (priority dimension).
- *cost accountant*: too narrow.

**Dim 5 (reversibility / opportunity cost):**
- *opportunity-cost auditor for next-quarter deferrals*: focused on what each option left out costs in the next quarter. **PICKED.**
- *generic strategist*: already considered and rejected for dim 2.

## 5. Cross-model decision

Pool: `gpt-5.5,claude-opus-4-6,gemini/gemini-3.1-pro-preview`.

I considered cross-model triangulation on dim 4, the priority. Estimate skepticism is a lens where models have different priors (some lean conservative on dev velocity, some optimistic). Decided **yes**: clone the engineering-estimate skeptic across two models. That makes 6 personas, over the cap of 5.

Resolution: drop the strategic-positioning persona (dim 2). Of the 5 dimensions, it is the most speculative and the least tied to the user's stated priority. The synthesis can name "no one on the panel covered competitive positioning" as an explicit gap.

The trade-off was deliberate, and the user saw it at roster confirmation:

> "Note: dropping the AI-feature competitive lens to fit cross-model triangulation on the priority dimension (engineering-cost-vs-value). If you want competitive coverage, override and I'll drop the cross-model clone instead."

User accepted the trade.

Final assignment (5 personas, two are same-lens different-model):
- Tomislav Trijalić — trial-to-paid revenue lens → gpt-5.5
- Beatriz Bulkova — paying-customer voice for bulk-export → claude-opus-4-6
- Estela Slipova — engineering-estimate skeptic [instance 1] → gpt-5.5 (priority)
- Nikolai Estimov — engineering-estimate skeptic [instance 2] → gemini-3.1-pro-preview (priority, triangulation; distinct human name from instance 1)
- Olamide Defernot — opportunity-cost auditor → claude-opus-4-6

## 6. Final roster (abbreviated)

- **Tomislav Trijalić — trial-to-paid revenue lens for option C.** Bias: argue for C if the 40% drop-off is on a step that can be fixed in 6 weeks. Blind spots: refuses to opine on engineering cost or competitive positioning.
- **Beatriz Bulkova — paying-customer voice for the bulk-export ask.** Bias: argue for B as the cheapest way to repair customer trust; will accept C only if revenue impact is well-quantified. Blind spots: revenue specifics, engineering risk.
- **Estela Slipova — engineering-estimate skeptic [instance 1: gpt-5.5].** Bias: stated estimates are likely 1.5–2x optimistic; pick the option whose ESTIMATE × 2 still fits the window. Blind spots: revenue, customer trust, strategic positioning.
- **Nikolai Estimov — engineering-estimate skeptic [instance 2: gemini-3.1-pro-preview].** Same body as instance 1, on a different model for triangulation on the priority dimension, with a distinct human name so the user can tell whose take is whose in the transcript.
- **Olamide Defernot — opportunity-cost auditor for next-quarter deferrals.** Bias: argue for the option whose deferral cost (over 1 quarter) is smallest. Blind spots: revenue mechanics, engineering risk, customer-trust specifics.

## 7. Path and round-count rationale

Panel, `R = 2`, priority dimension = engineering-cost-vs-value ratio, with a cross-model clone on the priority lens. The strategic-positioning dimension was dropped to fit the 5-persona cap and is reported as an explicit gap.

Estimated cost: 5 personas × 2 rounds = 10 advisor calls; the synthesis is the orchestrator's own turn.

---

## What this example teaches

- The recipe works for product and strategy decisions, not only technical ones, because "dimensions = ways the decision can fail" carries over.
- Cross-model triangulation can force a coverage trade-off. Make it deliberate and visible, and ask the user.
- Sometimes a dimension gets dropped. Name the gap in the synthesis ("no panel coverage on X") instead of quietly widening another persona's lens to cover it.
- The priority dimension drove both the persona selection AND the decision to triangulate. The user's own words ("we've been burned 2x on estimates") shaped the panel.
