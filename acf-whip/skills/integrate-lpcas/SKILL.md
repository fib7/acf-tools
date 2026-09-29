---
name: integrate-lpcas
description: LP-CAS integrator. Lands one accepted task's single-parent candidate on the live trunk by cherry-picking it, co-committing an in-tree ledger marker, gating the union tree, and CAS-updating trunk. A task counts as integrated when its marker is in the live-trunk tree, never because of a markdown field. Only /go's orchestrator invokes it; specialists never do.
---

# integrate-lpcas: Ledger-In-Tree Compare-And-Swap integrator (acf-whip 3.0.0)

Replaces `integrate-worktree`, which rebased each task onto a cached trunk snapshot. This skill folds
one accepted task onto the live trunk. The `#N` references below are failure classes of that old
engine; each step names the ones it rules out.

## The one invariant
> A task `K` is integrated **iff** `git cat-file -e <live-trunk-tip>:.acfwhip/integrated/<shard>/<K>.json`
> succeeds. Only the integrator writes that marker, and only co-committed in the same single-parent
> commit as the change, after the union gate passes, landed by compare-and-swap.

Nothing else counts as integration: not `Integrated-At`, not the folder a task sits in, not a commit
trailer. The integrator adds an `ACFW-Task:` trailer for people to read, and nothing queries it.

## Contract

```
integrate-lpcas.sh <TASK_FILE>                  # initial attempt
integrate-lpcas.sh --post-resolver <TASK_FILE>  # resume after the caller dispatched a resolver
```

Env (set by `/go`): `ACFW_TRUNK_ROOT`, `ACFW_TRUNK_BRANCH`, optional `ACFW_GATE_CMD` (union gate, CWD
= candidate worktree), optional `ACFW_PARSE_SANITY_CMD` (cheap parse/lint, run before the heavy gate).

Input: a **single-parent** candidate commit at `refs/acfw/patch/<key>` (`key` = task id = `TASK_FILE`
basename). The integrator builds it from the task's worktree branch: the tip's tree, with the fork
base (`refs/acfw/forkbase/<slug>`, else the merge-base with trunk) as its only parent. With no branch,
it uses whatever candidate the ref already holds. The integrator changes only git (the trunk ref and a
disposable integration worktree under `<worktree-dir>/_integrate/<key>`), never the `.backlog`
markdown.

## Flow
1. Observe the live trunk tip. Nothing caches it, so the base cannot go stale (#1/#9/#10).
2. O(1) already-integrated check via the marker → idempotent skip (#4).
3. Check the candidate is single-parent (else quarantine) and does not touch the ledger namespace
   (poison guard).
4. `cherry-pick --no-commit` the candidate onto a fresh worktree at the observed tip. The 3-way base
   is the candidate's own parent, never a merge-base against trunk, and nothing is rebased or
   replayed (#3). A conflict surfaces as `resolver-needed` and is never dropped silently (#17).
   Before the fold the integrator drops the candidate's `.backlog/` and `docs/cycles/` changes, since
   task state and plan cycles are never a task's deliverable. Dropping `docs/cycles/` changes prints a
   `WARN:` on stderr naming each path and the diff that recovers it from `refs/acfw/patch/<key>`, and
   a second `WARN:` when nothing but the marker is left to land. A conflict confined to `docs/cycles/`
   is not sent to a resolver, because that content is dropped anyway.
5. Co-commit the change **+** the marker in one single-parent commit → "marker ⟺ change" (#5/#7/#11/#16).
6. Run parse-sanity (a failure is a mechanism fault, #18), then the union gate on the candidate tree
   (#8). The gate runs under `pipefail`, so a pipeline cannot hide its exit code (#12). A gate
   failure is `quality-fault`.
7. CAS-land with `update-ref refs/heads/<trunk> <new> <observed>`, then resync ROOT. If trunk moved or
   was rewound in the meantime, the update is rejected as `cas-lost`: a transient mechanism fault
   that loses no data. The resync checks out only the paths this landing changed, so a
   `Worktree: none` task editing the root keeps its other files. If the landing overwrites
   uncommitted work on one of those paths, a `WARN:` on stderr gives a snapshot commit and a
   `Recover:` command that re-applies those edits 3-way.

## Outcomes (stdout `ACFW-INTEGRATE: <verdict>`) / exit codes
| exit | verdict | meaning |
|---|---|---|
| 0 | `integrated` / `already-integrated` | landed, or idempotent skip |
| 3 | `quarantine malformed-candidate` / `quarantine poison-ledger-write` | isolate this id only |
| 4 | `no-candidate` | no `refs/acfw/patch/<key>` → nothing to integrate (terminal skip) |
| 6 | `quality-fault` | union gate failed on the candidate tree (not a mechanism fault) |
| 7 | `resolver-needed` | cherry-pick conflict; worktree left mid-pick; caller dispatches resolver, re-invokes `--post-resolver` |
| 9 | `mechanism …` | resolution-syntax-broken / conflict-unresolved / worktree error (not a quality reject) |
| 11 | `cas-lost` | trunk moved/rewound under us → transient; caller re-observes (epoch check at loop) |
| 12 | `stall trunk-unobservable` · `stall backlog-strip-failed` · `stall cycles-strip-failed` · `stall root-index-desync` | trunk missing or detached; a candidate whose `.backlog/` or `docs/cycles/` edits could not be stripped (refused, never folded in); the root index could not be resynced after landing (the line carries the `git reset --mixed` to run) |

Mechanism faults (7/9/11) and quality faults (6) go to **separate** counters, so a conflict never
spends the quality reject budget (#13).

## Resolver protocol
On exit 7 the integration worktree is left mid-cherry-pick, and stdout also carries `worktree:`,
`assigned_agent:` and `conflicted_files:` lines. The caller dispatches the task's assigned agent into
that worktree to resolve the conflict markers and `git add` the files. The agent does **not** run
`cherry-pick --continue`; the integrator owns the commit. The caller then re-invokes with
`--post-resolver`. Any path still unmerged ends as `mechanism conflict-unresolved`. Otherwise the
resolved tree goes through the same sanity → gate → CAS-land path.

Tested by `acf-whip/tests/phase8-lpcas-integrate.test.sh`.
