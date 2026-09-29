# Worked example: perf regression triage

## 1. Original decision prompt (verbatim)

> A profile shows our search endpoint p99 went from 180ms to 720ms after the v4.2 release. The release contained 47 commits across 12 files. Our CI ran the full perf benchmark suite and it passed (no regression flagged). Should we (a) bisect commit-by-commit, (b) roll back the release and re-deploy without the suspect change, (c) push forward and instrument production for one more week before deciding, or (d) something else? Pressure: oncall is paging twice a day on this.

## 2. Extracted dimensions, with reasoning

1. **Bench-vs-prod gap.** The CI bench passed and prod regressed. *Failure mode named:* if the bench setup doesn't represent prod (e.g. different cache hit rate, different query distribution, different concurrency), bisecting against the bench will find nothing or find the wrong thing.
2. **Time-to-mitigation vs time-to-root-cause.** Oncall is being paged. *Failure mode named:* hunting for root cause while users suffer; or rolling back blindly and losing 47 commits' worth of unrelated fixes.
3. **Bisect cost in a 47-commit release.** Bisection is `log2(47) ≈ 6` test iterations, and each may take 30+ minutes if it needs a deploy. *Failure mode named:* bisection takes longer than the user-pain window the team can tolerate.
4. **Production observability gap.** If CI didn't catch it, what in prod telemetry could narrow down which path regressed? *Failure mode named:* if we don't know which code path is slow, every option (rollback, bisect, instrument) is partly guessing.

I considered "rollback risk to other features" as a dimension, but it folds into dimension 2 (time-to-mitigation vs time-to-root-cause), and one persona on dimension 2 covers that tradeoff.

User-confirmed dimensions: 1, 2, 3, 4. Priority dimension: **time-to-mitigation** (oncall pain is the immediate cost).

## 3. Path decision

Four dimensions. The decision is reversible (you can change strategy mid-investigation), but switching mid-flight costs time. The personas trade off: the perf engineer wants more data, oncall wants relief. → **Panel.** `R = 2` because dimensions 2 and 4 trade off (relief now vs. accuracy later), and a one-round panel might miss the rebuttals.

## 4. Personas considered AND rejected

**Dimension 1 (bench-vs-prod gap):**
- *generic perf engineer*: too broad.
- *bench/prod parity skeptic for the search benchmark suite*: focuses on the specific gap. **PICKED.**
- *workload generator critic*: narrower, and overlaps with the one above.

**Dimension 2 (time-to-mitigation vs root cause):**
- *oncall ergonomics advocate*: focused on user pain. **PICKED.**
- *blameless-postmortem advocate*: beside the point; this is a triage decision, not a postmortem.
- *release engineer*: too generic.

**Dimension 3 (bisect cost):**
- *bisect-cost auditor for the 47-commit release*: focused on the economics of this bisection. **PICKED.**
- *git-bisect mechanics expert*: too tactical.

**Dimension 4 (production observability):**
- *prod-telemetry skeptic for the search endpoint*: focused on what we have vs what we need. **PICKED.**
- *generic SRE*: fails the naming test.

## 5. Cross-model decision

Pool: `gpt-5.5,claude-opus-4-6`. Two models, four personas. Round-robin gives one wrap, no triangulation.

I considered cross-model triangulation on dimension 2 (the priority). Cloning would take the panel from four personas to 5, and this isn't a lens where I expect models to disagree: oncall ergonomics is about pragmatism, not deep reasoning. **Skipped triangulation.** Round-robin assignment:

- Priya Parithi — bench/prod parity skeptic → gpt-5.5
- Søren Pageløs — oncall ergonomics advocate → claude-opus-4-6
- Bohdan Bisektor — bisect-cost auditor → gpt-5.5 (wrap)
- Tomás Telémaco — prod-telemetry skeptic → claude-opus-4-6 (wrap)

## 6. Final roster (abbreviated; same template as the auth example)

- **Priya Parithi — bench/prod parity skeptic for the search benchmark suite.** Dimension: CI bench passing while prod regresses; Lens: every difference between bench setup and prod (cache state, query mix, concurrency, data shape); Bias: argue the bench is wrong before assuming the code is wrong; Blind spots: refuses to opine on which commit, on rollback, or on observability gaps.
- **Søren Pageløs — oncall ergonomics advocate.** Dimension: minimizing user-pain window; Lens: every option's "time until pages stop"; Bias: rollback now, root-cause later, even if it loses unrelated fixes; Blind spots: refuses to opine on bench accuracy or which commit caused it.
- **Bohdan Bisektor — bisect-cost auditor for the 47-commit release.** Dimension: bisect economics in this specific release; Lens: per-iteration cost × iterations; what subset of files most-likely contains the regression; Bias: targeted instrumentation > blind bisection if the file count can be narrowed; Blind spots: refuses to opine on rollback or oncall pain.
- **Tomás Telémaco — prod-telemetry skeptic for the search endpoint.** Dimension: what telemetry exists vs what's needed; Lens: every metric/trace/log in the call graph from edge to result-merger; Bias: 30 minutes of new instrumentation can save 6 hours of bisection; Blind spots: refuses to opine on rollback or bench design.

## 7. Path and round-count rationale

Panel, `R = 2`, priority dimension = time-to-mitigation. In round 1 the oncall ergonomics advocate will likely push hard for rollback, while the bench-parity and prod-telemetry skeptics push for diagnosis. Round 2 shows each of them the others' takes. The rollback push may soften once it sees the bisect-cost numbers, and the diagnosis-first takes may soften once they see the user-pain framing. The synthesis, weighted by time-to-mitigation, integrates the two sides.

---

## What this example teaches

- The "47-commit" in the bisect-cost persona's name matters. A "bisection expert" gives generic advice; the named persona has to reason about the economics of *this* bisection.
- Cross-model triangulation isn't always worth it. It was skipped here because the priority dimension is pragmatic (oncall pain), not analytical.
- `R = 2` because the personas trade off, not because debates feel important.
