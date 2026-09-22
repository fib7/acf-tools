---
name: whip-doctor
description: Backlog integrity check for ACF Whip, on every task-store backend (files, beads, multica, linear). Scans the task store and the git worktree registry for ~20 invariants (status/folder mismatch, collapsed task files, dangling or cyclic dependencies, missing/duplicate worktree slugs, orphaned worktrees, unknown agents, stray Integrated-At, out-of-range Rejection Count, missing clean-checkout tokens, cross-slug glob overlap, stale in-progress). Reports FATAL/REPAIRABLE/WARN; --fix auto-repairs the REPAIRABLE class. Run it before /go, or any time the backlog looks inconsistent.
argument-hint: "[--fix]"
allowed-tools:
  - Bash
  - Read
---

# /whip-doctor

Deterministic backlog integrity gate, on **every** task-store backend. Always invoke it through
the dispatcher, never a battery script by path — the batteries are per-backend and the `files` one
refuses to run against any other store (it would otherwise report a clean board against no evidence,
and `--fix` would delete this repo's acf-whip worktrees and their branches).

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor          # report only
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor --fix    # auto-repair REPAIRABLE, then re-scan
```

Where the findings come from depends on the resolved store. On the default `files` store the
dispatcher execs the full battery documented below (`skills/whip-doctor/bin/doctor.sh`, via the
files adapter, which declares `doctor-complete`). On any other store it merges that adapter's
store-native checks with the generic graph/git battery (`skills/lib/bin/acfw-doctor-generic.sh`)
into one report with one recomputed summary. `/go` gates on the same dispatcher call at startup and
rechecks it every iteration.

It prints one finding per line, then a summary:

```
SEVERITY|CODE|TASK_ID|DETAIL
SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false
```

Exit 0 when `ok=true` (no FATAL), exit 1 otherwise.

## Severity classes

- **FATAL** — must be resolved before the work it names can run. Since 3.4.0 that is a
  narrower claim than "blocks the run", because a FATAL has two scopes and `/go` routes on
  the difference:
  - **Repo-scoped** — the checkout itself is unusable, so nothing can proceed: detached HEAD
    at the repo root, an acf-whip worktree on the wrong branch, a battery that could not run
    (`doctor-unavailable`, `snapshot-unavailable`), a backend that is unreadable. These abort
    a run exactly as they always did.
  - **Task-scoped** — one card is malformed: dangling or cyclic dependencies, an
    `Assigned Agent` with no agent file, a code-mutating task with no `Worktree:` slug,
    unparseable frontmatter, a task file collapsed to bare Transition Log rows by a concurrent
    write, control bytes, a duplicate whip key, the same task in two folders with no readable
    survivor. `/go` HOLDS OUT that task — never dispatched, never transitioned, never
    integrated, and still gating its dependents — and runs the rest of the board. It reports
    `partial`, not `complete`. Before 3.4.0 one long-cancelled card could block every run for
    a whole team, including runs that never touched it.

  A finding whose task field names nothing in the snapshot gates nothing at all: it is
  reported (`fatalsNotGating`) and acted on by no one. Two FATALs are deliberately **not**
  `--fix`-able — `control-bytes` and `collapsed-task-file`. Both mark a torn write, and a
  bootstrap `--fix` must never commit one as "healed"; the finding carries the recovery
  command instead. Nor is `dup-folder-unresolvable`: when a duplicate's `Status` names none
  of the folders it is in, no copy can be chosen as the survivor, so `--fix` refuses and
  leaves every copy intact rather than guessing.
- **REPAIRABLE** — safe to auto-fix with `--fix`, then re-scan to confirm: status-vs-folder
  mismatch (synced), `Rejection Count` or `Block-Count` out of range (clamped), bracketed
  dependency tokens (unwrapped), the same task present in two folders (kept the one matching
  its `Status`), an orphaned `.worktree/<slug>` with no live task (removed — but an accepted
  task whose change has NOT landed still counts as live, so its worktree survives; it is
  often the only copy of the deliverable).

**Ownership scope (worktree checks).** The doctor manages **only** worktrees on the
namespace it owns — `<ACFW_BRANCH_PREFIX>/<slug>` (default `worktree/<slug>`), configurable in
`.backlog/.acfw-config`. A directory under `.worktree/` on any other branch, detached (e.g.
mid-rebase), or that is not a registered worktree is treated as **foreign** — your own
parallel research/benchmark work — and is left completely alone: no `orphaned-worktree`, no
`worktree-wrong-branch`, and never removed by `--fix`. Both the wrong-branch FATAL and the
orphan reaper apply only to worktrees in acf-whip's branch namespace.
- **WARN** — surfaced, never blocks: accepted task missing the `clean-checkout | ok`
  token, a task lingering in `in-review/`, an in-progress task past the configurable
  timeout (`ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h), two pending tasks in different
  slugs that declare overlapping `Touches Globs` (possible mis-partition), a duplicate ID,
  a dependency on a paused/retired task (`dep-inactive` — gated, with the remedy), a whip
  state outside the vocabulary (`invalid-state` — quarantined by construction), and a
  **native hold**: a card a human parked with a native `blocked`/`cancelled` status while
  its whip state still reads runnable. That last one is reported and never repaired —
  `/go` runs `--fix` at bootstrap, so repairing it would un-park every card the team parked,
  on every run. Park a task where the scheduler understands it instead:
  `/whip-move <task> draft`.

## How to respond

1. Run the report. If `ok=true`, say so and stop.
2. If only REPAIRABLE/WARN findings, summarize them. Offer `--fix` for the repairables.
3. If FATAL findings, list them plainly. FATAL must be resolved before `/go` will dispatch.
   Most FATALs are task-engineer errors (missing slug, bad deps) — route them back to
   `/task` or fix the frontmatter directly at the repo root.
4. After `--fix`, report what was repaired and the post-repair summary.

The doctor **plans and applies** repairs only when invoked with `--fix` and only for the
REPAIRABLE class; inside the `whip-go` workflow the doctor-agent reports and the single
backlog-writer applies, preserving the single-writer invariant.

---

**Last Updated**: 2026-05-28
