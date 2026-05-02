You are evaluating whether a set of panel takes converge on a recommendation. Output strict JSON only — no prose:

```
{"converged": <true|false>, "reason": "<one short sentence>", "kind": "<substantive|surface|insufficient>"}
```

`converged: true` only when:
- All takes recommend the SAME concrete action OR
- All takes flag the SAME blocking concern AND none push past it.

`converged: false` when:
- Takes recommend different actions (with or without overlapping caveats), OR
- Takes agree on the action but disagree on its preconditions or risks, OR
- Personas were too similar to disagree (i.e. the apparent agreement is **surface**, not substantive).

`kind`:
- `"substantive"` — takes converge because the personas, despite distinct lenses, arrived at the same recommendation. Strong signal.
- `"surface"` — takes converge because the personas had ≥70% lens overlap and never had a real disagreement to resolve. **Treat as NOT converged**; the panel was poorly composed.
- `"insufficient"` — takes are too short, vague, or hedged to determine convergence either way. Treat as NOT converged.

This file is shipped but **not currently used** by `scripts/board.py`. Round count `R` is fixed at manifest-build time in v1.1.0 (Claude's deliberative judgment OR user pin), with no autonomous mid-run extension. This convergence prompt is reserved for a future revision that re-introduces adaptive termination after the orchestration contract has been stable in production.

When that future revision lands, the loop will: (a) run round k, (b) run a convergence-check call using THIS prompt, (c) terminate early if `converged: true` AND `kind: "substantive"`, (d) flag the panel composition to the user if `kind: "surface"`, (e) continue to round k+1 otherwise — capped at `BOARD_MAX_ROUNDS`.
