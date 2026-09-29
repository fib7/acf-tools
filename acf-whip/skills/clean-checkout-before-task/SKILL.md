---
name: clean-checkout-before-task
description: Mandatory first step for any agent that mutates code. Resolves the task's Worktree slug, lazy-creates an isolated git worktree on a derived branch, validates the branch, hydrates the dev env from .worktreeinclude, stashes unrelated changes, and logs the clean-checkout token. Gives each task its own index and branch, so tasks do not bundle each other's commits and rarely contend on index.lock.
allowed-tools:
  - Bash
  - Read
---

# /clean-checkout-before-task

Concurrency primitive for ACF specialist agents. Every implementer and reviewer runs it before any edit, commit, or state move.

**All the logic lives in one script**,
`${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/clean-checkout.sh`, with its lock
backoff in the shared `skills/lib/acfw-git.sh`. This skill wraps it so the legacy `/go` path and the
`whip-go` workflow run the same code. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/clean-checkout.sh" "$TASK_FILE"
```

`$TASK_FILE` is the absolute path to the task markdown: the live file in `.backlog/pending/` or
`in-progress/` on the `files` store, or the spec `acfw-store read --materialize` wrote on any other
store. On success the script prints the worktree path on **stdout** and sends all git output to
stderr. `cd` into that path and do all further work there.

Git is the lock. `git worktree add -b worktree/<slug>` fails when the branch already exists, a
re-attach fails when the branch is already checked out in another worktree, and that failure is the
mutual exclusion. There is no lock file, daemon or scheduler.

## What the script does

1. Resolve the `Worktree:` slug from the task front-matter (missing → exit 1 for code tasks). Only
   the first `Worktree:` line counts, so a store comment appended to a materialized spec that
   repeats the field cannot change the slug.
2. Resolve trunk from `$ACFW_TRUNK_ROOT` / `$ACFW_TRUNK_BRANCH` (set by `/go`), else from git.
3. Lazy-create `.worktree/<slug>` on `worktree/<slug>` from the local trunk, and record the fork
   base (`refs/acfw/forkbase/<slug>` = the trunk SHA the branch's code sits on). If the branch
   already exists but its directory is gone (a reaped worktree, or one an older release made), the
   script re-attaches the branch as it is, with its commits, instead of failing. It never resets or
   rebases it, and it does not record today's trunk tip as its fork base: step 6 backfills
   `merge-base` when no fork base is recorded.
4. **Hydrate** a newly created worktree from `.worktreeinclude` (the script's Step 3.5). This
   copies or symlinks untracked dev files such as `.env` and `node_modules`, so the worktree can run
   the full dev environment. No manifest, no hydration. See `hydrate-worktree.sh`.
5. Check the worktree is on `worktree/<slug>` (any other branch → exit 3).
6. Make sure the per-slug fork-base ref exists, backfilling it with `merge-base` for a worktree
   created before 3.0.0. Nothing is rebased, snapshotted or re-aligned (LP-CAS, 3.0.0). The branch
   holds the specialist's commits on top of the fork base, and `integrate-lpcas` applies that change
   to the **live** trunk at integration time. Before 3.0.0 the branch was rebased onto a cached
   `refs/acfw/trunk-snapshot`, and on a rewritten trunk that snapshot stopped advancing and froze
   every worktree's base. The snapshot and the rebase are both gone.
7. Stash unrelated working-tree changes.
8. Append the OK token and print the worktree path.

## Standalone re-hydration

You can run hydration by itself against an existing worktree: one made by a bare
`git worktree add`, or one whose `.env`/`node_modules` you want refreshed after editing
`.worktreeinclude`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/clean-checkout-before-task/bin/hydrate-worktree.sh" <REPO_ROOT> <WORKTREE_PATH>
```

It is safe to re-run. Targets that already exist are skipped, and a missing manifest does nothing.

## When to invoke

| Caller | When |
|---|---|
| Implementer specialist | Step 0, before reading task implementation requirements |
| quality-reviewer | Before moving the task to `.backlog/in-review/` (idempotent: re-logs a fresh token) |
| task-engineer | **Never.** It works only on `.backlog/` at the repo root on trunk. |
| research-agent, lean-architect, retro, precommit | Only if the task mutates code outside `docs/`. |

## Exit codes

| Exit | Cause | Caller action |
|---|---|---|
| 0 | success (worktree path on stdout) | `cd` into it; proceed |
| 1 | `Worktree:` field missing on a code task | Send back to task-engineer; do not pick up |
| 2 | branch in use elsewhere (lock held); stderr names the worktree it is checked out in | Defer; try a different task. If that worktree's directory is gone, `git worktree prune` clears it |
| 3 | worktree on the wrong branch | Stop; manual intervention |
| 5 | trunk branch not resolvable (detached HEAD) | Operator must check out a branch at root |
| 6 | the durable clean-checkout token could not be written to a non-`files` task store | Transient; orchestrator retries next iteration |
| 99 | lock contention persisted through the backoff (three attempts) | Transient; orchestrator retries next iteration |

## Token format (for greppers and quality-reviewer)

```
| <UTC ts> | clean-checkout | ok | clean-checkout-before-task | <slug> | <branch> |
```

The agent field is the literal `clean-checkout-before-task`. The script hard-codes it rather than
deriving it from its own path, which would give `clean-checkout.sh`. Quality-reviewer rejects any
task in `.backlog/in-review/` whose transition log lacks at least one `clean-checkout | ok` line.

On a non-`files` store the script also writes the token to the task store, because the next
`read --materialize` rewrites the spec it appended to. Exit 6 means that write failed.

## Why this works

Each worktree has its own index, so agents do not share one `index.lock` and a pre-commit stash
cannot bundle another task's changes. When two agents race to create the same slug's worktree, the
first wins and the second gets exit 2 and defers. That exclusion covers creation only. Against a
worktree that already exists the script passes the branch check and stashes whatever is uncommitted
there, including the work of an agent still writing in it. When two worktrees change the same
lines, the conflict surfaces at integration: `integrate-lpcas` hands it to a resolver instead of
dropping it silently.

---

**Last Updated**: 2026-09-29
