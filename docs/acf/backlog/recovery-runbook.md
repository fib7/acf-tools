<!-- acf-whip-artifact: content/backlog/recovery-runbook.md v3.5.0 -->
# Recovery Runbook

Operator reference for an acf-whip backlog that will not run, or a `/go` run that stopped short.

**First rule: never hand-edit task state.** Editing `Status:`, the Transition Log, or `Integrated-At:` with `sed`/`perl` is how a backlog ends up with a doctor FATAL. Use `/whip-move` (one task) or `/whip-doctor --fix` (the repairable class).

**Second rule: re-running `/go` is the resume.** git and `.backlog/` are the only durable state.

---

## Diagnose first

```bash
/whip-doctor          # report only
/whip-doctor --fix    # apply the REPAIRABLE class, then re-scan
```

Findings are `SEVERITY|CODE|TASK_ID|DETAIL`, then `BREAKDOWN|<SEV>|code=count,…`, then `SUMMARY|fatal=N|repairable=N|warn=N|ok=true|false`.

**A FATAL has two scopes, and `/go` routes on the difference (3.4.0).**

- **Repo-scoped** (`detached-head`, `worktree-wrong-branch`, `doctor-unavailable`,
  `snapshot-unavailable`, an unreadable store): the checkout itself is unusable, so nothing can
  proceed. These abort the run, as every FATAL did before 3.4.0.
- **Task-scoped**: one card is malformed. `/go` **holds out that task** and runs the rest of the
  board. A held-out task is never dispatched, transitioned or integrated; it still gates its
  dependents, and its worktree slug stays reserved. The run ends `partial`, with `completed: false`
  and `heldOut[]` naming what it refused to touch.

A finding whose task field names nothing in the snapshot gates nothing. `/go` reports it under
`fatalsNotGating` and does not act on it.

**One exception**: the legacy markdown loop (no dynamic workflows) still refuses to run on any FATAL.
It has no index to attribute a finding to a task and nowhere to record what it held out, and guessing
by hand is the failure the classification exists to remove.

Severity also depends on the dispatch path. A task in `accepted/` is terminal, so its structural defects are **advisory (WARN), never blocking**. Only an active task (`pending`, `in-progress`, `completed`, `in-review`) can draw a task-scoped FATAL.

---

## FATAL: fix before the task it names can run

| Code | Meaning | Recovery |
|------|---------|----------|
| `detached-head` | No branch checked out at the repo root. | `git checkout <trunk-branch>` |
| `unparseable-frontmatter` | Task file is missing `ID` and/or `Status`. | Restore both fields by hand, then `/whip-doctor`. |
| `control-bytes` | Raw NUL bytes (`0x00`) in a task file, so no field lookup can be trusted. | `LC_ALL=C tr -d '\000' < f > f.tmp && mv f.tmp f`, then re-run `/whip-doctor`. See below. |
| `collapsed-task-file` | A concurrent write destroyed the task document. Only transition-log rows are left. | `git checkout HEAD -- .backlog/<state>/<stem>.md`, then re-run `/whip-doctor`. See below. |
| `dangling-dep` | Task depends on an id with no task file. | Create the missing task, or drop the dep. |
| `cyclic-deps` | Task participates in a dependency cycle. | Break the cycle: remove one edge with an edit to `Dependencies`, or split the task. |
| `cross-slug-dep-not-integrated` | A dispatched task's cross-slug dep is not yet on trunk. | Let `/go` integrate the dep first. If the dep's change is already on trunk, see `accepted-branchless-unverified` below. |
| `unknown-agent` | `Assigned Agent` has no `.claude/agents/<name>.md`. | `/whip-add-agents`, or reassign the task. |
| `worktree-wrong-branch` | `.worktree/<slug>` is on the wrong branch. | `git worktree remove --force .worktree/<slug>`; `/go` recreates it. |

`duplicate-id` is **WARN**, not FATAL: it quarantines that id and the run continues. De-dup when convenient.

### On `control-bytes`

Only NUL (`0x00`) is flagged. A NUL makes `grep` and `file` treat the task file as binary, so a field lookup returns nothing even though the field is there: `grep -E '^a'` on a file containing a NUL exits 1 and prints nothing. Other C0 bytes pasted in from terminal output (ESC, formfeed) do no harm to the grep-based frontmatter parser, and the doctor ignores them on purpose.

Count the NULs in a suspect file:

```bash
LC_ALL=C tr -dc '\000' < f | wc -c
```

Strip them with `tr` (above), not with your editor: Read renders a NUL invisibly, Edit cannot match it in `old_string`, and `grep $'\x00'` truncates the pattern at the NUL.

### On `collapsed-task-file`

The document is gone and only transition-log rows remain, usually one. The doctor reports this apart from `unparseable-frontmatter` because the recovery is different: no metadata field is missing, the *whole file* was overwritten, and the content is still in git one commit back.

Cause: `append_log_row` performs a read-modify-write. Before 3.2.2 it could read a file that another process had momentarily emptied, and then write only its own row back. `apply-transition.sh` committed the result. 3.2.2 makes both steps refuse, so a file collapsed this way predates the fix (or was destroyed by something outside acf-whip).

Restore it from the last commit that still has it:

```bash
git log --all --oneline -- '.backlog/*/<stem>.md'
git checkout <sha> -- .backlog/<state>/<stem>.md
```

Two things to get right afterwards:

- **`Status` must match the folder the file now sits in.** The restored copy carries whatever state it had at that commit. Use `/whip-move` rather than editing it by hand.
- **Commit the repair immediately.** An uncommitted `.backlog` repair at the trunk root is invisible to `dirty-trunk-root` (which excludes `.backlog/` by design), so nothing warns you before something else overwrites it.

Any transition rows written between the restored commit and now are lost. Re-insert them under the separator that follows the `## Transition Log` heading, not under the first `|---|` in the file, which belongs to a different table.

`--fix` does not repair it, for the same reason as `control-bytes`: restoring from `HEAD` would silently discard the clean-checkout token row, which is uncommitted by design, and a bootstrap `--fix` must never commit a torn write as "healed".

---

## REPAIRABLE: `/whip-doctor --fix` handles these

| Code | Fix applied |
|------|-------------|
| `status-folder-mismatch` | Rewrites `Status:` to match the folder (the folder is the source of truth). |
| `missing-worktree-slug` | Derives a slug from the task id and writes it in. |
| `bracketed-deps` | Strips legacy `[a, b]` formatting from `Dependencies`. |
| `rejection-count-out-of-range` | Clamps to `[0, 5]`. |
| `block-count-out-of-range` | Clamps to `[0, 9]`. A value at the cap is valid: the task is parked for an operator. |
| `dup-folder` | Deletes the copies whose folder disagrees with `Status:`. |
| `orphaned-worktree` | Removes a `.worktree/<slug>` with no live task, and its branch. |

---

## WARN: advisory, nothing blocks, but read them

| Code | Meaning | Acknowledge by |
|------|---------|----------------|
| `orphaned-worktree-dirty` | The reaper **skipped** a dirty orphan worktree rather than destroying uncommitted work. | Inspect it, salvage anything you want, then `git worktree remove --force .worktree/<slug>`. |
| `accepted-branchless-unverified` | An accepted code task has no worktree branch **and** no ledger marker. Its deliverable may or may not be on trunk. | Check that the deliverable is on trunk, then clear the finding the way your backend allows (below). It gates nothing: the scheduler already treats a branchless accepted task as terminal. |
| `dirty-trunk-root` | Tracked files are modified or staged at the shared root, outside `.backlog/` and `docs/cycles/`. A specialist may have escaped its worktree. | **Commit or stash them now.** An integration that changes one of those paths overwrites your copy. It then prints a WARN (also in `/go`'s report, under `integrationWarnings`) with a snapshot commit and a `Recover:` command, `git -C <root> diff --binary <observed> <snapshot> \| git -C <root> apply -3`, which re-applies only your edits on top of the landed content (a clash leaves conflict markers; the result is staged). `git show <snapshot>:<path>` shows one path as it was. `docs/cycles/` is not counted: plans are edited at the root by design, and no landing can overwrite them, because the integrator drops every task's `docs/cycles/` edits. |
| `trunk-unpushed` | Local trunk is ahead of its remote. LP-CAS lands on the **local** trunk and never pushes, by design. | `git push` when ready. |
| `duplicate-id` | One `ID` appears in two task files. Each runs on its own slug and ledger key, so there is no integration collision. | De-dup the id. |
| `stale-in-progress` | Dispatched longer ago than the timeout. | Nothing. `/go` recovers it (see below). |
| `lingering-in-review` | Stuck in `in-review/`; the reviewer never terminated it. | Re-run `/go`; it is re-reviewed. |
| `missing-clean-checkout-token` | Accepted without a `clean-checkout \| ok` row. | Nothing; historical tasks predate the token. |
| `cross-slug-glob-overlap` | Two pending tasks on different slugs declare the same glob, which may mean the partition is wrong. | Merge the slugs, or narrow `Touches Globs`. |

---

## Integration: `integrate-lpcas` exit codes

The integrator changes **only git**: the trunk ref and a disposable integration worktree. It never moves a task file; `/go` owns every `.backlog/` move.

| Exit | Verdict | What it means | Operator action |
|------|---------|---------------|-----------------|
| 0 | `integrated` / `already-integrated` | Change + ledger marker are on trunk (or an idempotent skip). | None. |
| 3 | `quarantine` | Candidate is malformed (not single-parent) or poison (writes the ledger namespace). | The task is parked, alone. Inspect `refs/acfw/patch/<key>`. Other tasks are unaffected. |
| 4 | `no-candidate` | No `refs/acfw/patch/<key>`: a historical task already on trunk. | None; terminal skip, never retried. |
| 6 | `quality-fault` | The union gate failed on the candidate tree. A real quality reject. | `/go` moves the task `accepted → rejected` and increments Rejection Count. Fix the code. |
| 7 | `resolver-needed` | Cherry-pick conflict; the worktree is left mid-pick for a resolver. | `/go` dispatches the resolver automatically, then resumes with `--post-resolver`. |
| 9 | `mechanism` | Unresolved conflict, broken resolution syntax, or worktree error. Not a quality reject. | Retried next pass; the task stays accepted. |
| 11 | `cas-lost` | Trunk moved or rewound between observe and land. | Transient; retried next pass. |
| 12 | `stall` | Trunk unobservable (detached/missing). | Check out the trunk branch at the repo root. |
| 99 | git lock | `.git/index.lock` held past the backoff. | Transient; retried next pass. |

Only exit 6 consumes the rejection budget. A conflict (7) or mechanism fault (9) never does.

A dispatched resolver may **only** edit conflicted files and `git add` them. It must never run `cherry-pick --continue`, `reset`, or `rebase`: the integrator owns the commit, the gate, and the land.

---

## Crash and interrupt recovery

Re-run `/go`. It re-scans from disk and rebuilds the same plan, with no manual cleanup:

| Task state after the crash | What `/go` does |
|----------------------------|-----------------|
| `in-progress`, fresh | Re-dispatched on the first iteration. |
| `in-progress`, stale (≥ timeout) | Self-routes `timeout → blocked → unblock → pending`, **without** consuming Block-Count. |
| `accepted`, unintegrated | Re-enters the integration queue; `integrate-lpcas` is idempotent. |
| `in-review` | Re-reviewed. |

The timeout is **8h** by default; precedence is env `ACFW_INPROGRESS_TIMEOUT_HOURS` > `.backlog/.acfw-config` > 8.

Only when a run stops for good and one or two tasks need closing by hand:

```bash
/whip-move <stem> accepted --integrated-at <sha> --reason "verified by hand"   # files store only
/whip-doctor
```

---

## Run lock

`/go` refuses to start while `.backlog/.acfw-run.json` was last written less than **30 minutes** ago, because a live `/go` rewrites that heartbeat every iteration. **Never run two `/go` against one repo**: they race on the trunk index and the worktree branch registry.

A run that finishes cleanly removes the lock itself. After a crash the lock expires on its own once 30 minutes pass without a heartbeat. To clear it sooner: `rm .backlog/.acfw-run.json`.

On a non-files task store (`ACFW_STORE` set in `.acfwhip/config`) the lock lives at
`.acfwhip/run/acfw-run.json` instead, with the same 30-minute window and the same `rm` override.
`bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" info` prints the active path (the `runLock`
field).

---

## Parking a task away from automation

```
/whip-move <task> draft      # paused — the human gate
/whip-move <task> archive    # cancelled — retired for good
/whip-move <task> pending    # bring it back
```

This works on every backend, not just `files`. Both states are left out of every scan and out of the
completion denominator, but they still resolve as dependencies. A task that depends on a paused one
is reported as *gated, and here is why*, not as a dangling reference.

**The task's worktree and branch survive.** `/whip-doctor --fix` never reaps the worktree of a parked
or retired task. It reports `WARN|parked-task-worktree` and leaves the worktree alone, because that
directory is often the only copy of work that has not landed. Remove it by hand when you are sure:
`git worktree remove .worktree/<slug>` then `git branch -D worktree/<slug>`.

Two things look like they should park a task and do not:

- **Dropping it from a run focus.** A scoped run pulls in the unmet dependencies of everything in its
  scope, so a dropped task that something else in the focus needs comes straight back. That is
  correct: otherwise the dependent could never run. A focus is a selection, not a state.
- **Setting a native `blocked`/`cancelled` status** on an API-backed board. Whip reads its own
  metadata, not the native status, so the card stays runnable. The doctor reports this as
  `WARN|native-hold` and, since 3.4.0, leaves the native status alone. Before 3.4.0 every `/go`
  bootstrap "repaired" it, silently un-parking every card parked this way.

---

## Integration truth

A task is integrated **iff** its in-tree ledger marker is present in the tree of the live trunk tip:

```bash
. "${CLAUDE_PLUGIN_ROOT}/skills/lib/acfw-git.sh"
acfw_is_integrated "$(git rev-parse --show-toplevel)" HEAD <task-stem> && echo integrated
```

Only the integrator writes the marker (`.acfwhip/integrated/<shard>/<key>.json`), in the same commit as the change. Because the two land together, a marker can never claim work that is absent.

### Clearing `accepted-branchless-unverified`

The finding means integration was never *recorded*, not that the work is missing. Check first:

```
git log --oneline <trunk> -- <a path the task touched>
```

**If the change is not on trunk**, the work was lost: move the task back (`/whip-move <stem> pending`)
and let `/go` run it again. That is the case this WARN exists to catch.

**If the change is on trunk**, only a ledger marker clears it, because the marker is the oracle on
every backend. On `files` you can ack it with `/whip-move <stem> accepted --integrated-at <sha>`
instead, since the doctor's gate there accepts either. Every other backend has no stamp, because no
adapter maps `Integrated-At`. Write the marker by hand, on trunk:

```bash
KEY=<stem>
SHARD=$(printf '%s' "$KEY" | git hash-object --stdin | cut -c1-2)
mkdir -p ".acfwhip/integrated/$SHARD"
printf '{"key":"%s","patch":"","patch_parent":"","observed_trunk":"%s","slug":"%s"}\n' \
  "$KEY" "$(git rev-parse HEAD)" "<the task's Worktree slug>" \
  > ".acfwhip/integrated/$SHARD/$KEY.json"
git add ".acfwhip/integrated/$SHARD/$KEY.json"
git commit -m "chore: record out-of-band integration of $KEY"
```

Only do this for a change you have *seen* on trunk. Every later run believes the marker, so a marker
for work that never landed turns a visible warning into a silent hole: the task's dependents dispatch
as if their prerequisite shipped.

**Or leave it.** It is advisory, it gates nothing, and a standing WARN on a handful of historical
tasks is a fair price for not writing ledger entries you are unsure of.

**`Integrated-At:` is display and operator-ack metadata, never the oracle.** The integrator neither reads nor writes it. Setting it lands no code; clearing it un-integrates nothing. Its one functional use is the ack above: the doctor's cross-slug dep gate accepts either a ledger marker **or** an `Integrated-At:` stamp, so stamping a verified branchless task with `/whip-move --integrated-at <sha>` clears the gate for its dependents. Stamp only what you have verified is on trunk.
