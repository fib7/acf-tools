---
name: whip-doctor
description: Backlog integrity check for ACF Whip, on every task-store backend (files, beads, multica, linear). Scans the task store and the git worktree registry for ~20 invariants (status/folder mismatch, collapsed task files, dangling or cyclic dependencies, missing/duplicate worktree slugs, orphaned worktrees, unknown agents, out-of-range Rejection Count, missing clean-checkout tokens, cross-slug glob overlap, stale in-progress). Reports FATAL/REPAIRABLE/WARN; --fix auto-repairs the REPAIRABLE class. Run it before /go, or any time the backlog looks inconsistent.
argument-hint: "[--fix]"
allowed-tools:
  - Bash
  - Read
---

# /whip-doctor

A deterministic integrity gate for the backlog, on **every** task-store backend. Always run it
through the dispatcher, never a battery script by path. The batteries are per-backend, and the
`files` one refuses to run against any other store: without that refusal it would report a clean
board with no evidence behind it, and `--fix` would delete this repo's acf-whip worktrees and their
branches.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor          # report only
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor --fix    # auto-repair REPAIRABLE, then re-scan
```

The resolved store decides where the findings come from. On the default `files` store the
dispatcher execs the full battery described below (`skills/whip-doctor/bin/doctor.sh`, through the
files adapter, which declares `doctor-complete`). On any other store it merges the adapter's own
checks with the generic graph and git battery (`skills/lib/bin/acfw-doctor-generic.sh`) into one
report with one recomputed summary. `/go` gates on the same dispatcher call at startup and runs it
again every iteration.

It prints one finding per line, then a summary:

```
SEVERITY|CODE|TASK_ID|DETAIL
SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false
```

Exit 0 when `ok=true` (no FATAL), exit 1 otherwise.

## Severity classes

- **FATAL**: must be resolved before the work it names can run. Since 3.4.0 that is narrower than
  "blocks the run": a FATAL has one of two scopes, and `/go` routes on the difference.
  - **Repo-scoped**: the checkout itself is unusable, so nothing can proceed. This covers detached
    HEAD at the repo root, an acf-whip worktree on the wrong branch, a battery that could not run
    (`doctor-unavailable`, `snapshot-unavailable`) and an unreadable backend. These abort the run,
    as they always have.
  - **Task-scoped**: one card is malformed. This covers dangling or cyclic dependencies, an
    `Assigned Agent` with no agent file, unparseable frontmatter, a task file collapsed to bare
    Transition Log rows by a concurrent write, control bytes, two tasks deriving the same worktree
    slug, a duplicate whip key, the same task in two folders with no readable survivor, a
    code-mutating task with **no `Worktree:` slug and no id to derive one from** (with an id it is
    REPAIRABLE, see below), and the adapter FATALs `missing-metadata` (linear) and `id-bijection`
    (beads). `/go` holds that task out: it is never dispatched, transitioned or integrated, and it
    still gates its dependents. The rest of the board runs, and the run reports `partial`, not
    `complete`. Before 3.4.0 one long-cancelled card could block every run for a whole team,
    including runs that never touched it.

  A finding whose task field names nothing in the snapshot gates nothing. It is reported
  (`fatalsNotGating`) and nobody acts on it.

  `--fix` refuses three FATALs on purpose. `control-bytes` and `collapsed-task-file` both mark a
  torn write, and a bootstrap `--fix` must never commit one as "healed", so each finding carries
  its recovery command instead. `dup-folder-unresolvable` means a duplicated task's `Status` names
  none of the folders it sits in. No copy can be chosen as the survivor, so `--fix` leaves every
  copy intact rather than guess.
- **REPAIRABLE**: safe to auto-fix with `--fix`, then re-scan to confirm. The class covers
  status-vs-folder mismatch (synced), a missing `Worktree:` slug that can be **derived from the
  task id** (written, with a collision check), `Rejection Count` or `Block-Count` out of range
  (clamped), bracketed dependency tokens (unwrapped), the same task in two folders (the copy
  matching its `Status` is kept), and an orphaned `.worktree/<slug>` with no live task (removed).
  The derived slug is the common case: do not hand-edit a slug the doctor would derive better. An
  accepted task whose change has not landed still counts as live, so its worktree survives. It is
  often the only copy of the deliverable.

  **This class is `files`-only.** On every other backend the graph and git half of the report
  comes from the generic battery, which never changes anything: out-of-range counters and orphaned
  worktrees show up there as WARN and are not repaired. On those backends `--fix` repairs only what
  the adapter itself repairs: `status-drift`, `bad-rejections`, `bad-blocks`. Reaping stays with
  `files` on purpose, because on an API-backed store the worktree is often the only copy of an
  unintegrated deliverable.
- **WARN**: reported, never blocks. The class covers an accepted task missing the
  `clean-checkout | ok` token, a task lingering in `in-review/`, an in-progress task past the timeout
  (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h), two pending tasks in different slugs that declare
  overlapping `Touches Globs` (possibly mis-partitioned), a duplicate ID, a dependency on a paused
  or retired task (`dep-inactive`: gated, with the remedy), a whip state outside the vocabulary
  (`invalid-state`: quarantined by construction), and a **native hold**: a card a human parked with
  a native `blocked`/`cancelled` status while its whip state still reads runnable.

  A native hold is reported and never repaired. `/go` runs `--fix` at bootstrap, so repairing it
  would un-park every card the team parked, on every run. Park a task where the scheduler
  understands it instead: `/whip-move <task> draft`. On multica the finding cannot tell a human
  hold from a stale write, because whip projects its own `blocked` state onto the native `blocked`
  status, so it names the re-sync command for the stale case and repairs neither. Linear keys on
  the state *type* and has no such ambiguity.

  Also WARN: `parked-task-worktree` (the worktree of a task you paused or retired; it is never
  reaped, so nothing you parked is destroyed, and you remove it by hand once you are sure),
  `orphaned-worktree-dirty` (no live task but uncommitted changes; never removed automatically),
  `duplicate-derived-slug` where one copy is accepted, `dup-folder-untracked`, `dirty-trunk-root`
  (tracked files modified at the root outside the task store and `docs/cycles/`, so a specialist may
  have escaped its worktree; plans are edited at the root by design and never count),
  `trunk-unpushed`, and `accepted-branchless-unverified`.

**Ownership scope (worktree checks).** The doctor manages **only** worktrees in the branch
namespace it owns, `<ACFW_BRANCH_PREFIX>/<slug>` (default `worktree/<slug>`, configurable in
`.backlog/.acfw-config`). A directory under `.worktree/` that is on any other branch, detached
(mid-rebase, say), or not a registered worktree is **foreign**, such as your own parallel research
or benchmark work. The doctor leaves it alone: no `orphaned-worktree`, no `worktree-wrong-branch`,
and `--fix` never removes it. Both the wrong-branch FATAL and the orphan reaper apply only to
worktrees in acf-whip's branch namespace.

## How to respond

1. Run the report. If `ok=true`, say so and stop.
2. If there are only REPAIRABLE and WARN findings, summarize them and offer `--fix` for the
   repairables.
3. If there are FATAL findings, list them plainly. A repo-scoped FATAL stops `/go` from
   dispatching anything; a task-scoped one holds that task out until it is fixed. The legacy loop
   (no `Workflow` tool) is stricter and refuses on any FATAL. Most FATALs are task-engineer errors
   (a missing slug, bad dependencies): route them back to `/task`, or fix the frontmatter directly
   at the repo root.
4. After `--fix`, report what was repaired and the post-repair summary.

The doctor plans and applies repairs only when invoked with `--fix`, and only for the REPAIRABLE
class. Inside the `whip-go` workflow the doctor agent only reports and the single backlog writer
applies the repairs, so the backlog keeps exactly one writer.

---

**Last Updated**: 2026-09-29
