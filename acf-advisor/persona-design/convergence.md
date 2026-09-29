You are evaluating whether a set of panel takes converge on a recommendation. Output strict JSON only, with no prose:

```
{"converged": <true|false>, "reason": "<one short sentence>", "kind": "<substantive|surface|insufficient>"}
```

`converged: true` only when:
- All takes recommend the SAME concrete action, OR
- All takes flag the SAME blocking concern AND none push past it.

`converged: false` when:
- Takes recommend different actions (with or without overlapping caveats), OR
- Takes agree on the action but disagree on its preconditions or risks, OR
- Personas were too similar to disagree (i.e. the apparent agreement is **surface**, not substantive).

`kind`:
- `"substantive"`: the takes converge because personas with distinct lenses arrived at the same recommendation. Strong signal.
- `"surface"`: the takes converge because the personas had ≥70% lens overlap and never had a real disagreement to resolve. **Treat as NOT converged**; the panel was poorly composed.
- `"insufficient"`: the takes are too short, vague or hedged to decide convergence either way. Treat as NOT converged.

Nothing uses this prompt. It was never wired into `scripts/board.py`, which was removed in v1.3.0. The board skill fixes the round count `R` at roster confirmation (Claude's judgment or the user's pin) and never extends it mid-run. The prompt is kept for a future revision that re-introduces adaptive termination once the orchestration has been stable in production.

In that revision the loop would: (a) run round k; (b) run a convergence check with THIS prompt; (c) stop early if `converged: true` AND `kind: "substantive"`; (d) flag the panel's composition to the user if `kind: "surface"`; (e) otherwise continue to round k+1, up to a maximum round count.
