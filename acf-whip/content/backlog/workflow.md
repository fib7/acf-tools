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

### Step 0: clean-checkout-before-task

Every implementer specialist and `quality-reviewer` invokes the `clean-checkout-before-task` skill as Step 0, before reading the task body. The skill:

1. Resolves `<slug>` from the task front-matter.
2. Lazy-creates `.worktree/<slug>` on branch `worktree/<slug>`.
3. Validates the branch matches the derivation rule.
4. Stashes unrelated working-tree changes.
5. Logs `clean-checkout: ok` to the task transition log.

Quality-reviewer rejects any task in `.backlog/in-review/` whose transition log lacks the `clean-checkout: ok` token.

All subsequent state moves, edits, and commits happen inside the worktree on `worktree/<slug>`. **No commits land on the trunk branch from a specialist.**

### Integration

**Default**: at the end of each `/go` iteration, the orchestrator folds every newly-accepted worktree into the branch checked out at the repo root (the local trunk) via the `integrate-worktree` skill. Fast-forward where possible; otherwise the worktree is rebased onto trunk and conflicts are resolved by the task's `assigned_agent` working inside the worktree with full context of the conflicting commits and their source tasks. On successful merge, the task's `Integrated-At:` field is populated with the new trunk SHA.

**Override**: if the project's `CLAUDE.md` (or any other persistent agent instructions) directs a different integration strategy — for example "open a PR per `PR Group:` via `gh pr create` instead of merging locally" — `/go` follows those instructions and skips auto-integration, per Claude's instruction-priority hierarchy. In that mode the operator is responsible for integration; `Integrated-At:` stays empty and the loop's terminal check falls back to `accepted ∪ blocked`.

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
2. For each group with no in-progress task, dispatch the highest-priority pending task whose dependencies are satisfied (see rule 5). Dispatch happens in parallel across groups.
3. Within a group, the next task waits until the current in-progress task terminates (accepted, blocked, or rejected).
4. Blocker tasks within a group still take precedence; they just do not break the per-group serialization.
5. **Dependency gating**: a task may dispatch only from a codebase that already contains all its dependencies.
   - **Same-slug dep** (dep's `Worktree:` equals this task's `Worktree:`): satisfied as soon as the dep is in `.backlog/accepted/`. The dep's commits already live on the shared `worktree/<slug>` branch.
   - **Cross-slug dep**: dep must be `accepted/` AND have a non-empty `Integrated-At:` (i.e. merged into the local trunk). Acceptance alone is insufficient because the dependent's worktree only sees cross-slug commits after `clean-checkout-before-task` Step 5 fast-forwards from the now-advanced trunk.
   - In override (PR) mode, where `Integrated-At:` is never written, acceptance is sufficient for cross-slug deps; the operator is responsible for ordering.

## Evidence Requirements

Every completed task MUST provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA on `worktree/<slug>` (not on the trunk branch)
4. Transition log with timestamps including at least one `clean-checkout: ok` line

In default (auto-merge) mode, every accepted task MUST additionally have:
5. `Integrated-At: <sha>` populated by the orchestrator's `integrate-worktree` step, plus a transition-log line `accepted | accepted | integrate-worktree | <slug> | <sha> | integrated`.

---

**Last Updated**: 2026-04-28
