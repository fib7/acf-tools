---
name: whip-focus
description: Manage the run focus — the small, per-checkout list of tasks a bare `/go` runs. Set it to what you are working on now, add to it, drop from it, or clear it. Never committed, never shared, so two people on one board have two focuses. Use when a bare `/go` should run YOUR tasks rather than the whole backlog, or to see what it would run.
argument-hint: "[show | set <tasks...> | add <tasks...> | drop <tasks...> | clear]"
allowed-tools:
  - Bash
  - Read
---

# /whip-focus — what a bare `/go` runs

The focus is a small list of the tasks *you* are working on in *this* checkout. A bare `/go` runs it.
`/task` sets it to the tasks it just created, so the ordinary path — plan, `/task`, `/go` — needs no
arguments at all and still runs only your own work.

It lives at `.acfwhip/run/focus`, which is gitignored. That is not an implementation detail: a focus
is one person's current selection, never a fact about the project. Two people working the same board
have two focuses, and neither one's `/go` becomes everyone's.

## Commands

| Command | Effect |
|---|---|
| `/whip-focus` or `/whip-focus show` | Print the focus, with each task's live state and who set it when |
| `/whip-focus set <tasks...>` | Replace the focus with exactly these |
| `/whip-focus add <tasks...>` | Add these. Replaces outright when every task already in the focus is done |
| `/whip-focus drop <tasks...>` | Remove these from the focus (see the warning below) |
| `/whip-focus clear` | Remove the focus. A bare `/go` then follows the store's `bareGo` policy |

Tasks may be named by stem, id, native backend id (`MUL-4821`), or a unique stem prefix.

## How to run it

One bash call. The script does the resolution, the validation and the writing; do not hand-edit the
file, and do not construct it yourself.

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-focus" <subcommand> [tasks...]
```

With no arguments, run `show --live` — the extra store read answers the question an operator actually
has, which is whether any of it is still worth running.

Report the output as-is. It is already written for a person.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | Report the output |
| 2 | Usage error, or the focus belongs to a different store backend | Report it; for the store mismatch the remedy is `/whip-focus clear` |
| 3 | A task did not resolve, or a prefix was ambiguous — **nothing was written** | Show the names it printed and ask for exact ids. Do NOT retry with a guess |
| 5 | The task store could not be read | The backend is down or misconfigured; `acfw-store info` is the place to start |

## Two things that are easy to get wrong

**Dropping is not pausing.** A scoped run pulls in the unmet dependencies of everything in its scope,
so a task you drop that something else in the focus depends on comes straight back — correctly, since
otherwise that dependent could never run. To actually park a task:

```
/whip-move <task> draft      # paused: not dispatched, still resolvable as a dependency
/whip-move <task> archive    # cancelled: retired for good
```

Both are states the scheduler and the doctor understand. A dependent of a paused task is reported as
gated, with the paused task named — not as a dangling reference.

**The focus holds resolved stems, not what you typed.** `set` and `add` resolve every token through
the store first and refuse the whole operation if any is ambiguous or unknown. A focus holding raw
arguments would inherit every ambiguity of the thing typed — a prefix that matches one task today and
two tomorrow — and a selection that silently changes meaning is worse than no selection.

## Related

- `/go` — runs the focus when given no arguments; `/go --all` ignores it
- `/task` — sets the focus to the tasks it creates
- `/whip-move` — the pause (`draft`) and cancel (`archive`) states
- `/whip-doctor` — integrity; a task held out of a run is explained there
