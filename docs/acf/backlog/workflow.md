# Task Workflow

## State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

## State Transition Authority

| From | To | WHO moves file & updates transition log |
|------|----|-----------------------------------------|
| N/A | pending | task-engineer |
| pending | in-progress | Implementer agent |
| in-progress | blocked | Implementer agent |
| blocked | in-progress | Implementer agent |
| in-progress | completed | Implementer agent |
| completed | in-review | quality-reviewer |
| in-review | accepted | quality-reviewer |
| in-review | rejected | quality-reviewer |
| rejected | in-progress | Implementer agent (retry, max 5 attempts) |

**Retry limit**: Rejected tasks can return to in-progress up to 5 times. After 5th rejection, task-engineer must redesign or archive.

**File move + transition log update = ATOMIC** (same commit).
**Timestamp command**: `date +"%Y-%m-%d %H:%M:%S"` (never placeholder).

## Concurrency Model

**Parallel across worktrees, sequential within a worktree.** Every code-mutating task declares two front-matter fields, set by `task-engineer` at decomposition time:

- `Worktree: <slug>` (kebab-case identifier; required for code-mutating tasks)
- `PR Group: <slug>` (defaults to the same slug; sibling tasks ship together)

The orchestrator (`/go`) groups pending tasks by `Worktree:` and dispatches at most one specialist per worktree-group. Tasks sharing a slug execute strictly sequentially. Tasks with different slugs execute in parallel.

The lock is git itself: `git worktree add <repo>/.worktree/<slug> -b worktree/<slug>` fails when the branch is already checked out elsewhere. No custom lock files, daemons, or schedulers.

**Ownership scope.** acf-whip owns exactly one branch namespace — `worktree/<slug>` — and only ever creates, inspects, or removes worktrees on it. The doctor's orphan reaper and wrong-branch check are scoped to that namespace, so the `/go` bootstrap `--fix` never touches a worktree you keep in the same repo for your own research/benchmarking, even one parked under `.worktree/`. The directory and branch prefix are configurable per project via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR`, `ACFW_BRANCH_PREFIX`); change them only on a fresh backlog.

### Step 0: clean-checkout-before-task

Every implementer specialist and `quality-reviewer` invokes the `clean-checkout-before-task` skill as Step 0, before reading the task body. The skill:

1. Resolves `<slug>` from the task front-matter.
2. Lazy-creates `.worktree/<slug>` on branch `worktree/<slug>`.
3. Validates the branch matches the derivation rule.
4. Stashes unrelated working-tree changes.
5. Logs `clean-checkout: ok` to the task transition log.

Quality-reviewer rejects any task in `.backlog/in-review/` whose transition log lacks the `clean-checkout: ok` token.

All subsequent state moves, edits, and commits happen inside the worktree on `worktree/<slug>`. **No commits land on `main` from a specialist.** Integration of `worktree/<slug>` into `main` (PR via `gh pr create` or fast-forward merge) is project-decided and outside this contract.

## Priority Levels

| Priority | SLA (deadline) | Cycle Time Target (stretch goal) |
|----------|----------------|-----------------------------------|
| blocker | 1h | 30min |
| critical | 4h | 2h |
| high | 24h | 6h |
| medium | 1 week | 2 days |
| low | none | none |

Priority orders within a worktree partition. It does not authorize parallelism across the partition; the partition rule does.

## Execution Rules

1. Group pending tasks by `Worktree:`.
2. For each group with no in-progress task, dispatch the highest-priority pending task. Dispatch happens in parallel across groups.
3. Within a group, the next task waits until the current in-progress task terminates (accepted, blocked, or rejected).
4. blocker tasks within a group still take precedence; they just do not break the per-group serialization.

## Evidence Requirements

Every completed task MUST provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA on `worktree/<slug>` (not `main`)
4. Transition log with timestamps including at least one `clean-checkout: ok` line

---

**Last Updated**: 2026-04-28
