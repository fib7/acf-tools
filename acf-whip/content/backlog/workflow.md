# Task Workflow

## State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

## Execution paths: workflow-native (default) and legacy fallback

`/task` and `/go` run as **dynamic workflows** (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) when the host supports them. The loop, the slug partition, the dependency gate, the topological integration order, and the stall/terminal bookkeeping run inside a deterministic JavaScript script; **intermediate state lives in script variables, not Claude's context**, so context stays flat across iterations no matter how large the backlog. Every filesystem/git action is delegated to a narrow agent: a read-only scanner (`scan-backlog.sh`), a single sequential writer (`apply-transition.sh`), parallel specialists/reviewers isolated by worktree slug, and a sequential integrator (`integrate-worktree.sh`) with conflict-resolver dispatch hoisted into the script.

When dynamic workflows are unavailable (disabled, or older Claude Code), both commands fall back to the **legacy single-context loop** documented below — byte-compatible behavior over the same `.backlog/` state machine, but the loop lives in (and grows) Claude's context. The capability check is simply whether the `Workflow` tool is present; no plugin code special-cases it.

Both paths enforce the same invariants: the doctor integrity gate, the single-writer rule, worktree-slug partitioning, and the dependency gate.

## State Transition Authority

All `.backlog/` state moves happen at the **repo root** (`$ACFW_TRUNK_ROOT`) on the **trunk branch**. The orchestrator (`/go`) is the single writer of `.backlog/` files; specialists and quality-reviewer signal their decisions via the `ACFW-RESULT` marker in their Task() return, and the orchestrator performs the corresponding move + commit on trunk.

| From | To | WHO performs the move (at root, on trunk) |
|------|----|-------------------------------------------|
| N/A | pending | task-engineer (creation, at root, never in a worktree) |
| pending | in-progress | `/go` orchestrator (pre-move + commit before dispatching specialist) |
| in-progress | completed | `/go` orchestrator on specialist's `transition: completed` signal |
| in-progress | blocked | `/go` orchestrator on specialist's `transition: blocked` signal |
| completed | in-review | `/go` orchestrator (pre-move before dispatching quality-reviewer) |
| in-review | accepted | `/go` orchestrator on reviewer's `transition: accepted` signal |
| in-review | rejected | `/go` orchestrator on reviewer's `transition: rejected` signal (also increments Rejection Count) |
| rejected | pending | task-engineer (retry, at root); max 5 attempts |
| blocked | pending | task-engineer (unblock when deps resolved, at root) |
| rejected | blocked | task-engineer (redesign at >5 rejections, at root) |

**task-engineer never enters a worktree.** It never invokes `clean-checkout-before-task`. All its operations are on `.backlog/` at the repo root, committed to the trunk branch.

**Specialists** still do code work inside `.worktree/<slug>` on `worktree/<slug>` — that is unchanged. Their commits on the worktree branch contain code only; they do NOT move task files and do NOT commit `.backlog/` changes on the worktree branch.

**Retry limit**: Rejected tasks can return to in-progress up to 5 times. After 5th rejection, task-engineer redesigns (rejected → blocked) at root.

**File move + transition log update = ATOMIC** (same commit on trunk).
**Timestamp command**: `date +"%Y-%m-%d %H:%M:%S"` (never placeholder).

## Git lock-file policy

Every git command issued by acf-whip skills (orchestrator commits, worktree creation, FF merges, rebases, fetches, stashes) goes through a backoff helper. If `.git/index.lock` is held by another process, the helper sleeps and retries (1s → 2s → 4s, three attempts total, ~7s worst case). **The lock file is never removed.** After exhausting retries the operation surfaces exit code 99; the orchestrator treats it as transient and retries the affected operation next iteration.

## Concurrency Model

**Parallel across worktrees, sequential within a worktree.** Every code-mutating task declares two front-matter fields, set by `task-engineer` at decomposition time:

- `Worktree: <slug>` (kebab-case identifier; required for code-mutating tasks; `none` only for research/docs-only tasks). A missing slug on an **active** code task is self-healed: the doctor derives one from the task id and writes it in (`--fix`) rather than hard-failing. A missing slug on an **accepted** (terminal) task is advisory only.
- `PR Group: <slug>` (defaults to the same slug; sibling tasks ship together)
- `Touches Globs: <comma-separated globs>` (the files the task modifies, or `none`; the doctor WARNs when two different-slug pending tasks declare overlapping globs — a mis-partition signal)

Slug enforcement is layered: schema-required at decomposition (the workflow planner cannot omit it), a JS validation gate (kebab-case, never equal to the task id, acyclic deps, unique ids) before any file is written, and at dispatch the doctor self-heals a missing slug on an active task (derives + writes it).

**Parallelism is the default.** The slug is the partition: the orchestrator (`/go`) groups pending tasks by `Worktree:` and dispatches at most one specialist per worktree-group — tasks with different slugs run **in parallel**, tasks sharing a slug run strictly sequentially. Decomposition is therefore biased toward maximum parallelism: every independent file surface gets its own slug (concurrent), a slug is shared only when tasks write the **same** files, and a dependency is declared only when a task genuinely consumes another's output. Over-sharing slugs and adding unnecessary dependencies are the two ways to needlessly serialize work — both are avoided by default.

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

**Terminal in default mode**: an accepted task is terminal once nothing remains to fold into trunk — it carries `Integrated-At:`, **or** it is non-code (`Worktree: none`), **or** it has no `worktree/<slug>` branch (a historical/pre-2.0.0 task already merged the old way). Branchless historical accepted tasks are never enqueued for integration (integrate-worktree exits 4, "nothing to fold"), so a lived-in backlog reaches 100% instead of looping on phantom branches.

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
   - **Cross-slug dep**: dep's commits must already be on the local trunk. It blocks only while genuinely pending integration — `accepted/`, a live `worktree/<slug>` branch, and no `Integrated-At:` yet. A non-empty `Integrated-At:` satisfies it; so does a **branchless historical/pre-2.0.0** accepted dep (no worktree branch = already on trunk the old way). A non-code (`none`) dep is satisfied on acceptance.
   - In override (PR) mode, where `Integrated-At:` is never written, acceptance is sufficient for cross-slug deps; the operator is responsible for ordering.

## Evidence Requirements

Every completed task MUST provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA on `worktree/<slug>` (not on the trunk branch)
4. Transition log with timestamps including at least one `clean-checkout: ok` line

In default (auto-merge) mode, every accepted task MUST additionally have:
5. `Integrated-At: <sha>` populated by the orchestrator's `integrate-worktree` step, plus a transition-log line `accepted | accepted | integrate-worktree | <slug> | <sha> | integrated`.

## Backlog integrity (`/whip-doctor`)

`doctor.sh` is the integrity battery. It runs at three points: as a **hard gate** at `/go` startup (it applies the REPAIRABLE class with `--fix`, then re-scans and refuses to dispatch if any FATAL remains), as a **per-iteration recheck** inside the loop (a mid-run FATAL — e.g. a cycle introduced by a retry — aborts before the next dispatch), and at **`/task` create-time**. `/whip-doctor [--fix]` runs it on demand. Findings are `SEVERITY|CODE|TASK_ID|DETAIL` lines, then a grouped `BREAKDOWN|<SEV>|code=count,…` line per severity (so callers summarize instead of dumping every line), then `SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false`.

**Severity is scoped to the dispatch path.** A task in `accepted/` is terminal/out-of-scope, so its structural defects are **advisory (WARN), never blocking** — a pre-2.0.0 backlog of historical accepted tasks (missing slugs, stale `Status:`, even dangling/cyclic deps among themselves) does not abort the gate. FATAL is reserved for **active** tasks (pending/in-progress/completed/in-review): status-vs-folder mismatch, unknown Assigned Agent, dangling/cyclic deps, a cross-slug dependent dispatched before its dep is on trunk (branch-aware: a branchless historical dep counts as satisfied), worktree on the wrong branch, detached HEAD at trunk. REPAIRABLE (auto-fixed by `--fix`): **a missing worktree slug on an active code task (derived from the id and written in)**, stray `Integrated-At` on a non-accepted task, out-of-range Rejection Count, a task present in two folders, an orphaned `.worktree/<slug>`.

## Worktree environment hydration (`.worktreeinclude`)

A committed root manifest lists the git-ignored files a fresh `.worktree/<slug>` needs to run a full dev/test sandbox (`.env`, local config, `node_modules`, `.venv`). `clean-checkout-before-task` calls `hydrate-worktree.sh` right after creating a worktree. Lines are glob-capable; default action is **copy**, with `link:`, `copy:`, and `secret:` (copy + `0600`) prefixes. Secret-safety is allowlist-only: nothing is materialized unless listed, a denylist (`.env*`, `*.pem`, `*.key`, `id_*`, `credentials*`, `*.p12`, anything under `.git/`) is refused for symlink and forced to copy, every entry must already be git-ignored (`git check-ignore`), and a tracked path is a hard error — so hydration can never stage a secret.

## In-progress timeout (operator-configurable)

`.backlog/.acfw-config` sets `ACFW_INPROGRESS_TIMEOUT_HOURS` (default **8**; env var overrides). The doctor WARNs on in-progress tasks older than the threshold. `whip-init` scaffolds the config.

## Run & resume model

git plus `.backlog/` are the only durable state — **re-running `/go` is the resume**. A fresh run re-scans from disk and reconstructs the identical plan; the only loss across a Claude Code restart is the in-session agent cache and any in-flight worktree edit, which surfaces as a stale in-progress task that clean-checkout's stash and the timeout recover. The workflow path also writes a gitignored `.backlog/.acfw-run.json` heartbeat each iteration for observability; the design does not depend on it.

---

**Last Updated**: 2026-05-28
