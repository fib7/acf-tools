<!-- acf-whip-artifact: content/backlog/workflow.md v3.4.0 -->
# Task Workflow

## Pluggable task store (3.1.0)

Task state lives in a **task store** behind an executable adapter contract (plugin
`adapters/CONTRACT.md`). The dispatcher `skills/lib/bin/acfw-store` resolves the active backend
(`ACFW_STORE` env → `ACFW_STORE=` in `.acfwhip/config` or the legacy `.backlog/.acfw-config` →
`files`), locates its adapter (project-local `.acfwhip/adapters/` → shipped `adapters/<backend>/` →
`$PATH`), and routes every read/write: `snapshot` (the scan), `transition` (the single-writer
primitive), `read`/`create`/`update-field`, `doctor`.

| Backend | State lives in | Notes |
|---|---|---|
| `files` (default) | `.backlog/<state>/*.md` on trunk | reference backend; everything below describes it literally |
| `beads` | `bd` issue tracker (`.beads/`, embedded Dolt) | custom statuses mirror the whip states; deps native |
| `multica` | multica server (Postgres, via CLI) | `whip_state` metadata is canonical; comments are the audit trail |
| `linear` | Linear workspace (GraphQL API) | `whip_*` state in per-issue attachment metadata; native status is a display projection; comments are the audit trail |

Invariants that hold on EVERY backend: the whip-canonical state machine below, the single sequential
writer, worktree-slug partitioning, the dependency gate, idempotent transitions, and the **LP-CAS
integration ledger staying git-native** (`.acfwhip/integrated/` on trunk — integration truth never
moves into a store backend). On non-files backends, dispatched agents read a spec **materialized**
from the store (`acfw-store read --materialize`) instead of a live `.backlog/` path, and evidence
flows back via `acfw-store comment`; the `.backlog/`-literal prose below applies to the files
backend. The legacy (non-workflow) `/go` loop is files-only.

## State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

## Execution paths: workflow-native (default) and legacy fallback

`/task` and `/go` run as **dynamic workflows** (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) when the host supports them. The loop, the slug partition, the dependency gate, the topological integration order, and the stall/terminal bookkeeping run inside a deterministic JavaScript script; **intermediate state lives in script variables, not Claude's context**, so context stays flat across iterations no matter how large the backlog. Every filesystem/git action is delegated to a narrow agent: a read-only scanner (`scan-backlog.sh`), a single sequential writer (`apply-transition.sh`), parallel specialists/reviewers isolated by worktree slug, and a sequential LP-CAS integrator (`integrate-lpcas.sh`) with conflict-resolver dispatch hoisted into the script.

**Bounded working-set snapshot.** The workflow JS has no filesystem access, so each iteration a scanner agent runs the store walk and hands its JSON back. That hop is the constraint: the payload must fit what a model will echo reliably, and a short echo is valid JSON — indistinguishable from a smaller board — so the scheduler would plan over a backlog that does not exist. Three mechanisms bound it, and one proves it arrived.

*Collapse.* `--digest` emits full per-task objects only for tasks the scheduler can act on — every non-accepted active task, every accepted task still pending integration, and every accepted task something **depends on** (so dependency resolution never sees a gap) — while terminal/historical accepted tasks collapse into aggregate counts. Since 3.4.0 this is real on **every** backend, not just `files`: the dispatcher applies the same three-way split to any adapter that does not implement it.

*Narrowing.* A scoped run (`/go <ids>`, or a bare `/go` running your focus) passes `--only`, and the store emits just the closure of those tasks — the seeds plus every dependency that is not accepted-terminal. A five-task run relays five records whatever the board's size.

*Proof.* Every snapshot leads with a `relay` header stating how many entries it contains and the byte sum of their stems. The consumer recomputes both and refuses a mismatch, retrying and then stopping as `relay-truncated` — never reporting the named ids as nonexistent, which is what a silently short echo used to look like. The doctor's findings ride the same hop, so the `SUMMARY`'s `fatal=N` is cross-checked against the lines relayed: a dropped FATAL would silently un-hold the task it names.

Completion is measured over `counts.total` (active folders only) against `runtimeTerminalDefault`/`runtimeTerminalOverride`, which mirror the JS terminal rule exactly; a snapshot missing those counts aborts loudly (version skew) rather than silently stalling. The doctor's `--quiet` mode likewise bounds the integrity report to FATAL findings plus the grouped breakdown, so hundreds of historical advisories never flow through the gate agent.

When dynamic workflows are unavailable (disabled, or older Claude Code), both commands fall back to the **legacy single-context loop** documented below — byte-compatible behavior over the same `.backlog/` state machine, but the loop lives in (and grows) Claude's context. The capability check is simply whether the `Workflow` tool is present; no plugin code special-cases it.

Both paths enforce the same invariants: the doctor integrity gate, the single-writer rule, worktree-slug partitioning, and the dependency gate.

## State Transition Authority

All `.backlog/` state moves happen at the **repo root** (`$ACFW_TRUNK_ROOT`) on the **trunk branch**. The orchestrator (`/go`) is the single writer of `.backlog/` files; specialists and quality-reviewer signal their decisions via the `ACFW-RESULT` marker in their Task() return, and the orchestrator performs the corresponding move + commit on trunk.

| From | To | WHO performs the move (at root, on trunk) |
|------|----|-------------------------------------------|
| N/A | pending | task-engineer (creation, at root, never in a worktree) |
| pending | in-progress | `/go` orchestrator (pre-move + commit before dispatching specialist) |
| in-progress | completed | `/go` orchestrator on specialist's `transition: completed` signal |
| in-progress | blocked | `/go` orchestrator on specialist's `transition: blocked` signal (increments `Block-Count` — the per-task loop-breaker) |
| completed | in-review | `/go` orchestrator (pre-move before dispatching quality-reviewer) |
| in-review | accepted | `/go` orchestrator on reviewer's `transition: accepted` signal |
| in-review | rejected | `/go` orchestrator on reviewer's `transition: rejected` signal (also increments Rejection Count) |
| rejected | pending | `/go` orchestrator (workflow path) on retry, up to the orchestrator's cap (`MAX_REJECT_RETRY`, currently 3); task-engineer at root on the legacy markdown loop |
| blocked | pending | `/go` orchestrator when deps resolve (gated on `Rejection Count` < cap and `Block-Count` < cap), or task-engineer (unblock, at root) |
| rejected | blocked | `/go` orchestrator at the cap — the task is parked for task-engineer to redesign; task-engineer at root on the legacy loop |

**task-engineer never enters a worktree.** It never invokes `clean-checkout-before-task`. All its operations are on `.backlog/` at the repo root, committed to the trunk branch.

**Specialists** still do code work inside `.worktree/<slug>` on `worktree/<slug>` — that is unchanged. Their commits on the worktree branch contain code only; they do NOT move task files and do NOT commit `.backlog/` changes on the worktree branch.

**Retry limit**: a rejected task returns to pending until it hits the orchestrator's retry cap (`MAX_REJECT_RETRY`, currently **3**, and settable per run with `maxReject`). At the cap it is moved to blocked for task-engineer to redesign, and the unblock pass will not lift it again — so the number here is not advisory, it is the point at which automation stops. A review that reports `faultClass: mechanism` (a broken environment, a lost clean-checkout token) does not charge it.

**File move + Status rewrite + transition-log update = ATOMIC** (same commit on trunk). The single writer rewrites `- **Status**:` to the destination folder as it moves the file — **the folder is the source of truth and Status always follows it** — so a transition can never leave Status stale (a stale Status used to self-inflict a `status-folder-mismatch` FATAL that aborted `/go` at its first transition).
**Timestamp command**: `date +"%Y-%m-%d %H:%M:%S"` (never placeholder).
**Transition rows splice into the `## Transition Log` table and cap** (shared `append_log_row`), so a task file stays well-formed and bounded no matter how many transitions churn — rows never dangle after the last heading.

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

**Ownership scope.** acf-whip owns exactly one branch namespace — `worktree/<slug>` — and only ever creates, inspects, or removes worktrees on it. The doctor's orphan reaper and wrong-branch check are scoped to that namespace, so the `/go` bootstrap `--fix` never touches a worktree you keep in the same repo for your own research/benchmarking, even one parked under `.worktree/` — a foreign branch, a detached worktree (mid-rebase), or a plain directory there is left completely alone. The directory and branch prefix are configurable per project via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR`, default `.worktree`; `ACFW_BRANCH_PREFIX`, default `worktree`); change them only on a fresh backlog, since existing worktrees are pinned to the namespace they were created under.

## Per-task child workflows (3.2.0)

Each dispatched unit runs as its **own nested workflow**, not as a single agent. A **workflow-architect** agent authors a harness for that specific task by filling four marked regions of a locked, shipped skeleton (`skills/lib/child-skeleton.js.tmpl`); a validator byte-diffs every locked segment before `/go` will run the file. The skeleton owns the single `clean-checkout`, the stage primitives, the progress ledger, the budget guard, the commit verifier, the review-panel arithmetic and the sole return path — none of it can be authored away.

**Seams.** Implementation and LP-CAS conflict resolution escalate by default. The multi-lens review panel is opt-in (`args.escalateReview`) because it is the only *subtractive* seam: it can reject work that would otherwise have shipped, against a hard 3-rejection terminal. Aggregation is strict majority with **no veto**, and a panel of any size can cost at most one rejection per round.

**Durability.** Each stage's own agent appends its result to a ledger under `.acfwhip/run/child/<stem>/<attempt>/<kind>/` (gitignored), because a workflow script has no filesystem — which is exactly why the record survives the script throwing *and* the architect's repair edit. When a harness throws, a scout reconciles that ledger against git and the architect amends with the completed-stage set in hand; the amended run replays those stages in **zero agents**. A commit-bearing entry is trusted only when git confirms it with an `ACFW-Stage:` trailer; every disagreement resolves toward an **informed re-run**, never a skip.

The attempt key is `a<RejectionCount>-b<BlockCount>`: stable across amends, re-dispatches and `/go` crashes (so progress survives them), and **new** on an external rejection — a retry harness that replayed everything as done would produce nothing.

**Degradation.** The runtime caps total agents per run and children share the counter, so `/go` degrades FULL → LEAN → DIRECT → CLOSE as its budget depletes, falling back to verbatim 3.1.0 single-agent dispatch. Escalation is therefore a **policy, not a guarantee**: on a large backlog the tail of a run is 3.1.0, and the report says so (`escalation{}`, `agentsUsed`, `stopReason: agent-cap-reached`). Every exhaustion path — architect non-emit, pre-flight rejection, amend budget, `workflow()` unavailable — lands on the same fallback. `args.escalate: false` disables the whole feature.

### Step 0: clean-checkout-before-task

Every implementer specialist and `quality-reviewer` invokes the `clean-checkout-before-task` skill as Step 0, before reading the task body. The skill:

1. Resolves `<slug>` from the task front-matter.
2. Lazy-creates `.worktree/<slug>` on branch `worktree/<slug>`.
3. Validates the branch matches the derivation rule.
4. Stashes unrelated working-tree changes.
5. Logs `clean-checkout: ok` to the task transition log.

Quality-reviewer rejects any task in `.backlog/in-review/` whose transition log lacks the `clean-checkout: ok` token. As of 3.2.0 `/go` also checks this **deterministically** before dispatching a reviewer, and types the result: a missing token with the worktree branch **present** means the token was lost rather than the work (a mechanism fault — retried, no rejection charged), while no branch at all is a genuine quality rejection.

**Exactly one clean-checkout per (task, attempt) — 3.2.0, WT-1.** The skill is *not* reentrant: its exit-2 mutual exclusion fires only when the worktree is **created**, so a second invocation against a live worktree passes the branch check and proceeds to step 4, whose `git stash push -u … || true` silently sweeps another stage's in-flight work into the **shared** `refs/stash`. Inside a child workflow the checkout therefore happens once, in the locked prologue, guarded by an **observation** (`git worktree list --porcelain` shows the branch) rather than by a ledger record — a lost ledger entry must never be able to trigger a second stash. No authored stage may invoke it, and the validator rejects a harness that names it.

**One writer at a time.** Within a task, "write" includes editing files, `git add`/`git commit`, **and running the build or test suite** (which produces build output, caches, coverage and formatter rewrites). Read-only work — recon, call-site census, review lenses, adversarial judging — is the parallel lane. The stage runner forces mutating stages sequential, so this is structural rather than a request.

All subsequent state moves, edits, and commits happen inside the worktree on `worktree/<slug>`. **No commits land on the trunk branch from a specialist.**

### Integration

**Default (LP-CAS, 3.0.0)**: the orchestrator folds every newly-accepted task onto the branch checked out at the repo root (the live trunk) via the `integrate-lpcas` skill. The task's change is published as a single-parent candidate (tree = its `worktree/<slug>` branch tip, parent = its fork-base) and `git cherry-pick --no-commit`-applied onto the **live** trunk tip — base is the candidate's own parent, never a cached snapshot, never a rebase or replay. The change **and** an in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`) are committed in **one** single-parent commit, the project union gate runs on that candidate tree, and the result lands by compare-and-swap (`update-ref <new> <observed>`). A cherry-pick conflict (e.g. a same-file parallel task) is surfaced to the task's `assigned_agent` as a resolver — never silently dropped. **Integration truth is the marker's presence in the live-trunk tree, and nothing else** — `Integrated-At:` is inert (kept only for display).

**Streaming, not a wave barrier.** Each dispatched unit flows through its **own** lifecycle — specialist → review → integrate — as soon as it is ready, rather than waiting for the slowest task in the iteration. A documentation task done in minutes is reviewed, accepted, and (for code) integrated in minutes even while a multi-hour task dispatched in the same wave is still running. Two invariants are preserved by **explicit serialization**, not the iteration barrier: a single-writer promise-chain so `apply-transition.sh` calls never overlap, and an integrate lock so git folds onto trunk stay sequential. Cross-slug dependents are already gated at **dispatch** (a dependent is not dispatched until its dependency is accepted **and** integrated), so units accepted in the same wave are mutually dependency-independent and need only serialization; pre-existing accepted leftovers (which can be interdependent) integrate first in one topo-ordered, lock-held pass. The behavior is regression-tested in `tests/phase5-streaming` (a fast task integrates while a gated slow task in the same wave is still in flight — a construction that deadlocks under the old barrier).

**Override**: `/go` skips auto-integration entirely, the operator owns integration, no ledger marker is written, the terminal check falls back to `accepted ∪ blocked`, and each accepted task's `worktree/<slug>` branch and worktree are **kept alive** (in default mode they are reaped once the change is on trunk — in override mode that branch is the only copy of the deliverable). The doctor relaxes its `cross-slug-dep-not-integrated` gate in lockstep, because the scheduler and the doctor must agree on what "terminal" means or the run aborts on their disagreement.

Select it in either of two ways:

- **Pinned** (preferred when the answer must not vary per run): `ACFW_INTEGRATION_MODE=override` as an env var or a key in the committed config (`.acfwhip/config`, or the legacy `.backlog/.acfw-config` — whichever the project has; the first existing file wins). `acfw-store info` reports it as `integrationMode`. An unrecognized value is FATAL rather than a silent fallback, and a trailing `# comment` counts as part of the value.
- **Unpinned**: `/go` decides per run by reading the project's `CLAUDE.md`/`AGENTS.md` — e.g. "open a PR per `PR Group:` via `gh pr create` instead of merging locally" — per Claude's instruction-priority hierarchy.

Override mode does **not** push, run `gh pr create`, or read `PR Group` (which is stored but drives no behavior). It stops at accepted and gets out of the way. Note also that `.backlog/` state transitions are committed on the trunk branch in **both** modes; if trunk must stay free of bookkeeping commits, use a non-files task store, where task state lives outside git entirely.

**Terminal in default mode**: an accepted task is terminal once nothing remains to fold into trunk — its **ledger marker is on trunk** (the integration oracle), **or** it is non-code (`Worktree: none`), **or** it has no `worktree/<slug>` branch (a historical/pre-3.0.0 task already merged the old way). Branchless historical accepted tasks are never enqueued for integration (no candidate ref; the integrator exits 4, "nothing to integrate"), so a lived-in backlog reaches 100% instead of looping on phantom branches. A `worktree/<slug>` branch that **exists but has no commits ahead of trunk** (a read-only/gate/verification task that got a slug but produced no code) also lands cleanly: the empty cherry-pick applies nothing and the integrator co-commits the marker alone, so the task becomes terminal instead of retrying forever.

**Completion requires no queued unblock.** The loop declares the backlog complete only when it is 100% terminal **and** no blocked task is about to be unblocked. Otherwise a cross-slug dependency that integrates in the final iteration would hit 100% and exit before the blocked dependent gets its `blocked → pending` pass — so the loop runs one more unblock+dispatch pass first.

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
   - **Cross-slug dep**: dep's commits must already be on the local trunk. It blocks only while genuinely pending integration — `accepted/`, a live `worktree/<slug>` branch, and **no ledger marker on trunk** yet. A dep whose marker is on trunk satisfies it; so does a **branchless historical/pre-3.0.0** accepted dep (no worktree branch = already on trunk the old way). A non-code (`none`) dep is satisfied on acceptance.
   - In override (PR) mode, where no ledger marker is written, acceptance is sufficient for cross-slug deps; the operator is responsible for ordering. The doctor's matching FATAL is relaxed there too — when it was not, the scheduler dispatched the dependent and the next integrity recheck aborted the run on that very dispatch.

## Evidence Requirements

Every completed task MUST provide:
1. Quality gate outputs (all commands, complete)
2. Test results with coverage
3. Implementation commit SHA on `worktree/<slug>` (not on the trunk branch)
4. Transition log with timestamps including at least one `clean-checkout: ok` line

In default (auto-merge) mode, an accepted task becomes integrated when:
5. The LP-CAS integrator (`integrate-lpcas`) lands its in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`) on trunk, co-committed with the change. That marker — not a markdown field — is the integration oracle; `Integrated-At:` is inert.

## Backlog integrity (`/whip-doctor`)

`doctor.sh` is the integrity battery. It runs at three points: as a **hard gate** at `/go` startup (it applies the REPAIRABLE class with `--fix`, then re-scans and refuses to dispatch if any FATAL remains), as a **per-iteration recheck** inside the loop (a mid-run FATAL — e.g. a cycle introduced by a retry — aborts before the next dispatch), and at **`/task` create-time**. `/whip-doctor [--fix]` runs it on demand. Findings are `SEVERITY|CODE|TASK_ID|DETAIL` lines, then a grouped `BREAKDOWN|<SEV>|code=count,…` line per severity (so callers summarize instead of dumping every line), then `SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false`.

**Severity is scoped to the dispatch path.** A task in `accepted/` is terminal/out-of-scope, so its structural defects are **advisory (WARN), never blocking** — a pre-2.0.0 backlog of historical accepted tasks (missing slugs, stale `Status:`, even dangling/cyclic deps among themselves) does not abort the gate. FATAL is reserved for **active** tasks (pending/in-progress/completed/in-review): unknown Assigned Agent, dangling/cyclic deps, a cross-slug dependent dispatched before its dep is on trunk (branch-aware: a branchless historical dep counts as satisfied), worktree on the wrong branch, detached HEAD at trunk. A **duplicate id** is advisory (WARN/quarantine) in 3.0.0 — it isolates that id for an operator and the run continues; it no longer aborts the whole backlog. REPAIRABLE (auto-fixed by `--fix`): **a status-vs-folder mismatch on an active task (Status rewritten to match the folder — the folder is the source of truth; this is why a backlog whose mover left Status stale self-heals at the bootstrap gate instead of aborting)**, a missing worktree slug on an active code task (derived from the id and written in), out-of-range Rejection Count or Block-Count, a task present in two folders, an orphaned `.worktree/<slug>`. (The pre-3.0.0 "stray `Integrated-At`" reconciliation is gone — the field is inert, so the doctor never touches integration state.)

## Worktree environment hydration (`.worktreeinclude`)

A committed root manifest lists the git-ignored files a fresh `.worktree/<slug>` needs to run a full dev/test sandbox (`.env`, local config, `node_modules`, `.venv`). `clean-checkout-before-task` calls `hydrate-worktree.sh` right after creating a worktree. Lines are glob-capable; default action is **copy**, with `link:`, `copy:`, and `secret:` (copy + `0600`) prefixes. Secret-safety is allowlist-only: nothing is materialized unless listed, a denylist (`.env*`, `*.pem`, `*.key`, `id_*`, `credentials*`, `*.p12`, anything under `.git/`) is refused for symlink and forced to copy, every entry must already be git-ignored (`git check-ignore`), and a tracked path is a hard error — so hydration can never stage a secret.

## In-progress timeout (operator-configurable)

`.backlog/.acfw-config` sets `ACFW_INPROGRESS_TIMEOUT_HOURS` (default **8**; env var overrides). `scan-backlog.sh` resolves the threshold (env > config > 8) and emits it in the snapshot; the doctor WARNs on in-progress tasks older than it, and `/go` moves them **in-progress → blocked** (`timeout >=Nh — stale dispatch`) so a crashed/hung dispatch becomes terminal instead of re-dispatching indefinitely. `whip-init` scaffolds the config.

## Per-task loop-breaker (Block-Count)

A specialist is only dispatched on a task whose dependencies are already satisfied, so a specialist that returns `transition: blocked` is signalling that the **real blocker is unmodeled** (e.g. "needs a python-engineer task that does not exist"). Left unguarded, such a task cycles `pending → in-progress → blocked → pending` forever — its declared deps stay accepted, so the unblock pass re-queues it every iteration, and the global no-gain guard never trips because other tasks keep making progress.

`/go` breaks this with a **durable per-task `Block-Count`**: each specialist re-block of a dispatched task increments the counter (timeout and max-rejection redesign blocks do **not** count). Once `Block-Count` reaches the cap (default **3**), the unblock pass stops re-queueing the task — it stays in `blocked/` (terminal) and is surfaced in the run report as `needsOperator`, with its reason, instead of spinning. The count lives in the task front-matter, so it survives a crash/restart. An operator clears `Block-Count` (or models the missing dependency) to re-enable the task.

**Structured `dependency-missing` signal.** A specialist can make the unmodeled-blocker explicit: its `ACFW-RESULT` may carry `blocked_reason: dependency-missing` and a free-text `needs_task`. When it does, the orchestrator **parks the task for an operator immediately** — it stops re-queueing it this run (rather than burning the full Block-Count budget looping) and emits an actionable "create a task: …" line naming the missing work. The fix is always "create the missing task as a dependency," never "re-run /go." Parked tasks appear in the run report's `needsOperator` with their `needsTask` hint.

## Manual close-out (`/whip-move`)

After any run that stops short (e.g. a `scan-degraded` stop, or a deliberate partial run), `/whip-move` reconciles the last tasks **without hand-editing files**. It resolves a task by stem/id/prefix and runs the same validated `apply-transition.sh` writer the orchestrator uses — atomic `Status:` sync to the destination folder, a spliced Transition Log row, and a commit — so a manual move can never leave a stale `Status:` (a doctor FATAL). It also sets `Integrated-At:` (`--integrated-at SHA`) or appends a dependency (`--add-dep ID`) in the same commit. Run `/whip-doctor` afterwards. It is for one task at a time; for bulk progress use `/go`.

## Run survival (bounded agent retry)

Every schema-bearing agent call the orchestrator makes — bootstrap, scan, the single writer, integrate, drain — is wrapped in a bounded retry that degrades gracefully on a StructuredOutput non-emit (a subagent that finishes without returning its structured result) instead of letting the exception abort the whole run. A non-emit maps to the safe transient for that step: the writer defers its moves to the next iteration (apply-transition is idempotent), and integrate leaves the task accepted to retry.

**The read-only scan never aborts the run.** The per-iteration scan is pure bookkeeping (counts + actionable tasks), so a transient emit failure must not discard hours of healthy iterations. Three layers protect it: the schema scan retries; then a **schema-less text scan** runs `scan-backlog.sh` through a plain agent and parses the JSON out of its message (the common failure is "the model answered but didn't call the tool"); and if even that fails, the loop **degrades to a `scan-degraded` stop** and drains any integratable work off the last good snapshot, returning a clean (non-aborted) report — re-running `/go` resumes. A genuine mid-run integrity FATAL still aborts (that is unrepairable, not transient). The drain likewise falls back to the last good snapshot if its own scan cannot emit. So a single agent hiccup costs at most one iteration, never the run.

## Run & resume model

git plus `.backlog/` are the only durable state — **re-running `/go` is the resume**. A fresh run re-scans from disk and reconstructs the identical plan; the only loss across a Claude Code restart is the in-session agent cache and any in-flight worktree edit, which surfaces as a stale in-progress task that clean-checkout's stash and the timeout recover. `Block-Count` and `Rejection Count` are front-matter, so the loop-breaker and retry budgets also survive a restart. The workflow path also writes a gitignored `.backlog/.acfw-run.json` heartbeat each iteration for observability; the design does not depend on it.

---

**Last Updated**: 2026-06-01
