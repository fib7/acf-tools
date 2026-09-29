---
name: whip-focus
description: Manage the run focus, the small per-checkout list of tasks a bare `/go` runs. Set it to what you are working on now, add to it, drop from it, or clear it. It is never committed and never shared, so two people on one board have two focuses. Use when a bare `/go` should run your own tasks rather than the whole backlog, or to see what it would run.
argument-hint: "[show [--live] | set <tasks...> | add <tasks...> | drop <tasks...> | clear | path]"
allowed-tools:
  - Bash
  - Read
---

# /whip-focus: what a bare `/go` runs

The focus is a short list of the tasks *you* are working on in *this* checkout, and a bare `/go`
runs it. `/task` sets it to the tasks it just created, so the usual path (plan, `/task`, `/go`)
needs no arguments and still runs only your own work.

It lives at `.acfwhip/run/focus`, which is gitignored on purpose. A focus is one person's current
selection, not a fact about the project. Two people working the same board have two focuses, and
neither one's `/go` becomes everyone's.

## Commands

| Command | Effect |
|---|---|
| `/whip-focus` or `/whip-focus show` | Print the focus, with each task's live state and who set it when |
| `/whip-focus set <tasks...>` | Replace the focus with exactly these |
| `/whip-focus add <tasks...>` | Add these. Replaces outright when every task already in the focus is done |
| `/whip-focus drop <tasks...>` | Remove these from the focus (see the warning below) |
| `/whip-focus clear` | Remove the focus. A bare `/go` then follows the store's `bareGo` policy |
| `/whip-focus path` | Print where the focus file lives, for scripts or when you need to find it |

Every subcommand that takes tasks, `drop` included, accepts a stem, an id, a native backend id
(`MUL-4821`) or a unique stem prefix. `set` and `add` refuse the whole operation if any token is
unknown or ambiguous. `drop` only removes, so it resolves what it can and reports the tokens that
matched nothing instead of refusing.

## How to run it

One Bash call. The script resolves, validates and writes; do not hand-edit the file or build it
yourself.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-focus" <subcommand> [tasks...]
```

With no arguments, run `show --live`. The extra store read answers what an operator wants to know:
whether any of it is still worth running. Without `jq` the live read is impossible and the output
says `live state unavailable`. Pass that on, and do not imply the stems are runnable.

Report the output as-is. It is already written for a person.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | Report the output |
| 2 | Usage error; the focus belongs to a different store backend; not inside a git repo; or `.acfwhip/run/` is not gitignored and the rule could not be added | Report it. For the store mismatch the remedy is `/whip-focus clear`. For the ignore refusal, add `.acfwhip/run/` to `.gitignore` by hand: a focus is one person's state and must never be committed |
| 3 | A task did not resolve, or a prefix was ambiguous. **Nothing was written** | Show the names it printed and ask for exact ids. Never retry with a guess |
| 5 | The task store could not be read | The backend is down or misconfigured. Start with `acfw-store info` |

## Two things that are easy to get wrong

**Dropping is not pausing.** A scoped run pulls in the unmet dependencies of everything in its
scope. Drop a task that something else in the focus depends on, and it comes straight back. That is
correct: without it, the dependent could never run. To park a task, change its state:

```
/whip-move <task> draft      # paused: not dispatched, still resolvable as a dependency
/whip-move <task> archive    # cancelled: retired for good
```

The scheduler and the doctor both understand these states. A dependent of a paused task is reported
as gated, with the paused task named, instead of as a dangling reference.

**The focus holds resolved stems, not what you typed.** `set` and `add` resolve every token through
the store first and refuse the whole operation if any is ambiguous or unknown. A focus that stored
raw arguments would inherit their ambiguity: a prefix that matches one task today can match two
tomorrow. A selection that silently changes meaning is worse than no selection.

## Related

- `/go`: runs the focus when given no arguments; `/go --all` ignores it
- `/task`: sets the focus to the tasks it creates
- `/whip-move`: the pause (`draft`) and cancel (`archive`) states
- `/whip-doctor`: integrity; it explains why a task was held out of a run
