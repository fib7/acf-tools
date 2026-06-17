---
name: integrate-worktree
description: Fold a single accepted worktree branch into the local trunk. Tries fast-forward; on non-FF rebases the worktree onto trunk; on rebase conflict hands a resolver-needed signal back to the orchestrator (which dispatches the task's assigned specialist as a conflict resolver), then validates and retries. On success writes Integrated-At and removes the worktree if no more tasks share the slug. Invoked exclusively by /go's orchestrator; never by specialists.
allowed-tools:
  - Bash
  - Read
  - Task
---

# /integrate-worktree

Single-slug integration primitive. The orchestrator (`/go`, or the `whip-go` workflow)
calls this once per accepted-but-unintegrated task, sequentially, in dependency-topological
order. Specialists never call this — they never write to trunk's `.git/index`.

**The logic lives in a script.** The FF → rebase → retry ladder is implemented in
`${CLAUDE_PLUGIN_ROOT}/skills/integrate-worktree/bin/integrate-worktree.sh` (shared
lock-backoff in `skills/lib/acfw-git.sh`). This skill is a thin wrapper so the legacy and
workflow paths run the *same* implementation.

**Branches are code-only.** The rebase replays ONLY the branch's own commits onto trunk via
`rebase --onto <trunk-snapshot> <fork-base>` (the fork base is the per-slug ref
`refs/acfw/forkbase/<slug>`, recorded at worktree creation and re-pointed after each integration).
A bare whole-branch rebase would replay the stale `merge-base..HEAD` range — trunk's `.backlog`
task-transition history plus duplicated-trunk commits — which is the cause of the 2.4.1 reject-loop.
Before integrating, a guard refuses any branch carrying `.backlog/` commits not on trunk (exit 8).

## Two-call protocol (resolver dispatch is hoisted to the caller)

Bash cannot reliably spawn a subagent, so conflict resolution is split across two calls
with the caller dispatching the resolver in between:

**Call 1 — initial attempt:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/integrate-worktree/bin/integrate-worktree.sh" "$TASK_FILE"
```

- exit 0 → integrated (done).
- exit 6 → unresolvable; task already moved to `.backlog/rejected/`.
- exit 7 → **resolver-needed**: the script prints an `ACFW-INTEGRATE: resolver-needed`
  block on stdout (worktree, branch, task_file, assigned_agent, conflicting_commits,
  source_tasks, conflicted_files) and leaves the worktree mid-rebase. The caller must
  dispatch `assigned_agent` as a conflict resolver **inside that worktree** (see resolver
  contract below), then make Call 2.
- exit 8 → **contaminated**: the branch carries `.backlog/` commits not on trunk (a pre-2.4.1
  import). The script prints an `ACFW-INTEGRATE: contaminated` block and refuses (no FF/rebase).
  The caller **parks the task for an operator** (manual recovery: cherry-pick the tip code commit
  onto trunk) — do NOT retry or reject.
- exit 10 / 99 → transient; leave the task in `accepted/`, retry next iteration.

**Call 2 — after the resolver returns:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/integrate-worktree/bin/integrate-worktree.sh" --post-resolver "$TASK_FILE"
```

Validates the worktree (rebase finished? clean? no `FATAL:` token in the log?), then
retries the fast-forward. exit 0 → integrated; exit 6 → unresolvable (task moved to
`rejected/`, Rejection Count incremented).

## Resolver dispatch (the caller does this on exit 7)

Dispatch `assigned_agent` via the Task tool (legacy) or `agent({isolation:'worktree',
agentType: assigned_agent})` (workflow), passing the printed context. Rules for the resolver:

- Work ONLY inside the worktree. Never touch trunk's `.git/index`.
- Resolve each conflict preserving the intent of BOTH this task and the conflicting tasks.
- Run the project's quality gates inside the worktree; they must pass.
- When clean: `git add` resolved files, `git rebase --continue` until the rebase finishes.
- Append a transition-log line describing the resolution.
- If intent cannot be reconciled: `git rebase --abort`, append `FATAL: <reason>` to the log, return.

## Env (set by /go at startup)

- `ACFW_TRUNK_ROOT` — absolute path to the repo-root checkout (trunk).
- `ACFW_TRUNK_BRANCH` — the branch checked out at `$ACFW_TRUNK_ROOT`.

## Anti-orphan guards (preserved verbatim)

The script aborts hard (exit 10) if `refs/acfw/<slug>` does not exist after the fetch, or
if a fast-forward reports success but HEAD did not advance. Both prevent writing an
"integrated" marker on top of unchanged trunk — which would silently orphan the worktree's
code commits (the historical zsh `:r` refspec-corruption failure mode). All scripts run
under `#!/usr/bin/env bash`, so the corruption cannot recur regardless of login shell.

## Exit codes

| Exit | Cause | Orchestrator action |
|---|---|---|
| 0 | integrated successfully | continue to next task in topo order |
| 1 | task missing `Worktree:` field | surface to operator (task-engineer bug) |
| 6 | conflict unresolved | task is in `rejected/`; retry path takes over |
| 7 | resolver-needed | dispatch resolver, then call with `--post-resolver` |
| 8 | contaminated (`.backlog/` commits on branch) | park task for an operator; do NOT retry/reject |
| 10 | transient git error | leave in `accepted/`; retry next iteration |
| 99 | lock contention past backoff | transient; retry next iteration |

On success the worktree is removed (and its branch deleted) iff no pending/in-progress
tasks still share the slug.

---

**Last Updated**: 2026-05-28
