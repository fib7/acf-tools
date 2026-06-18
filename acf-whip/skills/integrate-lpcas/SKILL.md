---
name: integrate-lpcas
description: LP-CAS integrator — land one accepted task's single-parent candidate onto the live trunk by cherry-picking it, co-committing an in-tree ledger marker, gating the union tree, and CAS-updating trunk. Integration truth is the marker's presence in the live-trunk tree, never a markdown field. Invoked exclusively by /go's orchestrator; never by specialists.
---

# integrate-lpcas — Ledger-In-Tree Compare-And-Swap integrator (acf-whip 3.0.0)

Replaces `integrate-worktree` (the rebase-into-cached-snapshot fold). Folds ONE accepted task onto
the live trunk so the production failure classes cannot arise by construction.

## The one invariant
> A task `K` is integrated **iff** `git cat-file -e <live-trunk-tip>:.acfwhip/integrated/<shard>/<K>.json`
> succeeds. Only the integrator writes that marker, and only co-committed in the same single-parent
> commit as the change, after the union gate passes, landed by compare-and-swap.

Nothing else asserts integration — not `Integrated-At`, not folder location, not a commit trailer
(a `ACFW-Task:` trailer is added for humans but never queried).

## Contract

```
integrate-lpcas.sh <TASK_FILE>                  # initial attempt
integrate-lpcas.sh --post-resolver <TASK_FILE>  # resume after the caller dispatched a resolver
```

Env (set by `/go`): `ACFW_TRUNK_ROOT`, `ACFW_TRUNK_BRANCH`, optional `ACFW_GATE_CMD` (union gate, CWD
= candidate worktree), optional `ACFW_PARSE_SANITY_CMD` (cheap parse/lint, run before the heavy gate).

Input: the worker publishes its change as a **single-parent** commit at `refs/acfw/patch/<key>`
(`key` = task id = `TASK_FILE` basename). The integrator mutates only git (trunk ref + a disposable
integration worktree under `<worktree-dir>/_integrate/<key>`) — never the `.backlog` markdown.

## Flow
1. Observe the live trunk tip (never cached → no stale base, #1/#9/#10).
2. O(1) already-integrated check via the marker → idempotent skip (#4).
3. Validate the candidate is single-parent (else quarantine) and does not touch the ledger namespace
   (poison guard).
4. `cherry-pick --no-commit` the candidate onto a fresh worktree at the observed tip — base is the
   candidate's own parent, **no rebase, no merge-base vs trunk, no replay** (#3). Conflict → surface
   `resolver-needed` (never a silent drop, #17).
5. Co-commit the change **+** the marker in one single-parent commit → "marker ⟺ change" (#5/#7/#11/#16).
6. Parse-sanity (mechanism if broken, #18) then the union gate on the candidate tree (#8), via direct
   exec with `pipefail` so a gate exit can't be masked (#12). Fail → quality-fault.
7. CAS-land: `update-ref refs/heads/<trunk> <new> <observed>` then resync ROOT. Rejection (external
   move/rewind) → `cas-lost` (mechanism, transient) — never data loss.

## Outcomes (stdout `ACFW-INTEGRATE: <verdict>`) / exit codes
| exit | verdict | meaning |
|---|---|---|
| 0 | `integrated` / `already-integrated` | landed, or idempotent skip |
| 3 | `quarantine malformed-candidate` / `quarantine poison-ledger-write` | isolate this id only |
| 4 | `no-candidate` | no `refs/acfw/patch/<key>` → nothing to integrate (terminal skip) |
| 6 | `quality-fault` | union gate failed on the candidate tree (NOT mechanism) |
| 7 | `resolver-needed` | cherry-pick conflict; worktree left mid-pick; caller dispatches resolver, re-invokes `--post-resolver` |
| 9 | `mechanism …` | resolution-syntax-broken / conflict-unresolved / worktree error (NOT a quality reject) |
| 11 | `cas-lost` | trunk moved/rewound under us → transient; caller re-observes (epoch check at loop) |
| 12 | `stall trunk-unobservable` | trunk missing/detached |

Mechanism faults (7/9/11) and quality faults (6) route to **different** counters — a conflict never
consumes the quality reject budget (#13).

## Resolver protocol
On exit 7 the integration worktree is left mid-cherry-pick. The caller dispatches the task's assigned
agent into that worktree to resolve conflict markers and `git add` the files (it does **not** run
`cherry-pick --continue` — the integrator owns the commit), then re-invokes with `--post-resolver`.
Remaining unmerged paths ⇒ `mechanism conflict-unresolved`; otherwise the resolved tree proceeds
through the same sanity → gate → CAS-land path.

Tested by `acf-whip/tests/phase8-lpcas-integrate.test.sh`.
