# Worked example: perf regression triage

## 1. Original decision prompt (verbatim)

> A profile shows our search endpoint p99 went from 180ms to 720ms after the v4.2 release. The release contained 47 commits across 12 files. Our CI ran the full perf benchmark suite and it passed (no regression flagged). Should we (a) bisect commit-by-commit, (b) roll back the release and re-deploy without the suspect change, (c) push forward and instrument production for one more week before deciding, or (d) something else? Pressure: oncall is paging twice a day on this.

## 2. Extracted dimensions, with reasoning

1. **Bench-vs-prod gap** — CI bench passed, prod regressed. *Failure mode named:* if the bench setup doesn't represent prod (e.g. different cache hit rate, different query distribution, different concurrency), bisecting against the bench will find nothing or find the wrong thing.
2. **Time-to-mitigation vs time-to-root-cause** — oncall is being paged. *Failure mode named:* hunting for root cause while users suffer; or rolling back blindly and losing 47 commits' worth of unrelated fixes.
3. **Bisect cost in a 47-commit release** — bisection is `log2(47) ≈ 6` test iterations; each iteration may take 30+ minutes if it requires a deploy. *Failure mode named:* bisection takes longer than the user-pain window the team can tolerate.
4. **Production observability gap** — if CI didn't catch it, what's in prod telemetry that could narrow down which path regressed? *Failure mode named:* if we don't know which code path is slow, every option (rollback, bisect, instrument) is partly guessing.

I considered "rollback risk to other features" as a dimension but it folds into dimension 2 (time-to-mitigation vs time-to-root-cause). One persona on dimension 2 covers that tradeoff.

User-confirmed dimensions: 1, 2, 3, 4. Priority dimension: **time-to-mitigation** (oncall pain is the immediate cost).

## 3. Path decision

Four dimensions, decision is reversible (you can change strategy mid-investigation), but mid-flight switches cost time. Personas trade off (the perf engineer wants more data; oncall wants relief). → **Panel.** `R = 2` because dimensions 2 and 4 trade off (relief now vs. accuracy later) and a one-round panel might miss the rebuttals.

## 4. Personas considered AND rejected

**Dimension 1 (bench-vs-prod gap):**
- *generic perf engineer* — too broad.
- *bench/prod parity skeptic for the search benchmark suite* — focuses on the specific gap. **PICKED.**
- *workload generator critic* — narrower but overlaps with above.

**Dimension 2 (time-to-mitigation vs root cause):**
- *oncall ergonomics advocate* — focused on user pain. **PICKED.**
- *blameless-postmortem advocate* — orthogonal; this is a triage decision, not a postmortem.
- *release engineer* — too generic.

**Dimension 3 (bisect cost):**
- *bisect-cost auditor for the 47-commit release* — focused on the specific bisection economics. **PICKED.**
- *git-bisect mechanics expert* — too tactical.

**Dimension 4 (production observability):**
- *prod-telemetry skeptic for the search endpoint* — focused on what we have vs need. **PICKED.**
- *generic SRE* — fails the naming test.

## 5. Cross-model decision

Pool: `gpt-5.5,claude-opus-4-6`. Two models, four personas. Round-robin gives one wrap, no triangulation.

Considered cross-model triangulation on dimension 2 (priority) but at four personas already, cloning would push to 5 and the lens isn't one where I expect models to disagree (oncall ergonomics is about pragmatism, not deep reasoning). **Skipped triangulation.** Round-robin assignment:

- bench/prod parity skeptic → gpt-5.5
- oncall ergonomics advocate → claude-opus-4-6
- bisect-cost auditor → gpt-5.5 (wrap)
- prod-telemetry skeptic → claude-opus-4-6 (wrap)

## 6. Final roster (manifest input — abbreviated; same template as auth example)

- **bench/prod parity skeptic for the search benchmark suite** — Dimension: CI bench passing while prod regresses; Lens: every difference between bench setup and prod (cache state, query mix, concurrency, data shape); Bias: argue the bench is wrong before assuming the code is wrong; Blind spots: refuses to opine on which commit, on rollback, or on observability gaps.
- **oncall ergonomics advocate** — Dimension: minimizing user-pain window; Lens: every option's "time until pages stop"; Bias: rollback now, root-cause later, even if it loses unrelated fixes; Blind spots: refuses to opine on bench accuracy or which commit caused it.
- **bisect-cost auditor for the 47-commit release** — Dimension: bisect economics in this specific release; Lens: per-iteration cost × iterations; what subset of files most-likely contains the regression; Bias: targeted instrumentation > blind bisection if the file count can be narrowed; Blind spots: refuses to opine on rollback or oncall pain.
- **prod-telemetry skeptic for the search endpoint** — Dimension: what telemetry exists vs what's needed; Lens: every metric/trace/log in the call graph from edge to result-merger; Bias: 30 minutes of new instrumentation can save 6 hours of bisection; Blind spots: refuses to opine on rollback or bench design.

## 7. Tier choice rationale

Panel, `R = 2`, priority dimension = time-to-mitigation. The oncall ergonomics advocate will likely push hard for rollback in round 1. The bench-parity skeptic and prod-telemetry skeptic will push for diagnosis. Round 2 lets each see the others' takes — the rollback push may soften when it sees the bisect-cost numbers, and the diagnosis-first takes may soften when they see the user-pain framing. Synthesis weighted by time-to-mitigation will integrate.

---

## What this example teaches

- The "47-commit" specificity in the bisect-cost persona name matters. A "bisection expert" would give generic advice; the named persona is forced to think about *this* bisection's economics.
- Cross-model triangulation isn't always the right call. Skipped here because the priority dimension is pragmatic (oncall pain), not analytical.
- `R = 2` because the personas trade off, not because debates feel important.
