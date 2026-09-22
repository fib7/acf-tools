---
name: whip-move
description: Safely move ONE acf-whip backlog task between state folders — including `draft` to PAUSE it and `archive` to CANCEL it, the supported way to park work on every backend (or set Integrated-At / add a Dependency) without hand-editing files. Resolves a task by stem/id and runs the validated apply-transition.sh writer — atomic Status sync + Transition Log row + commit — so manual close-out after a crash is a one-liner, not raw perl/sed. Use for last-mile reconciliation; run /whip-doctor after.
argument-hint: "<task> <state: pending|in-progress|completed|in-review|accepted|rejected|blocked|draft|archive> [--reason ..] [--integrated-at SHA] [--add-dep ID]"
allowed-tools:
  - Bash
  - Read
---

# /whip-move

Works on every task-store backend: on the default `files` store it resolves `.backlog/<state>/`
files and runs the apply-transition writer; on any other configured store (`ACFW_STORE` in
`.acfwhip/config`) it routes the same surface through the `acfw-store` dispatcher
(`read`/`update-field`/`transition`) — same flags, same output shapes.

Operator-facing wrapper around the single `.backlog/` writer primitive
(`${CLAUDE_PLUGIN_ROOT}/skills/go/bin/apply-transition.sh`). `/go` uses that primitive
internally; `/whip-move` surfaces it for **manual** close-out — e.g. finishing the last
1–2 tasks after a `/go` run stopped early, or reconciling a backlog by hand — so you never
hand-edit `Status:`, the Transition Log, or `Integrated-At` with `perl`/`sed` (one slip
there is a doctor FATAL).

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/whip-move/bin/whip-move.sh" <TASK> <TO_STATE> [flags]
```

- `<TASK>` — task stem, id, or a **unique prefix** (resolved across all `.backlog/<state>/`
  folders; ambiguous matches are refused with the candidate list).
- `<TO_STATE>` — `pending | in-progress | completed | in-review | accepted | rejected | blocked |
  draft | archive`. Pass the task's **current** state to apply field edits without moving it.

  **`draft` is PAUSE and `archive` is CANCEL** — the supported way to park work on every backend.
  Both are inert to the scheduler (nothing dispatches, transitions or integrates them) while staying
  resolvable as dependencies, so a dependent is reported as *gated, and here is why* rather than as a
  dangling reference. Reach for these instead of the two things that look like they should work and
  do not: dropping a task from a run focus does not pause it (a scoped run pulls in unmet
  dependencies, so it comes straight back), and setting a native `blocked`/`cancelled` status on an
  API-backed board does not pause it either — whip reads its own metadata, not the native status.
  Bring a paused task back with `pending`.

### Flags

| Flag | Effect |
|------|--------|
| `--reason "..."` | Transition Log note (default: `manual operator move`). |
| `--integrated-at SHA` | Set `- **Integrated-At**: SHA` (typical with `accepted`). |
| `--add-dep ID` | Append `ID` to the task's `- **Dependencies**:` list. |
| `--agent NAME` | Transition Log actor (default: `operator`). |

All edits land in the **same commit** as the move; the folder is the source of truth and
`Status:` is synced to it atomically (so a transition can never leave `Status` stale).
Idempotent: moving a task already in the target state is a no-op.

## Examples

```bash
# accept a task and stamp where it integrated
bash .../whip-move.sh test-041-promote-core-journeys accepted --integrated-at a042d461 --reason "verified by hand"

# block a task and record the missing dependency it actually needs
bash .../whip-move.sh bug-061-reanalyze-review-loop blocked --add-dep fixture-readiness --reason "needs clean-GO fixture task"

# just set Integrated-At on an already-accepted task (no move)
bash .../whip-move.sh docs-010-journey-docs-truth accepted --integrated-at 9f3c2aa
```

## After

Always run `/whip-doctor` to confirm the backlog is consistent:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor
```

`/whip-move` is for **one** task at a time. For bulk progress, use `/go`.
