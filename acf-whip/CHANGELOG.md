# Changelog — acf-whip

All notable changes to acf-whip. Format loosely follows Keep a Changelog.

## 2.5.0 — patch-id-aware integration (heals legacy branches, never destroys accepted work)

From a field report driving `/go` against a long-lived `develop` repo (~640 accepted tasks, branches born before 2.4.1): the 2.4.1 code-only architecture only helps branches it created, so legacy `worktree/<slug>` branches (no fork-base ref) still fell back to a far-back merge-base and replayed ~1000 phantom commits → the accepted→rejected reject-loop; accepted-but-unintegrated work whose equivalent code was already on trunk never registered terminal, stalling `/go` on "needs operator"; and a botched/aborted integration could destroy the branch's code (surviving only in dangling commits).

- **Integration is now patch-id aware.** A shared primitive (`acfw_pending_code_commits`) lists a branch's genuine code commits not yet on trunk *by patch-id*, dropping `.backlog` phantoms and already-applied commits. If the set is EMPTY, the task is stamped `Integrated-At` and reaped with **no rebase and no conflict** — curing the phantom-conflict reject-loop and the "done-modulo-integration" stall, and stopping re-runs from re-rejecting already-integrated work. Otherwise exactly those commits are replayed onto fresh trunk via cherry-pick (clean code-only branches fast-forward first), so a legacy branch with ~1000 phantom commits replays its ONE real commit.
- **Contaminated branches self-salvage in-path.** The exit-8 "contaminated → park for operator" path is retired: a `.backlog`-carrying branch is reconstructed code-only by the patch-id replay (the phantom commits are dropped), folding the real code and stamping `Integrated-At` instead of dead-ending. `clean-checkout` heals the same legacy branches at task-start (no more far-back merge-base fallback), recording a fork-base ref so they stay code-only thereafter.
- **Integration never destroys accepted work.** Before any branch mutation the integrator records `refs/acfw/preintegrate/<slug>` (the pre-integration tip) and prints an `ACFW-INTEGRATE: recovery` line; a resolver failure restores the branch from it (exit 6, code survives) instead of leaving it in dangling commits. The conflict resolver now runs a cherry-pick (`--continue`/`--abort`) and is explicitly forbidden from `git reset`/`checkout`/`switch`/branch-deletion or moving HEAD off the branch.
- **RunReport reconciled against disk.** `integrated` / `rejectedAtIntegration` are re-derived from the final on-disk snapshot (folder + `Integrated-At`) cross-referenced with what the run attempted, so a post-resolver agent non-emit can no longer report `rejectedAtIntegration: []` while the folder says rejected, nor list a rejected task under `integrated`.
- Regression tests: `tests/phase7-patchid-integration.test.sh` (short-circuit, legacy far-back reduction, backup-ref recovery), extended `tests/phase6-worktree-codeonly.test.sh` (in-path salvage + legacy clean-checkout heal) and `tests/phase2-scheduler.test.mjs` (`reconcileIntegrationTallies`). `tests/phase0-extraction.test.sh` updated to the cherry-pick resolver model.

## 2.4.1 — worktree branches are code-only (fix integrate reject-loop)

- Fixes a `/go` reject-loop: long-lived `worktree/<slug>` branches accumulated trunk `.backlog` task-transition commits (one field case: 367 commits ahead, 366 of them phantom). The whole-branch rebase at integrate time then produced phantom conflicts, cycling tasks accepted→rejected endlessly.
- A worktree branch is now **code-only by construction**. A per-slug fork-base ref (`refs/acfw/forkbase/<slug>`) records the trunk SHA the branch's code sits on. Both `clean-checkout` (re-sync) and `integrate-worktree` (pre-FF rebase) now replay ONLY the branch's own commits via `git rebase --onto <trunk-snapshot> <base>` instead of merging trunk's `.backlog` history in or whole-branch rebasing it back.
- Pre-integrate guard refuses any branch carrying `.backlog/` commits (`git log <trunk>..<branch> -- .backlog/` non-empty) → exit 8 / `contaminated`. `/go` parks that task for an operator (manual recovery: cherry-pick the tip code commit onto trunk) instead of rejecting/re-running.
- `apply-transition.sh` gains a defensive trunk-only assertion.
- Regression test: `tests/phase6-worktree-codeonly.test.sh`.

## 2.4.0 — worktree ownership scoping + configurable namespace

- Fixes a field report that `/go`'s startup pruned unrelated worktrees: the bootstrap's `whip-doctor --fix` orphan reaper + `worktree-wrong-branch` FATAL used to iterate every directory under `.worktree/`, force-removing or FATAL-aborting on worktrees a user kept for parallel research/benchmarking.
- The doctor now manages **only** worktrees on acf-whip's own branch namespace (`<ACFW_BRANCH_PREFIX>/<slug>`, default `worktree/<slug>`). An ownership guard skips any directory that is on a foreign branch, detached (mid-rebase), or not a registered worktree — no FATAL, no removal.
- Worktree directory and branch prefix are configurable via `.backlog/.acfw-config` (`ACFW_WORKTREE_DIR` default `.worktree`, `ACFW_BRANCH_PREFIX` default `worktree`), resolved by a shared `acfw_load_namespace` in `skills/lib/acfw-git.sh` and threaded through `clean-checkout`/`integrate-worktree`/`doctor`/`scan-backlog`. Scan digest emits `branchPrefix`/`worktreeDir` so prompt text matches a custom prefix. Defaults preserve prior behavior byte-for-byte.
- `<repo-root>/.worktree/` (gitignored, ephemeral) is now a documented ACF organization convention (librarian `organization-template.md`).
- Regression test: `tests/phase1-doctor-hydrate.test.sh` (foreign-worktree-survives + custom-namespace round-trip).

## 2.3.0 — orchestrator hardening

From a field bug report — two `/go` crashes, a livelock, a barrier stall:

- **Streaming lifecycle**: each dispatched unit runs its own specialist→review→integrate cycle instead of holding the wave at a per-iteration `parallel()` barrier. A fast task is reviewed, accepted, and integrated while a multi-hour task in the same wave is still running. Single-writer and topological-integration invariants are preserved by explicit serialization (write promise-chain + integrate lock); cross-slug dependents are gated at dispatch. Proven by `tests/phase5-streaming.test.mjs` (a construction that deadlocks under the old barrier).
- A read-only scan that fails to emit `StructuredOutput` no longer aborts: it retries, falls back to a schema-less text scan (parse the JSON the model printed), and if even that fails the loop degrades to a `scan-degraded` stop + drain off the last good snapshot, returning a clean report. A genuine mid-run integrity FATAL still aborts. Drain reuses the last good snapshot too (`tests/phase4-scan-degrade.test.mjs`).
- New **`/whip-move`** operator command wraps `apply-transition.sh` for validated manual close-out (move a task, set `Integrated-At`, add a dependency) with atomic `Status:` sync (`tests/phase4-whip-move.test.sh`).
- A specialist may report `blocked_reason: dependency-missing` + `needs_task`; the orchestrator parks the task for an operator immediately, naming the task to create, instead of re-dispatching to the `Block-Count` cap. Unit-tested in `tests/phase2-scheduler.test.mjs`.
- Per-wave dispatch logging names what is in flight. The git-worktree branch registry remains the parallelism lock (one specialist per `Worktree:` slug).

## 2.2.0 — per-ticket latency

On a 337-task backlog the per-iteration scan was ~48s (`scan-backlog.sh`) + ~22s (`whip-doctor`) plus a ~50KB / ~16,800-token verbatim Opus echo, ~99% of it terminal accepted files that never change. Three fixes:

- `scan-backlog.sh --digest` emits a small scheduling snapshot (counts + actionable tasks + accepted integration candidates + compact `satisfiedDeps`), classifying the accepted folder in one batched grep+awk pass (the per-file `field()` loop was ~240–600× slower). Scan drops to ~1.6s, echo to <1KB. JS `indexTasks(tasks, satisfiedDeps)` synthesizes a terminal dep object so `isTerminal`/`depsSatisfied` bodies are unchanged.
- `whip-doctor --active-only` runs the full integrity pass over active folders and feeds accepted tasks as cheap batched stubs (advisory only, never a gate FATAL), dropping the per-iteration recheck to ~0.1s with identical FATAL/ok output.
- Deterministic shell-runner agents (scan, single writer, integrate, bootstrap, drain) run on a fast model (`SHELL_MODEL`, overridable via `shellModel`) — they only run a script and copy stdout — while specialists/reviewers/conflict-resolvers keep the session model.
- Net: per-iteration overhead fell from ~70s + a multi-minute echo to ~2–3s. Pure scheduling/terminal logic lives behind `// <scheduler-pure>` markers, unit-tested by `tests/phase2-scheduler.test.mjs`; the shell layer by `tests/phase1-doctor-hydrate.test.sh` + `tests/phase3-reliability.test.sh`.

## 2.1.0 — reliability hardening

From a multi-wave field retro where 2 of 4 runs crashed and one aborted at iteration 2:

- Every schema `agent()` call is wrapped in bounded retry + graceful degrade, so a single StructuredOutput non-emit no longer aborts a multi-hour run (writer defers, integrate stays transient, scan re-scans then aborts cleanly).
- Durable per-task `Block-Count` breaks the specialist re-dispatch livelock — a task whose real blocker is unmodeled stops being re-queued after a cap (default 3) and surfaces as `needsOperator` instead of spinning.
- `apply-transition.sh` syncs `Status:` to the destination folder atomically with the move (folder is the source of truth), so a stale Status can no longer self-inflict the `status-folder-mismatch` FATAL. The doctor now treats that mismatch as REPAIRABLE.
- Completion requires no queued unblock, so a cross-slug dep integrated in the final iteration never strands its blocked dependent. `integrate-worktree` treats an empty (no-commits-ahead) branch as terminal. Transition rows splice into the `## Transition Log` table and cap (shared `append_log_row`).

## 2.0.3 — state-machine parity

- The `/go` workflow performs the two transitions the workflow migration had dropped: **blocked→pending** unblock when deps resolve (gated on rejection-count so max-rejection redesign blocks stay for a human) and **in-progress→blocked** timeout past the operator threshold (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h, emitted by `scan-backlog.sh`). A backlog whose pending tasks are gated on blocked tasks now runs to completion instead of exiting `no-progress`.
- `/task` aborts up front when no specialist agents are installed.
- Retained dependency-target accepted tasks are emitted slim; a single garbled snapshot echo triggers one re-scan before aborting.

## 2.0.2 — scale fix

- The snapshot is a bounded working set — full task objects only for actionable tasks plus their dependency targets, while terminal/historical accepted tasks collapse into aggregate `runtimeTerminalDefault`/`runtimeTerminalOverride` counts that drive completion. The per-iteration scan no longer balloons into a backlog-sized blob the workflow agent must echo (the cause of a multi-minute stall on a ~300-task backlog).
- The doctor's new `--quiet` mode bounds the gate report to FATAL + `BREAKDOWN` + `SUMMARY`.

## 2.0.1 — self-healing

- Doctor severity is scoped to the dispatch path: accepted/historical tasks are advisory (WARN, never blocking), so a pre-2.0.0 backlog runs instead of aborting the gate.
- `/go` counts a branchless historical accepted task as terminal (runtime-derived via `hasWorktreeBranch`, no file rewrites) and never re-integrates it (`integrate-worktree` exits 4 on a missing branch).
- Parallelization is the default at planning and execution: distinct slug per independent surface (concurrent), shared slug only on real file-surface overlap, dependencies only on genuine output consumption.
- `/whip-doctor` is the integrity battery (now emitting a grouped `BREAKDOWN` line) and runs as a startup + per-iteration gate; `scan-backlog.sh` emits the read-only snapshot the scheduler runs on (now including `hasWorktreeBranch`); `.worktreeinclude` hydrates git-ignored config into fresh worktrees.

---

`/task` and `/go` are **workflow-native**: they run as dynamic workflows (`workflows/whip-task.workflow.js`, `workflows/whip-go.workflow.js`) whose loop, slug partition, dependency gate, and topological integration live in a deterministic script — so Claude's context stays flat across iterations — with the legacy single-context loop as the automatic fallback when dynamic workflows are unavailable. Worktree slugs are enforced in three layers: schema-required at decomposition → JS validation gate (kebab-case, acyclic deps, unique ids) → at dispatch the doctor self-heals a missing slug on an active task. See `content/backlog/workflow.md` for the state-machine spec.
