---
name: whip-move
description: Move one acf-whip backlog task to another state without hand-editing it. `draft` pauses a task and `archive` cancels it; the two are the supported way to park work on every backend. It can also set Integrated-At (files store only) or add a Dependency. Resolves the task by stem or id and runs the validated writer (on files, apply-transition.sh, which does the Status sync, Transition Log row and commit together), so a manual close-out after a crash is one command, not raw perl/sed. Use it for last-mile reconciliation, then run /whip-doctor.
argument-hint: "<task> <state: pending|in-progress|completed|in-review|accepted|rejected|blocked|draft|archive> [--reason ..] [--integrated-at SHA] [--add-dep ID]"
allowed-tools:
  - Bash
  - Read
---

# /whip-move

Moves one task to another state without anyone editing its file. `/go` changes task state through
a single writer primitive (`${CLAUDE_PLUGIN_ROOT}/skills/go/bin/apply-transition.sh` on the `files`
store), and `/whip-move` hands that writer to an operator for **manual** close-out: finishing the
last one or two tasks after a `/go` run stopped early, or reconciling a backlog by hand. Use it
instead of editing `Status:`, the Transition Log or `Integrated-At` with `perl`/`sed`: one slip there
is a doctor FATAL.

It works on every task-store backend. On the default `files` store it resolves `.backlog/<state>/`
files and runs the apply-transition writer. On any other store configured with `ACFW_STORE` in
`.acfwhip/config`, it routes the same commands through the `acfw-store` dispatcher
(`read`/`update-field`/`transition`), with the same flags and the same output shapes.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/whip-move/bin/whip-move.sh" <TASK> <TO_STATE> [flags]
```

- `<TASK>`: a task stem, id or **unique prefix**, resolved across all `.backlog/<state>/` folders.
  An ambiguous match is refused with the list of candidates.
- `<TO_STATE>`: `pending | in-progress | completed | in-review | accepted | rejected | blocked |
  draft | archive`. Pass the task's **current** state to apply field edits without moving it.

  **`draft` is PAUSE and `archive` is CANCEL.** They are the supported way to park work on every
  backend. The scheduler never dispatches, transitions or integrates a task in either state, but
  both stay resolvable as dependencies, so a dependent is reported as gated, with the reason,
  instead of as a dangling reference. Two other moves look like they should pause a task and do
  not. Dropping a task from a run focus does not pause it: a scoped run pulls in unmet
  dependencies, so it comes straight back. Setting a native `blocked`/`cancelled` status on an
  API-backed board does not pause it either, because whip reads its own metadata, not the native
  status. Bring a paused task back with `pending`.

### Flags

| Flag | Effect |
|------|--------|
| `--reason "..."` | Transition Log note (default: `manual operator move`). |
| `--integrated-at SHA` | Set `- **Integrated-At**: SHA` (typical with `accepted`). **`files` store only.** On every other backend `/whip-move` refuses it up front with exit 2: no adapter maps the field, and the in-tree LP-CAS ledger is the sole integration oracle. |
| `--add-dep ID` | Append `ID` to the task's `- **Dependencies**:` list. |
| `--agent NAME` | Transition Log actor (default: `operator`). |

On `files`, every edit lands in the **same commit** as the move. The folder is the source of truth
and `Status:` is synced to it atomically, so a transition can never leave `Status` stale. Moving a
task to the state it is already in, with no field edits, is a no-op.

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
