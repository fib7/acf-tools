---
name: clean-checkout-before-task
description: Mandatory first step for any agent that mutates code. Resolves the task's Worktree slug, lazy-creates an isolated git worktree on a derived branch, validates the branch, hydrates the dev env from .worktreeinclude, stashes unrelated changes, and logs the clean-checkout token. Eliminates index.lock contention and cross-task commit bundling.
allowed-tools:
  - Bash
  - Read
---

# /clean-checkout-before-task

Concurrency primitive for ACF specialist agents. Every implementer and reviewer invokes this before any edit, commit, or state move.

**The logic lives in a script.** All steps are implemented in
`${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/clean-checkout.sh`
(shared lock-backoff in `skills/lib/acfw-git.sh`). This skill is a thin wrapper so the
legacy `/go` path and the `whip-go` workflow run the *same* implementation. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/clean-checkout.sh" "$TASK_FILE"
```

`$TASK_FILE` is the absolute path to the task markdown (in `.backlog/pending/` or
`in-progress/`). On success the script prints the worktree path on **stdout** (all git
chatter goes to stderr); `cd` into it and do all subsequent work there.

The lock is git itself: `git worktree add -b worktree/<slug>` fails when the branch is
already checked out elsewhere — that failure is the mutual-exclusion primitive. No lock
files, daemons, or schedulers.

## What the script does

1. Resolve `Worktree:` slug from the task front-matter (missing → exit 1 for code tasks).
2. Resolve trunk from `$ACFW_TRUNK_ROOT` / `$ACFW_TRUNK_BRANCH` (set by `/go`), else `git rev-parse`.
3. Lazy-create `.worktree/<slug>` on `worktree/<slug>` from the local trunk, recording the fork
   base (`refs/acfw/forkbase/<slug>` = the trunk SHA the branch's code sits on).
4. **Hydrate** the worktree from `.worktreeinclude` (Step 3.5; copies/symlinks untracked
   dev files like `.env`, `node_modules` so the worktree runs a full sandbox). No-op when
   the manifest is absent. See `hydrate-worktree.sh`.
5. Validate the worktree is on `worktree/<slug>` (drift → exit 3).
6. Ensure the per-slug fork-base ref exists (backfill via `merge-base` for a pre-3.0.0 worktree).
   **No rebase, no trunk-snapshot, no re-align** (3.0.0 / LP-CAS): the branch simply carries the
   specialist's code on top of its fork-base, and `integrate-lpcas` applies that change onto the
   **live** trunk at integration time. The cached `refs/acfw/trunk-snapshot` and the snapshot rebase —
   the keystone defect that froze every worktree's base on a rewritten trunk — are gone by construction.
7. Stash unrelated working-tree changes.
8. Append the OK token; print the worktree path.

## Standalone re-hydration

Hydration also runs on its own against an existing worktree — e.g. one created by a bare `git worktree add`, or one whose `.env`/`node_modules` you want refreshed after editing `.worktreeinclude`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/hydrate-worktree.sh" <REPO_ROOT> <WORKTREE_PATH>
```

Idempotent and safe to re-run: existing targets are skipped, and a missing manifest is a no-op.

## When to invoke

| Caller | When |
|---|---|
| Implementer specialist | Step 0, before reading task implementation requirements |
| quality-reviewer | Before moving the task to `.backlog/in-review/` (idempotent: re-logs a fresh token) |
| task-engineer | **MUST NOT invoke.** It operates only on `.backlog/` at the repo root on trunk. |
| research-agent, lean-architect, retro, precommit | Only if the task mutates code outside `docs/`. |

## Exit codes

| Exit | Cause | Caller action |
|---|---|---|
| 0 | success (worktree path on stdout) | `cd` into it; proceed |
| 1 | `Worktree:` field missing on a code task | Send back to task-engineer; do not pick up |
| 2 | branch in use elsewhere (lock held) | Defer; try a different task |
| 3 | worktree on the wrong branch | Stop; manual intervention |
| 5 | trunk branch not resolvable (detached HEAD) | Operator must check out a branch at root |
| 6 | the durable clean-checkout token could not be written to a non-`files` task store | Transient; orchestrator retries next iteration |
| 99 | lock contention persisted past backoff (>7s) | Transient; orchestrator retries next iteration |

## Token format (for greppers and quality-reviewer)

```
| <UTC ts> | clean-checkout | ok | clean-checkout-before-task | <slug> | <branch> |
```

The agent field is the literal `clean-checkout-before-task` (the script hard-codes it —
it is **not** derived from `$0`, which would drift to `clean-checkout.sh`). Quality-reviewer
rejects any task in `.backlog/in-review/` whose transition log lacks at least one
`clean-checkout | ok` line.

## Why this works

Each worktree has its own `.git/index` (no shared lock; no pre-commit stash bundling).
Two agents claiming the same slug: first wins, second sees exit 2 and defers. Cross-worktree
file conflicts surface at integration time (`integrate-lpcas`, as a resolver — never a silent
drop). Stale edits are stashed.

---

**Last Updated**: 2026-05-28
