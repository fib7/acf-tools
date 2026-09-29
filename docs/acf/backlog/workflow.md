<!-- acf-whip-artifact: content/backlog/workflow.md v3.5.0 -->
# Task Workflow

## Pluggable task store (3.1.0)

Task state lives in a **task store** behind an executable adapter contract (plugin
`adapters/CONTRACT.md`). The dispatcher `skills/lib/bin/acfw-store` resolves the active backend
(`ACFW_STORE` env → `ACFW_STORE=` in `.acfwhip/config` or the legacy `.backlog/.acfw-config` →
`files`), finds its adapter (project-local `.acfwhip/adapters/` → shipped `adapters/<backend>/` →
`$PATH`), and routes every read and write through it: `snapshot` (the scan), `transition` (the
single-writer primitive), `read`/`create`/`update-field`, `doctor`.

| Backend | State lives in | Notes |
|---|---|---|
| `files` (default) | `.backlog/<state>/*.md` on trunk | reference backend; everything below describes it literally |
| `beads` | `bd` issue tracker (`.beads/`, embedded Dolt) | custom statuses mirror the whip states; deps native |
| `multica` | multica server (Postgres, via CLI) | `whip_state` metadata is canonical; the audit trail is the task document's `## Transition Log` |
| `linear` | Linear workspace (GraphQL API) | `whip_*` state in per-issue attachment metadata; native status is a display projection; comments are the audit trail |

These invariants hold on every backend: the whip state machine below, the single sequential writer,
worktree-slug partitioning, the dependency gate, idempotent transitions, and an **LP-CAS integration
ledger that stays in git** (`.acfwhip/integrated/` on trunk; integration truth never moves into a
store backend). On a non-files backend, dispatched agents read a spec **materialized** from the store
(`acfw-store read --materialize`) instead of a live `.backlog/` path, and send evidence back through
`acfw-store comment`. The `.backlog/` paths in the rest of this document describe the files backend.
The legacy (non-workflow) `/go` loop runs on files only.

## State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

## Execution paths: workflow-native (default) and legacy fallback

When the host supports dynamic workflows, `/task` and `/go` run as workflows
(`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`). A deterministic JavaScript
script holds the loop, the slug partition, the dependency gate, the topological integration order,
and the stall and terminal bookkeeping. **Intermediate state lives in script variables, not in
Claude's context**, which stays flat across iterations however large the backlog. Every filesystem or git action goes to a narrow agent: a read-only scanner
(`scan-backlog.sh`), a single sequential writer (`apply-transition.sh`), parallel specialists and
reviewers isolated by worktree slug, and a sequential LP-CAS integrator (`integrate-lpcas.sh`), with
conflict-resolver dispatch hoisted into the script.

**Bounded working-set snapshot.** The workflow JS has no filesystem access, so on each iteration a
scanner agent runs the store walk and hands its JSON back. That hop is the constraint. The payload
must fit what a model will echo reliably, and a short echo is still valid JSON: it looks exactly like
a smaller board, and the scheduler would plan over a backlog that does not exist. Three mechanisms
bound the payload, and a fourth proves it arrived whole.

*Collapse.* `--digest` emits full per-task objects only for tasks the scheduler can act on: every
non-accepted active task, every accepted task still waiting for integration, and every accepted task
that something **depends on** (so dependency resolution never sees a gap). Terminal and historical
accepted tasks collapse into aggregate counts. Since 3.4.0 this works on **every** backend, not just
`files`: the dispatcher applies the same three-way split for any adapter that does not implement it.

*Narrowing.* A scoped run (`/go <ids>`, or a bare `/go` running your focus) passes `--only`, and the
store emits only the closure of those tasks: the seeds plus every dependency that is not
accepted-terminal. A five-task run relays five records whatever the size of the board.

*Quiet doctor.* The doctor's `--quiet` mode limits the integrity report to FATAL findings plus the
grouped breakdown, so hundreds of historical advisories never pass through the gate agent.

*Proof.* Every snapshot opens with a `relay` header stating how many entries it holds and the byte
sum of their stems. The consumer recomputes both and refuses a mismatch: it retries, then stops as
`relay-truncated`. It never reports the named ids as nonexistent, which is what a silently short echo
used to look like. The doctor's findings ride the same hop, so the `fatal=N` in `SUMMARY` is checked
against the lines relayed. A dropped FATAL would silently un-hold the task it names.

Completion is measured over `counts.total` (active folders only) against
`runtimeTerminalDefault`/`runtimeTerminalOverride`, which mirror the JS terminal rule exactly. A
snapshot missing those counts aborts loudly (version skew) rather than stalling in silence.

When dynamic workflows are unavailable (disabled, or an older Claude Code), both commands fall back
to the **legacy single-context loop** in the `/go` and `/task` skills. It runs the same `.backlog/`
state machine, but the loop lives in Claude's context and grows it, and its integrity gate is
stricter: it refuses on any FATAL instead of holding out one task. The presence of
the `Workflow` tool picks the path; no plugin code checks for it separately.

Both paths enforce the same invariants: the doctor integrity gate, the single-writer rule,
worktree-slug partitioning, and the dependency gate.

## State Transition Authority

All `.backlog/` state moves happen at the **repo root** (`$ACFW_TRUNK_ROOT`) on the **trunk branch**.
The orchestrator (`/go`) is the single writer of `.backlog/` files. Specialists and quality-reviewer
report their decisions through the `ACFW-RESULT` marker in their Task() return, and the orchestrator
performs the matching move and commit on trunk.

| From | To | Who performs the move (at root, on trunk) |
|------|----|-------------------------------------------|
| N/A | pending | task-engineer (creation, at root, never in a worktree) |
| pending | in-progress | `/go` orchestrator (pre-move + commit before dispatching specialist) |
| in-progress | completed | `/go` orchestrator on specialist's `transition: completed` signal |
| in-progress | blocked | `/go` orchestrator on specialist's `transition: blocked` signal (increments `Block-Count`, the per-task loop-breaker) |
| completed | in-review | `/go` orchestrator (pre-move before dispatching quality-reviewer) |
| in-review | accepted | `/go` orchestrator on reviewer's `transition: accepted` signal |
| in-review | rejected | `/go` orchestrator on reviewer's `transition: rejected` signal (also increments Rejection Count) |
| rejected | pending | `/go` orchestrator (workflow path) on retry, up to the orchestrator's cap (`MAX_REJECT_RETRY`, currently 3); task-engineer at root on the legacy markdown loop |
| blocked | pending | `/go` orchestrator when deps resolve (gated on `Rejection Count` < cap and `Block-Count` < cap), or task-engineer (unblock, at root) |
| rejected | blocked | `/go` orchestrator at the cap, parking the task for task-engineer to redesign; task-engineer at root on the legacy loop |

**task-engineer never enters a worktree.** It never invokes `clean-checkout-before-task`; all its work
is on `.backlog/` at the repo root, committed to the trunk branch.

**Specialists** do their code work inside `.worktree/<slug>` on `worktree/<slug>`. Their commits there
contain code only: they do not move task files and do not commit `.backlog/` changes on the worktree
branch.

**Retry limit**: a rejected task goes back to pending until it reaches the orchestrator's retry cap
(`MAX_REJECT_RETRY`, currently **3**, settable per run with `maxReject`). At the cap `/go` moves it to
blocked for task-engineer to redesign, and the unblock pass will not lift it again. That number is
where automation stops. A review that reports `faultClass: mechanism` (a broken environment, a lost
clean-checkout token) does not count against it.

**The file move, the Status rewrite and the transition-log row land in one commit on trunk.** As it
moves the file, the single writer rewrites `- **Status**:` to the destination folder. The folder is
the source of truth and Status always follows it, so a transition cannot leave Status stale. (A stale
Status used to raise a `status-folder-mismatch` FATAL that aborted `/go` at its first transition.)
**Timestamp command**: `date +"%Y-%m-%d %H:%M:%S"` (never a placeholder).
**Transition rows are spliced into the `## Transition Log` table, which is capped** (shared
`append_log_row`). A task file stays well-formed and bounded however many transitions it goes
through, and no row dangles after the last heading.

## Git lock-file policy

Git commands in acf-whip's scripts go through a backoff helper (`git_with_lock_backoff`). If another
process holds `.git/index.lock`, the helper sleeps and retries, doubling the wait from 1s, for three
attempts in all. **It never removes the lock file.** When the retries run out the operation exits 99;
the orchestrator treats that as transient and retries the operation on the next iteration.

## Concurrency Model

**Parallel across worktrees, sequential within a worktree.** Every code-mutating task declares three
front-matter fields, which `task-engineer` sets at decomposition time:

- `Worktree: <slug>`: a kebab-case identifier, required for code-mutating tasks; `none` only for
  research or docs-only tasks. On an **active** code task the doctor fills in a missing slug: it
  derives one from the task id and writes it in (`--fix`) instead of failing hard. On an **accepted**
  (terminal) task a missing slug is advisory only.
- `PR Group: <slug>` (defaults to the same slug; sibling tasks ship together)
- `Touches Globs: <comma-separated globs>`: the files the task modifies, or `none`. The doctor WARNs
  when two pending tasks on different slugs declare overlapping globs, a sign the partition is wrong.

Slugs are enforced in three layers. At decomposition the schema requires one, so the workflow planner
cannot omit it. Before any file is written, a JS validation gate checks that the slug is kebab-case
and never equal to the task id, that deps are acyclic, and that ids are unique. At dispatch, the
doctor derives and writes a missing slug on an active task.

**Parallelism is the default.** The slug is the partition. `/go` groups pending tasks by `Worktree:`
and dispatches at most one specialist per group: tasks on different slugs run **in parallel**, and
tasks that share a slug run one after another. Decomposition therefore maximizes parallelism: every
independent file surface gets its own slug, a slug is shared only when tasks write the **same** files,
and a dependency is declared only when a task consumes another's output. Over-shared slugs and
needless dependencies are the two ways to serialize work for nothing, and decomposition avoids both by
default.

Git itself is the lock: `git worktree add <repo>/.worktree/<slug> -b worktree/<slug>` fails when the
branch is already checked out elsewhere. acf-whip adds no lock file, daemon or scheduler for this.

**Ownership scope.** acf-whip owns one branch namespace, `worktree/<slug>`, and creates, inspects or
removes worktrees only on it. The doctor's orphan reaper and wrong-branch check stay inside that
namespace, so the `/go` bootstrap `--fix` never touches a worktree you keep in the same repo for your
own research or benchmarking, even one under `.worktree/`. A foreign branch, a detached worktree
(mid-rebase) or a plain directory there is left alone. Each project can change the directory and
branch prefix in `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR`, default `.worktree`;
`ACFW_BRANCH_PREFIX`, default `worktree`). Change them only on a fresh backlog: existing worktrees
stay pinned to the namespace they were created under.

## Per-task child workflows (3.2.0)

Each dispatched unit runs as its **own nested workflow**, not as a single agent. A
**workflow-architect** agent authors a harness for that specific task by filling four marked regions
of a locked, shipped skeleton (`skills/lib/child-skeleton.js.tmpl`). `/go` runs the file only after a
validator byte-diffs every locked segment. The skeleton owns the single `clean-checkout`, the stage
primitives, the progress ledger, the budget guard, the commit verifier, the review-panel arithmetic
and the only return path. The architect cannot author any of that away.

**Seams.** Implementation and LP-CAS conflict resolution escalate by default. The multi-lens review
panel is opt-in (`args.escalateReview`) because it is the only *subtractive* seam: it can reject work
that would otherwise have shipped, against a hard 3-rejection terminal. Aggregation is strict majority
with **no veto**, and a panel of any size can cost at most one rejection per round.

**Durability.** A workflow script has no filesystem, so each stage's own agent appends its result to
a ledger under `.acfwhip/run/child/<stem>/<attempt>/<kind>/` (gitignored). Because the record lives
outside the script, it survives the script throwing *and* the architect's repair edit. When a harness
throws, a scout reconciles that ledger against git, and the architect amends the harness knowing
which stages completed; the amended run replays those stages in **zero agents**. A commit-bearing
entry is trusted only when git confirms it with an `ACFW-Stage:` trailer, and every disagreement
resolves toward an **informed re-run**, never a skip.

The attempt key is `a<RejectionCount>-b<BlockCount>`. It stays stable across amends, re-dispatches
and `/go` crashes, so progress survives them, and it is **new** after an external rejection, since a
retry harness that replayed everything as done would produce nothing.

**Degradation.** The runtime caps the total agents per run, and children share that count, so `/go`
steps down FULL → LEAN → DIRECT → CLOSE as the budget runs low, ending at verbatim 3.1.0 single-agent
dispatch. Escalation is a **policy, not a guarantee**: on a large backlog the tail of a run is 3.1.0,
and the report says so (`escalation{}`, `agentsUsed`, `stopReason: agent-cap-reached`). Every failure
path (architect non-emit, pre-flight rejection, an exhausted amend budget, `workflow()` unavailable)
lands on the same fallback. `args.escalate: false` turns the whole feature off.

### Step 0: clean-checkout-before-task

Every implementer specialist and `quality-reviewer` invokes the `clean-checkout-before-task` skill as Step 0, before reading the task body. The skill:

1. Resolves `<slug>` from the task front-matter.
2. Lazy-creates `.worktree/<slug>` on branch `worktree/<slug>`.
3. Validates the branch matches the derivation rule.
4. Stashes unrelated working-tree changes.
5. Logs `clean-checkout: ok` to the task transition log.

Quality-reviewer rejects any task in `.backlog/in-review/` whose transition log lacks the
`clean-checkout: ok` token. Since 3.2.0 `/go` also checks the token itself, in code, before it
dispatches a reviewer, and classifies what it finds. A missing token with the worktree branch
**present** means the token was lost, not the work: a mechanism fault, retried with no rejection
charged. No branch at all is a real quality rejection.

**One clean-checkout per (task, attempt) (3.2.0, WT-1).** The skill is *not* reentrant. Its exit-2
mutual exclusion fires only when the worktree is **created**, so a second call against a live
worktree passes the branch check and goes on to step 4, whose `git stash push -u … || true` silently
sweeps another stage's in-flight work into the **shared** `refs/stash`. Inside a child workflow the
checkout therefore runs once, in the locked prologue. It is guarded by an **observation**
(`git worktree list --porcelain` shows the branch), not by a ledger record, because a lost ledger
entry must never trigger a second stash. No authored stage may invoke the skill, and the validator
rejects a harness that names it.

**One writer at a time.** Within a task, "write" includes editing files, `git add`/`git commit`,
**and running the build or test suite**, which produces build output, caches, coverage and formatter
rewrites. Read-only work (recon, call-site census, review lenses, adversarial judging) can run in
parallel. The stage runner forces mutating stages to run one at a time, so the rule is enforced by
structure, not by asking.

After Step 0, every code edit and commit happens inside the worktree on `worktree/<slug>`. Task state
stays with the orchestrator, which moves task files at the root. **A specialist never commits on the
trunk branch.**

### Integration

**Default (LP-CAS, 3.0.0)**: through the `integrate-lpcas` skill, the orchestrator folds every newly
accepted task onto the branch checked out at the repo root (the live trunk). The task's change is
published as a single-parent candidate (tree = its `worktree/<slug>` branch tip, parent = its
fork-base) and applied with `git cherry-pick --no-commit` onto the **live** trunk tip. The base is the
candidate's own parent: never a cached snapshot, never a rebase or replay. The change **and** an
in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`) go into **one** single-parent
commit, the project union gate runs on that candidate tree, and the result lands by compare-and-swap
(`update-ref <new> <observed>`). A cherry-pick conflict, such as two parallel tasks editing one file,
goes to the task's `assigned_agent` as a resolver; it is never dropped silently. **Integration truth
is the marker's presence in the live-trunk tree, and nothing else.** The integrator ignores
`Integrated-At:`, which is display and operator-ack metadata (see `recovery-runbook.md`).

**Streaming, not a wave barrier.** Each dispatched unit moves through its **own** lifecycle
(specialist → review → integrate) as soon as it is ready, instead of waiting for the slowest task in
the iteration. A documentation task done in minutes is reviewed, accepted and, for code, integrated
within minutes, even while a multi-hour task from the same wave is still running. Two invariants hold
through **explicit serialization** rather than the iteration barrier: a single-writer promise chain,
so `apply-transition.sh` calls never overlap, and an integrate lock, so git folds onto trunk stay
sequential. Cross-slug dependents are already gated at **dispatch** (a dependent waits until its
dependency is accepted **and** integrated), so units accepted in the same wave do not depend on each
other and need only serialization. Accepted leftovers from before the run, which can depend on each
other, integrate first in one topologically ordered pass under the lock. `tests/phase5-streaming`
covers this: a fast task integrates while a gated slow task from the same wave is still in flight, a
setup that deadlocked under the old barrier.

**Override**: `/go` skips auto-integration and the operator owns integration. No ledger marker is
written, the terminal check falls back to `accepted ∪ blocked`, and each accepted task's
`worktree/<slug>` branch and worktree are **kept alive**. (Default mode reaps them once the change is
on trunk; in override mode that branch is the only copy of the deliverable.) The doctor relaxes its
`cross-slug-dep-not-integrated` gate to match, because the scheduler and the doctor must agree on
what "terminal" means, or the run aborts on their disagreement.

Two ways to select it:

- **Pinned** (preferred when the answer must not vary per run): `ACFW_INTEGRATION_MODE=override` as an env var or a key in the committed config (`.acfwhip/config`, or the legacy `.backlog/.acfw-config`; whichever the project has, and the first existing file wins). `acfw-store info` reports it as `integrationMode`. An unrecognized value is FATAL rather than a silent fallback, and a trailing `# comment` counts as part of the value.
- **Unpinned**: `/go` decides per run by reading the project's `CLAUDE.md`/`AGENTS.md` (for example, "open a PR per `PR Group:` via `gh pr create` instead of merging locally"), following Claude's instruction-priority hierarchy.

Override mode does **not** push, run `gh pr create`, or read `PR Group` (stored, but it drives no
behavior). It stops at accepted and leaves the rest to you. `.backlog/` state transitions are
committed on the trunk branch in **both** modes. If trunk must stay free of bookkeeping commits, use a
non-files task store, where task state lives outside git.

**Terminal in default mode**: an accepted task is terminal once nothing is left to fold into trunk.
That means its **ledger marker is on trunk** (the integration oracle), **or** it is non-code
(`Worktree: none`), **or** it has no `worktree/<slug>` branch (a historical, pre-3.0.0 task already
merged the old way). Branchless historical accepted tasks are never queued for integration (there is
no candidate ref; the integrator exits 4, "nothing to integrate"), so an old backlog reaches 100%
instead of looping on phantom branches. A `worktree/<slug>` branch that **exists but has no commits
ahead of trunk** also lands cleanly. That happens when a read-only, gate or verification task got a
slug but produced no code: the empty cherry-pick applies nothing, the integrator commits the marker
alone, and the task becomes terminal instead of retrying forever.

**Completion requires no queued unblock.** The loop declares the backlog complete only when it is
100% terminal **and** no blocked task is about to be unblocked. Without that rule, a cross-slug
dependency that integrates in the final iteration would reach 100% and exit before the blocked
dependent gets its `blocked → pending` pass. The loop runs one more unblock-and-dispatch pass first.

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
4. Blocker tasks still go first within a group, but they do not break the per-group serialization.
5. **Dependency gating**: a task may dispatch only from a codebase that already contains all its dependencies.
   - **Same-slug dep** (dep's `Worktree:` equals this task's `Worktree:`): satisfied as soon as the dep is in `.backlog/accepted/`. The dep's commits already live on the shared `worktree/<slug>` branch.
   - **Cross-slug dep**: the dep's commits must already be on the local trunk. It blocks only while it
     is still waiting for integration: in `accepted/`, with a live `worktree/<slug>` branch and **no
     ledger marker on trunk** yet. A dep whose marker is on trunk satisfies it, and so does a
     **branchless historical (pre-3.0.0)** accepted dep, since no worktree branch means it reached
     trunk the old way. A non-code (`none`) dep is satisfied on acceptance.
   - In override (PR) mode no ledger marker is written, so acceptance is enough for a cross-slug dep
     and the operator is responsible for ordering. The doctor relaxes its matching FATAL there too;
     before it did, the scheduler dispatched the dependent and the next integrity recheck aborted the
     run on that same dispatch.

## Evidence Requirements

Every completed task must provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA on `worktree/<slug>` (not on the trunk branch)
4. Transition log with timestamps including at least one `clean-checkout: ok` line

In default mode, an accepted task becomes integrated when:
5. The LP-CAS integrator (`integrate-lpcas`) lands its in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`) on trunk, in the same commit as the change. That marker is the integration oracle, not any markdown field; the integrator ignores `Integrated-At:`.

## Backlog integrity (`/whip-doctor`)

`doctor.sh` is the integrity battery. It runs as a **hard gate** at `/go` startup, as a
**per-iteration recheck** inside the loop, and at **`/task` create time**; `/whip-doctor [--fix]`
runs it on demand. At startup `/go` applies the REPAIRABLE class with `--fix` and re-scans. What a
remaining FATAL does depends on its scope (3.4.0). A **repo-scoped** FATAL (a detached HEAD, a
worktree on the wrong branch, a battery that could not run) stops the run before the next dispatch,
at startup or mid-run. A **task-scoped** FATAL holds out the one task it names, and the rest of the
board runs. The legacy markdown loop still refuses on any FATAL. `recovery-runbook.md` covers each
finding code and its recovery.

Findings are `SEVERITY|CODE|TASK_ID|DETAIL` lines, then one grouped `BREAKDOWN|<SEV>|code=count,…`
line per severity (so callers summarize instead of dumping every line), then
`SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false`.

**Severity depends on the dispatch path.** A task in `accepted/` is terminal and out of scope, so its
structural defects are **advisory (WARN), never blocking**. A pre-2.0.0 backlog of historical accepted
tasks (missing slugs, stale `Status:`, even dangling or cyclic deps among themselves) does not trip
the gate. A task-scoped FATAL can only name an **active** task (pending, in-progress, completed,
in-review): an unknown Assigned Agent, dangling or cyclic deps, or a cross-slug dependent dispatched
before its dep is on trunk (branch-aware: a branchless historical dep counts as satisfied). A
worktree on the wrong branch and a detached HEAD at trunk are repo-scoped. Since 3.0.0 a **duplicate
id** is advisory (WARN, quarantine): it isolates that id for an operator and the run continues.

`--fix` repairs the REPAIRABLE class:

- a status-vs-folder mismatch on an active task. `Status` is rewritten to match the folder, which is
  the source of truth, so the bootstrap gate repairs a `Status` a mover left stale instead of aborting
- a missing worktree slug on an active code task, derived from the id and written in
- an out-of-range Rejection Count or Block-Count
- a task present in two folders
- an orphaned `.worktree/<slug>`

The doctor never touches integration state. (The pre-3.0.0 "stray `Integrated-At`" reconciliation is
gone.)

## Worktree environment hydration (`.worktreeinclude`)

`.worktreeinclude` is a committed manifest at the repo root. It lists the git-ignored files a fresh
`.worktree/<slug>` needs for a full dev and test sandbox (`.env`, local config, `node_modules`,
`.venv`). `clean-checkout-before-task` calls `hydrate-worktree.sh` right after it creates a worktree.
Lines may be globs. The default action is **copy**, and the prefixes are `link:`, `copy:` and
`secret:` (copy + `0600`). Secrets are protected by an allowlist: nothing is materialized unless it is
listed, anything on a denylist (`.env*`, `*.pem`, `*.key`, `id_*`, `credentials*`, `*.p12`, anything
under `.git/`) is refused as a symlink and copied instead, every entry must already be git-ignored
(`git check-ignore`), and a tracked path is a hard error. Hydration therefore can never stage a
secret.

## In-progress timeout (operator-configurable)

`.backlog/.acfw-config` sets `ACFW_INPROGRESS_TIMEOUT_HOURS` (default **8**; the env var overrides
it). `scan-backlog.sh` resolves the threshold (env > config > 8) and emits it in the snapshot. The
doctor WARNs on in-progress tasks older than that, and `/go` moves them **in-progress → blocked**
(`timeout >=Nh — stale dispatch`), so a crashed or hung dispatch becomes terminal instead of being
re-dispatched forever. `whip-init` scaffolds the config.

## Per-task loop-breaker (Block-Count)

`/go` dispatches a specialist only on a task whose dependencies are satisfied, so a specialist that
returns `transition: blocked` is saying the **real blocker is not modeled** (for example, "needs a
python-engineer task that does not exist"). Unguarded, such a task cycles
`pending → in-progress → blocked → pending` forever. Its declared deps stay accepted, so the unblock
pass re-queues it every iteration, and the global no-gain guard never trips because other tasks keep
making progress.

`/go` breaks the loop with a **durable per-task `Block-Count`**. Each time a specialist re-blocks a
dispatched task, the counter goes up by 1; blocks from a timeout or a max-rejection redesign do
**not** count. Once `Block-Count` reaches the cap (default **3**), the unblock pass stops re-queueing
the task. It stays in `blocked/` (terminal) and appears in the run report under `needsOperator`, with
its reason. The count lives in the task front-matter, so it survives a crash or restart. To re-enable
the task, an operator clears `Block-Count` or models the missing dependency.

**Structured `dependency-missing` signal.** A specialist can name the missing blocker outright: its
`ACFW-RESULT` may carry `blocked_reason: dependency-missing` and a free-text `needs_task`. The
orchestrator then **parks the task for an operator at once**. It stops re-queueing the task for this
run instead of spending the whole Block-Count budget on the loop, and prints a "create a task: …" line
naming the missing work. The fix is always to create the missing task as a dependency; re-running
`/go` does not help. Parked tasks appear under `needsOperator` in the run report, with their
`needsTask` hint.

## Manual close-out (`/whip-move`)

When a run stops short (a `scan-degraded` stop, say, or a deliberate partial run), `/whip-move`
closes out the last tasks **without hand-editing files**. It resolves a task by stem, id or prefix and
runs the same validated `apply-transition.sh` writer the orchestrator uses: `Status:` synced to the
destination folder, a Transition Log row spliced in, and a commit, all at once. A manual move
therefore cannot leave a stale `Status:`. In the same commit it can also append a dependency
(`--add-dep ID`) or, on the `files` store, set `Integrated-At:` (`--integrated-at SHA`). Run
`/whip-doctor` afterwards. `/whip-move` handles one task at a time; for bulk progress use `/go`.

## Run survival (bounded agent retry)

Every schema-bearing agent call the orchestrator makes (bootstrap, scan, the single writer,
integrate, drain) is wrapped in a bounded retry. When a subagent finishes without returning its
structured result (a StructuredOutput non-emit), the retry degrades that step instead of letting the
exception abort the run. Each step maps a non-emit to its safe transient: the writer defers its moves
to the next iteration (apply-transition is idempotent), and integrate leaves the task accepted to
retry.

**The read-only scan never aborts the run.** The per-iteration scan is bookkeeping (counts and
actionable tasks), and a transient emit failure must not throw away hours of good iterations. Three
layers protect it. First the schema scan retries. Then a **schema-less text scan** runs
`scan-backlog.sh` through a plain agent and parses the JSON out of its message, since the usual
failure is a model that answered but did not call the tool. If that fails too, the loop **stops as
`scan-degraded`**, drains any integratable work off the last good snapshot, and returns a clean,
non-aborted report; re-running `/go` resumes. A repo-scoped integrity FATAL mid-run still aborts,
because retrying cannot repair it. The drain also falls back to the last good snapshot if its own
scan cannot emit. One failed agent call costs at most one iteration, never the run.

## Run & resume model

git and `.backlog/` are the only durable state, plus a planned cycle's `docs/cycles/` folder.
**Re-running `/go` is the resume.** A fresh run re-scans from disk and rebuilds the same plan. A
Claude Code restart loses only the in-session agent cache and any in-flight worktree edit; the edit
shows up as a stale in-progress task, which clean-checkout's stash and the timeout recover.
`Block-Count` and `Rejection Count` live in the front-matter, so the loop-breaker and retry budgets
survive a restart too. The workflow path also writes a gitignored `.backlog/.acfw-run.json` heartbeat
each iteration so you can watch a run. It doubles as the run lock (see `recovery-runbook.md`);
resuming does not depend on it.

## Planned cycles in git (3.5.0)

A planned cycle is the folder `docs/cycles/YYYYMMDD-<slug>/`. `plan.md` is the spec, and it is yours.
`record.md` holds the approval stamp, the deliverable-to-task map and the Plan Log; only `acfw-cycle`
writes it. `/retro` writes `retro.md`.

**Tasks never edit cycles.** `integrate-lpcas` strips `docs/cycles/` from every candidate it lands
and prints a WARN naming each dropped path, so neither a task working in a worktree nor a conflict
resolver can land a plan edit. A candidate whose only change was under `docs/cycles/` still lands its
ledger marker, with a second WARN saying the task delivered nothing. A `Worktree: none` task never
passes through the integrator. The single writer commits the deliverable files it lists, so such a
task must never list a path under `docs/cycles/` (a plan changes only through `/whip`). The doctor's
`dirty-trunk-root` check ignores `docs/cycles/`, because a human edits `plan.md` at the root by
design.

Every cycle event that reaches git is its own pathspec commit, never folded into a task or state commit:

- **Subject**: `docs(plan): <event> <slug>`, for example `docs(plan): approve owner-seat-notice` or `docs(plan): decompose owner-seat-notice`. The slug is the folder name without its date, cut short so the subject stays within 50 characters.
- **Trailer**, one line per event: `ACFW-Plan-Event: <event> <c12> <cycle-id>`, for example `ACFW-Plan-Event: approved 3f9c0a1b2d4e 20260928-owner-seat-notice`. `<c12>` is the first 12 hex characters of the plan's content hash (`v1:` plus the git hash of the normalized `plan.md`).

**Plan trailers are audit only.** Nothing reads one to decide anything. The approval gate is a content check made from HEAD: `Approved Content` in `record.md`, the newest `approved` row of its Plan Log, and the hash of `plan.md` must all agree. A missing, indented or dropped trailer gives one WARN in `/whip` status and never a refusal. (Other `ACFW-*` trailers are not audit-only: `ACFW-Stage:` is the proof a child-workflow stage landed. Never strip or reword any `ACFW-*` line.)

Which merge methods keep plan trailers:

| Merge method | Plan trailers |
|---|---|
| Merge commit | Kept: the original commits stay in history unchanged |
| Rebase, or fast-forward | Kept: each commit is replayed with its own message |
| Squash | May be dropped, or indented inside the squashed message body. Only a WARN; the gate still passes because it never read them |

## Operator gates: when a run stops for a person (not review criteria)

These say when a run must stop and ask a person. They are **not** criteria for accepting or rejecting a task; do not review against them. The normative list lives in the `/whip` skill (`skills/whip/SKILL.md`, "Gates and non-gates"). In short:

- **Gates**: plan approval (including a blocking spec tool's NO-GO), retro action-item approval, parked work (blocked at the cap, dependency-missing, draft, a failed deliverable), and ship.
- **Non-gates**: a rejection under the cap, a merge conflict, a red gate inside a worktree, a retry, an implementation choice the acceptance criteria leave open, advisory critique or findings, a plan without D headings, a missing sibling plugin, a spec tool that could not run.

---

**Last Updated**: 2026-09-29
