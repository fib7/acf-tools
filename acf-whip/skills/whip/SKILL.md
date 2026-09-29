---
name: whip
description: "The front door of the acf-whip cycle (PLAN, DECOMPOSE, BUILD, VERIFY, RETRO). Bare /whip says where you are and prints the one command to run next. /whip \"<goal>\" sends small work straight to /task and risky work to a plan you approve with one yes, which then starts /task --plan itself. /whip <file.md> adopts a plan written anywhere else. Spec tools (plan reviewers and workbenches) run through it too: --review, --push, --pull, --from, --tools. Use it to start work, to find out what to run next, or to approve, amend or abandon a plan."
argument-hint: "[\"<goal>\" | <plan.md> | <cycle-id> | --abandon [<cycle-id>] | --review | --push | --pull | --from <tool> <ref> | --tools [add <name>]]   (no args = where am I)"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Skill
  - Agent
  - Task
  - Workflow
---

# /whip: where you are, and the one command to run next

## Stop rules (read these first; they still hold after compaction)

1. **Print `acfw-cycle` and `acfw-spec` output verbatim.** Stdout and stderr, as the tool shows
   them. Do not summarize, reorder, reword, or add a stage, a mark, a finding or a command of your
   own.
2. **On a non-zero exit of either script, print its output and stop.** Do not retry with other
   flags, do not do the refused step another way, do not dispatch around a refusal. Three
   exceptions, all spelled out below: `acfw-spec` exit 21 is a work order (**Agent work orders**);
   a plan review that could not run still lets the card render (**Show the card**, step 3); and
   `init` refused with `already exists` for a cycle that is already abandoned or closed gets one
   more try under a new slug (**Goal**, step 1).
3. **Never derive a stage in prose.** The stage, the coverage marks and the NEXT line come only
   from `acfw-cycle`, which reads git and the task store. If the script did not print it, it is
   not true.
4. **Never pass `--override <tool>`** unless the reply you are acting on, the yes message itself,
   contains `override <tool>` for that exact tool. An override typed on an earlier round does not
   carry over to a later yes: it was for that card's bytes. Never pass `--by` unless the user typed
   an identity.
5. **Never approve in the same turn as an edit to `plan.md`.** An edit changes the content hash, so
   the card the user said yes to is no longer the plan. Edit, re-show the card, wait. A pull, a
   `Q<n>:` answer and an `ignore F<n>:` are edits too.
6. **`--expect` comes only from a card you can see.** Copy it from the `content=` line of an
   approval card that is visible in this conversation. Never compute it, never read it from a file,
   never take it from a summary. If no such card is visible (after compaction, say), re-show the
   card with `/whip <ID>` and wait. `approve` refuses only a stale value; it cannot tell a hash you
   computed from the current file from one the user saw. The same holds for `F<n>` and `Q<n>`:
   they mean the numbers on the REVIEW block you can see, and they change every round.
7. **Spec tools run only through `acfw-spec`.** Never call a spec tool's MCP tools directly, never
   run its driver or its `review=` command yourself, and never call its service with curl.
8. **Write only `plan.md`.** Never write `record.md` (only `acfw-cycle` writes it), never write the
   source file of an adopted plan, never rename or move a cycle folder (its name is its ID), and
   never commit anything yourself (`approve` and `acfw-spec add` make their own commits).
9. **A pasted credential is written nowhere.** Not in `plan.md`, not in a file, not in a command,
   not in a subagent prompt, and never repeated back. Tell the user the key is exposed and must be
   rotated, and that the new key goes in their shell from a separate terminal or in a gitignored
   `.env`. Never print or test a key's value yourself (`echo $KEY`, `env`, `printenv`).
10. **Only the user trusts a spec tool.** The reply `run tools` runs `acfw-spec trust` with no
    arguments. Never pass `--trust` or `<name>=<key>` unless the user typed it. A tool is trusted
    only when a `TRUSTED|<name>` line says so.
11. **`/go` and `/retro` stay printed NEXT lines.** Never run them from here: `/go` is a background
    run, and `/retro` is always the user's explicit call.
12. **Free text goes in single quotes.** A title, a reason, a source, a slug, and any ref, path or
    name the user typed or a document supplied: write it as `'...'`, with each `'` inside written
    as `'\''`. Never put it in double quotes, where `$(...)`, backticks and `"` run a command or
    break the call.

The scripts are `${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle` and `acfw-spec` next to it.
Every call below spells the path out, because shell variables do not survive from one Bash call to
the next. Run them from inside the repository: they find its root themselves. Pass a cycle ID rather
than a relative path wherever you can, so the current directory inside the repo never matters. The
placeholders below are already in single quotes. Fill them in as stop rule 12 says, so a heading
like `# Invoice export $(date) now` stays text.

`status` and `approve` may walk the task store, which takes minutes on a large shared board, and
spec tools run inside a 540 s budget. Give every `acfw-cycle status`, `acfw-cycle approve` and
`acfw-spec` Bash call `timeout: 600000`.

## What the argument means

| You type | What happens |
|---|---|
| `/whip` | Where you are: `acfw-cycle status`, printed verbatim. Read-only. |
| `/whip "<goal>"` | Pick a route. Small work: print `NEXT /task "<goal>"`. Planned work: draft a plan, show the card. |
| `/whip <file.md>` | Adopt a plan written anywhere else (superpowers, spec-kit, Claude plan mode, by hand). Show the card. |
| `/whip <cycle-id>` | Show that cycle's card. After an edit to its `plan.md` (or on a plan never approved) this is the approval card again: the way to re-approve. `/retro` calls this for a retro-actions cycle. |
| `/whip --abandon [<cycle-id>]` | Close a cycle you no longer want. Zero agents. |
| `yes` (or `/whip yes`) after a card | Approve that exact plan, then start `/task --plan` in the background. |
| `/whip --review`, `--push`, `--pull`, `--from`, `--tools` | Spec tools: see **Spec tools**. |
| `run tools`, `review`, `push`, `Q<n>: ...`, `defaults`, `ignore F<n>: ...` after a card | Spec-tool replies: see **The debugger loop**. |

Cards name a cycle as `/whip <ID>`, the bare ID, never as a path to its `plan.md`: `/whip <path.md>`
means import.

Read the argument in this order, first match wins:

1. Empty: **Bare**.
2. `--abandon`, with or without a cycle: **Abandon**.
3. A cycle ID (`^[0-9]{8}-[a-z0-9][a-z0-9-]*$`), or a path inside `docs/cycles/<ID>/` (the folder,
   its `plan.md` or its `record.md`): **Show the card** for that cycle.
4. A single path to an existing file ending in `.md`: **Adopt**.
5. Any other argument starting with `--`: see **Spec tools** below. If nothing there matches, say
   `/whip` has no such option and stop.
6. A plain yes as the whole argument (`yes`, `y`, `approve`, `approved`, `ship it`,
   `yes, override <tool>`), or the card's own NEXT text (`yes: approve docs/cycles/<ID>/plan.md
   (content=<c12>)`): **The yes** for the approval card visible in this conversation. With no
   approval card visible, run **Bare** and wait. If the typed text carries a `content=` that
   differs from the visible card's, it is not a yes to that card: re-show the card with **Show the
   card** and wait.
7. A spec-tool reply to a card visible in this conversation (`run tools`, `review`,
   `review <tool>`, `push`, `push <tool>`, `defaults`, `Q<n>: <answer>`, `ignore F<n>: <reason>`,
   several of them in one message included): **The debugger loop**. With no card visible, run
   **Bare** and wait.
8. Anything else is a goal, quoted or not: **Goal**.

## Bare: where am I

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" status
```

Print it verbatim. That is the whole answer: run nothing else, not even a spec review. It ends
with exactly one `NEXT` line and either `NEED YOU: nothing` or one or more cards, each with `WHAT`,
`RISK` and `REPLY` lines. A card's REPLY is what the user types or does next; do not run it for
them. An approval card (one with a `content=` line) is answered through **The yes**, and its NEXT
line (`NEXT yes: approve docs/cycles/<ID>/plan.md (content=<c12>)`) is a reply for the user to
type, not a command.

Bare status reports on one cycle: the one in flight, or your single draft. A draft never takes NEXT
from a cycle in flight. When several cycles could be meant, it prints a `/whip <ID>` card for each.
A draft it does not mention opens with `/whip <ID>`.

## Goal: pick the route

There are two routes. **Small is the default.** Take the planned route only when the user asks for
a plan (the goal starts with the word `plan`, as in `/whip plan <goal>`, or they answer "plan"
after you picked small), or when the goal touches one of these:

- data, a schema, or a migration;
- auth, secrets, payments, or personal data (PII);
- a breaking change to a public contract (an API, CLI flags, a file format, an event shape);
- three or more modules;
- a new user flow.

Words like "or" and "should" in the goal are not triggers. Say the route in one line, with the
trigger that picked it.

**Small.** Print exactly this line and stop:

```
NEXT /task "<the goal, verbatim>"
```

Do not run `/task`. If the user answers "plan", take the planned route with the same goal.

**Planned.** Draft the plan in this session. You hold the conversation, so no subagent drafts it.

1. Create the cycle folder. The slug is 2 to 5 words of the goal, lowercase, hyphens only
   (`^[a-z0-9][a-z0-9-]*$`), at most 30 characters:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" init '<slug>' --kind feature --source '/whip draft' --title '<short title>'
   ```
   Its first line is `INIT|<ID>|docs/cycles/<ID>/plan.md`. From here on pass `<ID>` as the plan
   argument. `init` already wrote `plan.md` from the template (the project's
   `docs/acf/backlog/plan-template.md` if it has one, else the plugin's
   `content/backlog/plan-template.md`) and `record.md`. Nothing is committed yet.

   **Exit 3 with `REFUSED (3): docs/cycles/<ID> already exists`** means a cycle with that ID was
   started today. You picked the slug, so look at that cycle before you send the user anywhere:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" status '<ID>'
   ```
   If it prints `this cycle is abandoned` or `this cycle is closed`, the folder is finished and
   nobody can continue it: pick another slug (add one more word of the goal) and run `init` once
   more. Otherwise print the refusal and stop. Do not print that status: it was only a check, and a
   card shown from it would skip the review. The user continues that cycle with `/whip <ID>` or
   closes it with `/whip --abandon <ID>`. Any other exit 3 (`exists at HEAD`, say) is a plain
   refusal: print it and stop.
2. Read the recorded lessons:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" lessons
   ```
   Each line is `<slug>: <rule>`. Every rule this goal walks into becomes a line in **Risks**, with
   the lesson slug as plain text (not a link). Do not paste rules that do not apply.
3. Write `plan.md` (only `plan.md`, at `<repo root>/docs/cycles/<ID>/plan.md`). Keep the template's
   headings and comments, and fill them:
   - **Problem**, including the `**Actor & trigger**:` line: who does what, and what starts it.
   - **Scope** and **Non-scope**.
   - **Assumptions**: its first line is the route, `- Route: planned, because <trigger>.` Then every
     default you chose that the user did not state, one line each, so the user can veto it on the
     card. Unknowns become assumptions. Never invent a requirement.
   - **Risks**: one line each in the template's form `<Risk>. Undo: <how to back it out>.`, citing a
     lesson as plain text (`lesson: <slug>`), never as a link.
   - **`## Deliverables`**: at most 7, each a heading `### D<n>: <outcome>` (a colon, never a dash)
     with binary acceptance criteria `- AC<n>.<m>: <criterion>`, at most 10 per deliverable, no
     checkboxes. Keep the template's comment under `## Deliverables`: D-ids are permanent once
     tasks name them.
4. **Show the card** (below).

## Adopt: /whip <file.md>

1. Create a cycle from the file. The source is copied, never written:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" init '<slug>' --from-file '<absolute path>' --kind feature --source 'imported from <path as the user typed it>'
   ```
   Take the slug from the file's H1 or its name. It follows the same rule as **Goal**, step 1: 2 to
   5 words, lowercase, hyphens only (`^[a-z0-9][a-z0-9-]*$`), at most 30 characters. Build it that
   way before the call: `init` refuses a slug off that pattern with exit 3 (capitals and spaces
   included), and stop rule 2 then ends the turn. Leave out `--title`: `init` takes the title from
   the file's H1. An `already exists` refusal is handled as in **Goal**, step 1. `init` adds the
   source's blob hash to the recorded Source itself. Use `<ID>` from the `INIT|` line from here on.
   If the source changes later, it is still never written: the cycle's `plan.md` is the copy that
   gets approved (to merge a changed original, see `--pull --file` under **Spec tools**).
2. Do not edit the imported `plan.md` unless the user asks. A plan with no `## Deliverables` /
   `### D<n>` headings runs with coverage off. The card says so. That is not a failure and needs
   no fix.
3. **Show the card**.

## Show the card

Every card goes through these steps, whoever asked for it. The spec review runs only for an
approval card. An approved, abandoned or closed cycle's bytes are not up for a yes, and a review
there can bill a paid tool or dispatch a subagent for nothing.

1. **Are spec tools declared?** (a file with no dot in its name directly in
   `.acfwhip/spec-tools/`, in the working tree or at HEAD):
   ```bash
   R=$(git rev-parse --show-toplevel) || exit 1
   if { find "$R/.acfwhip/spec-tools" -maxdepth 1 -type f 2>/dev/null; git -C "$R" ls-tree --name-only HEAD .acfwhip/spec-tools/ 2>/dev/null; } | sed 's#.*/##' | awk 'index($(0), ".") == 0 && NF { f = 1 } END { exit !f }'; then echo SPEC_TOOLS=yes; else echo SPEC_TOOLS=no; fi
   ```
   (`awk`, not `grep -v`: some shells wrap `grep`, and a wrapped `grep -qv` on empty input says
   yes.)
2. **Render the card** (Bash `timeout: 600000`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" status '<ID>'
   ```
   If step 1 printed `SPEC_TOOLS=no`, or this output has no line starting with `  content=` (so it
   is not an approval card), print it verbatim and go to step 5. Otherwise do not print it: it is
   the card before the review, and step 4 renders the one to show.
3. **Review the plan** (Bash `timeout: 600000`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" review '<ID>'
   ```
   Print its output verbatim, then by exit code:
   - **21**: agent work is pending. Follow **Agent work orders**, then run the same review again.
   - **20**: a credential literal. The output names each file and line, never the value. If one of
     them is `docs/cycles/<ID>/plan.md:<n>`, stop here: no card and no approval, because a yes
     would commit that line. Tell the user to delete it and rotate the key (stop rule 9). Any other
     location (a declaration, a tracked `.env` or `.mcp.json`, a driver) is not something `approve`
     commits: go on to step 4. That card carries its own credential card with the rotate reply.
   - **Anything else**: go on to step 4. A spec tool that could not run never blocks the card.
4. **Render the card again**, with the same `status` call as step 2. Print it verbatim, even though
   it repeats the REVIEW block.
5. **Stop and wait for the reply.**

An approval card carries a line `  content=<c12>` and the reply
`  REPLY yes: approve, then start /task --plan in the background (sets your /go focus)`, and its
NEXT line is `NEXT yes: approve docs/cycles/<ID>/plan.md (content=<c12>)`. With spec tools declared
it also embeds the REVIEW block: verdicts, findings `F<n>`, questions `Q<n>` and a `replies:` line
(**The debugger loop**). On a retro-actions card, a heading tagged `[loosens: yes, <control>]`
relaxes that control, and a plain yes approves it: relay the card verbatim and add nothing.

## The yes

A **plain yes** approves the plan and asks for nothing else: "yes", "y", "approve", "approved",
"ship it", or "yes, override <tool>". Anything that asks for a change is not a yes (see **Vetoes**).

1. Take `<c12>` from the `content=` line of the approval card **you showed in this conversation
   and can still see**. Never compute it, never take it from a file, never guess it. If you cannot
   see that card any more (after compaction, say), re-show it with **Show the card** and wait.
   If more than one approval card is on screen, ask which plan the yes is for.
   **A card from bare `/whip`, with spec tools declared** (the check in **Show the card**, step 1,
   prints `SPEC_TOOLS=yes`): bare status shows only cached reviews, or none, and `approve` gates on
   a review of these exact bytes. So first run **Show the card** for that cycle, steps 1 to 4 (the
   review, then the fresh card, printed verbatim). Go on to step 2 below (Approve) only when both
   hold:
   - the fresh card's `content=` is still `<c12>`;
   - its REVIEW block lists no finding (`F<n>`) and no question (`Q<n>`) that the card the user
     answered did not show. Compare the text after the number: the numbers change every round.

   Otherwise the user said yes without seeing what they would approve: stop and wait for a yes to
   the fresh card.
2. Approve:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" approve '<ID>' --expect '<c12>'
   ```
   Add `--override '<tool>'` once per tool, and only for a tool the yes message itself names with
   the words `override <tool>` (stop rule 4).
3. Print its output verbatim. On success it starts with `APPROVE|ok|cycle=<ID>|content=<c12>|commit=<sha>`
   (or `APPROVE|noop|...` when these bytes were already approved), then human lines, and its last
   line is NEXT. A stderr line `note: retro actions <ID> are done, so they were closed (commit
   <sha>)` means `approve` first closed a finished retro-actions cycle in a commit of its own. That
   is not an error.
4. **Start the decomposition yourself, only when all three hold:**
   - `approve` exited 0;
   - its NEXT line is exactly `NEXT /task --plan docs/cycles/<ID>/plan.md` (the regex is
     `^NEXT /task --plan docs/cycles/[0-9]{8}-[a-z0-9][a-z0-9-]*/plan\.md$`);
   - the Workflow tool is available in this session.

   Then invoke the `acf-whip:task` skill via the Skill tool **as your last /whip action**, with
   args copied character for character from that NEXT line: `--plan docs/cycles/<ID>/plan.md`.
   Loading the skill does not start anything by itself. Follow the instructions it loads, to the
   end: it resolves the environment and launches the `/task --plan` workflow, which sets your `/go`
   focus, and it reports what the run returns. While a `/go` run is in flight, the `/task --plan`
   run stops at its first check with `wait: /go is running`. That is its report, not a failure to
   work around. Do nothing of /whip's own after it (no summary, no NEXT line of your own).
5. **Otherwise, stop** after printing `approve`'s output. Its exit code and message say why (for
   example 9: this is not the plan on the last card; 8: a D-id was renumbered; 22: a blocking spec
   tool has not said GO; 26: the plan is out in a workbench). A refusal ends with
   `REFUSED (<code>): <reason>` on stderr, and a spec-gate refusal (22 or 26) prints the gate's own
   lines first (`spec gate: ...` or `the plan is OUT ...` on stderr, `GATE|...` on stdout). Print
   all of it verbatim. Do not re-show, retry or work around it in the same turn. If `approve`
   exited 0 and only the Workflow tool is missing, also print the Fallback line from **Without the
   Workflow tool**.

### Vetoes are edits, not yeses

A reply that changes the plan (a veto of an assumption, a new constraint, "yes, but make D2 ...",
an answer to a spec tool's question, a blocker from a sibling mode) is **not** a yes, even when it
contains the word yes:

1. Edit `plan.md` in place. A deliverable you reword keeps its D-id. New work takes the next unused
   number. To drop a deliverable, keep its heading and say so; its tasks get archived later.
2. **Show the card** again. The content hash changed, so the new card has a new `content=`.
3. Wait. Never approve in the same turn as the edit.

"no" or "stop" means do nothing. The draft stays as an untracked folder until
`/whip --abandon <ID>` closes it.

## Abandon: /whip --abandon [<cycle-id>]

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" abandon '<ID>' --reason '<their reason, in their words>'
```

Leave out `--reason` when the user gave none. With no cycle named, use the cycle of the card you
last showed in this conversation. If there is none, or more than one could be meant, print bare
`status` and ask which cycle. An untracked draft is only stamped in the working tree
(`ABANDON|ok|...|committed=no`); a tracked cycle gets its own commit. Print the output verbatim.

## Sibling modes and plugins

If a challenger or arazor mode is active in this session, fold its blockers into the one card
round: each becomes an in-place edit, an `Assumptions` line or a `Risks` line **before** you show
the card. Do not run a separate review round. `acfw-cycle` and `acfw-spec` output is still printed
verbatim, and it wins over any mode's own format. A sibling plugin that is not installed is not a
gate: carry on without it.

## Without the Workflow tool

`/task --plan` needs dynamic workflows. If the Workflow tool is not available in this session
(disabled, or an older Claude Code), everything above works up to and including `approve`. Then,
instead of invoking the task skill, print `approve`'s output verbatim and this one line, with the
plan's D-ids filled in (leave out the parentheses when the plan has none):

```
Fallback (no Workflow tool, coverage off for this cycle): /task "Implement docs/cycles/<ID>/plan.md (D1..Dn)"
```

Stop there. The user runs it. Coverage for that cycle stays off, because free-text `/task` does not
record which task covers which deliverable.

## Gates and non-gates

This is the normative list of when the cycle stops and asks a person. `docs/acf/backlog/workflow.md`
points here; it is not a list of review criteria.

**Gates (page a human):**

- Plan approval, including a `policy=block` spec tool's NO-GO, which you can override on the same
  card.
- Retro action-item approval: the same card, shown for the retro-actions cycle.
- Parked work: a task blocked at the cap, a dependency-missing block, a task in draft (including a
  spec-review hold), a deliverable marked ✗.
- Ship: git push, a PR, a merge to a shared branch. Always a person.

**Non-gates (never a reason to page a human):**

- A rejection under the cap.
- A merge conflict.
- A red gate inside a worktree.
- Mechanism or relay retries.
- An implementation choice the acceptance criteria leave open.
- Advisory critique.
- A foreign plan without D headings (coverage is off, and the card says so).
- A missing sibling plugin.
- An advisory spec-tool finding.
- A spec tool that could not run. Skip and error never block and never hold.

## Spec tools (reviewers and workbenches)

A spec tool is one committed file, `.acfwhip/spec-tools/<name>`: a **reviewer** whose findings go
on the approval card, or a **workbench** you push the plan to, edit there, and pull back. The engine
`${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec` is the only thing that runs them (stop rule 7).
How to write a declaration: `${CLAUDE_PLUGIN_ROOT}/spec-tools/README.md`.

In this section `<ID>` is the cycle the user named, else the cycle of the card you last showed in
this conversation. If there is none, or more than one could be meant, print bare `status` and ask
which cycle.

**When review runs.** Before every approval card (**Show the card**, step 3) and after every pull,
since a pull ends on an approval card. Never before a card that is not an approval card (an
approved, abandoned or closed cycle), never from bare `/whip` (it shows cached results only), and
never in `/go`. A free tool runs on every approval card. A tool with `rerun=ask` (a paid service,
or a subagent) runs on the first card; after an edit the card shows its last result as `stale since
your edit` until the user replies `review`. A tool with no `at=` runs only on `/whip --review` or
the reply `review`.

**Exit codes of `acfw-spec`.** 0 ran. 2 usage or a declaration error. 20 a credential literal.
21 agent work pending. 22 gate unmet. 23 pull conflict. 24 pull refused by validation. 25 verb not
offered, or the tool could not do it (this includes a trust notice for a tool not trusted yet).
26 the plan is, or is not, out in a workbench. Every code except 0 and 21 means: print and stop
(stop rule 2), with the one card exception in **Show the card**, step 3. Engine output may show
`<redacted>` where a credential-shaped string was; that is deliberate.

### Agent work orders (exit 21)

An `agent=` tool is a prompt that a subagent of this session runs. `review`, `push`, `pull` and
`from` may exit 21 and print one work order per line: `AGENT|<tool>|<verb>|<command>`, where
`<command>` is everything after the third `|`.

1. Dispatch **one subagent per `AGENT|` line, all in a single message**. Give each exactly this
   task: run `<command>` (character for character) with Bash, do exactly what it prints, and reply
   `done`. Do none of that work yourself, and never edit the files a work order writes.
2. When all have returned, run the same `acfw-spec` command again, with the same arguments. It
   collects the results. Handle its exit code as usual.

### The debugger loop

The REVIEW block on an approval card numbers findings `F1`..`F8` (critical and high first, never
cut) and questions `Q1`..`Q5`, labels findings `[new]` or `[persisting]`, and ends with a
`replies:` line listing the replies that apply now. Take numbers only from the REVIEW block you can
see (stop rule 6). One message may carry several replies: apply them as one edit and show one card.

| Reply | What you do |
|---|---|
| `Q<n>: <answer>` | Write the answer into `plan.md` (below), then **Show the card**. |
| `defaults` | The same for every question on the card, using each one's `(default: ...)`. |
| `ignore F<n>: <reason>` | Add a Risks line `- Accepted: <the finding, in plain words>, because <their reason>.` Then **Show the card**. |
| `review` | `acfw-spec review '<ID>' --all` in place of **Show the card** step 3 (same exit handling), then steps 4 and 5. It re-runs `rerun=ask` tools and runs tools with no `at=`. |
| `review <tool>` | The same with `--tool '<tool>'` instead of `--all`. |
| `push`, `push <tool>` | **Workbench round-trip**, push. |
| `run tools` | **Trust on first use**. |
| `yes` | **The yes**. |
| `yes, override <tool>` | **The yes**, with `--override '<tool>'`. Only when this yes message has those words (stop rule 4). |

Every decision becomes plain plan text, so the next reader needs no tool to understand it:

- An answer that settles a deliverable: edit its acceptance criterion in place (the finding's
  location says which: `L<n>`, `D<n>` or `AC<n>.<m>`), or add the next `AC<n>.<m>` under that D.
  The D-id never changes.
- Any other decision: one `Assumptions` line, in plain words.
- Never write a tool name, an `F`/`Q` number, a fingerprint or a URL into `plan.md`, and never add
  content the user did not give: only their answer, or the default the tool printed.

The edit changes `content=`, so the card that follows is a new round: review runs again on the new
bytes, and resolved findings are listed. Never approve in the same turn (stop rule 5). Ignoring a
`policy=block` tool's finding does not satisfy its gate: approval still needs that tool's GO on the
exact bytes, or the user's `yes, override <tool>`, which `approve` records with their email.

### Trust on first use

A new or changed declaration does not run until the user trusts it. The card says `new or changed
on this machine` and offers the reply `run tools`. On that reply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" trust
```

Print it verbatim. Each `TRUSTED|<name>` line is a tool now trusted. A `TRUST|<name>|...` notice with
no `TRUSTED|<name>` line means that tool is **not** trusted: the user saw only a short card before,
and now sees everything it runs. Stop and wait for another `run tools`. When every tool is trusted,
redo what showed the notice: **Show the card** for `<ID>` (the review now runs the tool), or the
push, pull or `--from` the user asked for. If only a status card showed it, stop.

### /whip --review

- `/whip --review [<ID>] [--tool <name>]... [--fresh]`: review the plan now, on-request tools
  included, then render the card:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" review '<ID>' --all
  ```
  With `--tool`, pass each `--tool '<name>'` instead of `--all`. Add `--fresh` only when the user
  typed it: it ignores cached results, so a paid tool pays again for bytes it already reviewed.
  Handle the exit code as **Show the card** step 3 does, then run its steps 4 and 5. The user
  asked for this review by name, so it runs on any cycle, approved ones included.
- `/whip --review <task>` (anything that is not a cycle ID): show why a spec tool held that task in
  draft. It changes nothing:
  ```bash
  D=$(mktemp -d "${TMPDIR:-/tmp}/acfw-review.XXXXXX") || exit 1
  p=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" read --materialize "$D" '<task>') || { rc=$?; rm -rf "$D"; exit "$rc"; }
  bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" review --stage task "$p"; rc=$?
  rm -rf "$D"; exit "$rc"
  ```
  Print it verbatim. The task stays in draft until someone moves it. The user fixes the task where
  it lives (its `.backlog/draft/` file on `files`, the backend's own editor elsewhere; `--push` and
  `--pull` take plans only, never a task) and runs `/whip --review <task>` again. Two commands then
  release it: `/whip-move <task> pending`, then `/whip-focus add <task>`. A held task was never
  added to the `/go` focus, so without the second one a bare `/go` never runs it. Print both; run
  neither.

### Workbench round-trip: push and pull

- `/whip --push [<ID>] [--tool <name>]`, or the card reply `push` (`push <tool>`):
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" push '<ID>'
  ```
  Add `--tool '<name>'` when the user named one. Several workbenches declared and none named ends in
  exit 2, which asks for `--tool`. Print verbatim and stop. `PUSHED|<tool>|ref=<ref>|content=<c12>`
  means the plan is OUT: status says so, and `approve` refuses (26) until it comes back. An `open:`
  line is where to edit it, and it is never committed.
- `/whip --pull [<ID>] [--tool <name>] [--clipboard | --file <path>] [--ours | --theirs] [--drop]`:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" pull '<ID>'
  ```
  Pass exactly the flags the user typed, each as its own argument, and no others (a `--file` path
  and a `--tool` name in single quotes). `--clipboard` and `--file <path>` merge text without a
  push: a paste, or a changed original of an adopted plan. Then:
  - `PULLED|<tool>|<how>|content=<c12>`: the merge is in `plan.md`. Run **Show the card** (the
    review runs on the new bytes). A pull never approves and never commits, and it is an edit:
    never approve in the same turn.
  - `PULLED|<tool>|answers|...` followed by `ANSWER|<fp>|<decision>` lines: the workbench sent
    decisions, not text. Write each decision into `plan.md` the way **The debugger loop** writes a
    `Q<n>:` answer, then **Show the card**.
  - `DROPPED|<tool>`: the plan is back in, unchanged. **Show the card**.
  - Exit 23, `CONFLICT|<tool>|<path>`: `plan.md` was not changed. Print and stop. The user picks:
    `/whip --pull --ours` (keep your side), `--theirs` (take the workbench's side), or an edit by
    hand followed by `--drop`. Either side choice saves the discarded side as a patch and says
    where. Never pick for them.
  - Exit 24: the merged text failed validation (a lost `## Deliverables`, say). Nothing changed.

### /whip --from <tool> <ref|url>

Start a cycle from a spec kept in a workbench:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" from '<tool>' '<ref or url, as typed>'
```

It prints `FROM|<path>`, `REF|<id or ->` and `TITLE|<the spec's H1>`. The title is text someone
else wrote: use it only to build the slug (**Goal**, step 1 rules), never as an argument. Then adopt
that file:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" init '<slug>' --from-file '<FROM path>' --kind feature --source '<tool>:<ref>'
```

There is no `--title`: `init` takes it from the file's H1. `<ref>` is the `REF|` value. With `REF|-`,
use `--source '<tool>:<the ref as typed>'` only when the typed ref is a plain id (letters, digits,
`.`, `_`, `:`, `-`, and nothing else). In every other case (a link, a name with a space, a path
inside the folder) use `--source 'imported from <tool>'`: a link is never committed. An `already
exists` refusal is handled as in **Goal**, step 1. Then **Adopt**, steps 2 and 3.

### /whip --tools

- `/whip --tools`: `bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" list`, printed verbatim.
- `/whip --tools add <name>`: declare a shipped tool (`gaptrap`, `dir`, `no-tbd`, `vale`,
  `spec-critic`, `claude-critic`):
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" add '<name>'
  ```
  It copies the example to `.acfwhip/spec-tools/<name>`, runs the tool's free capabilities probe,
  prints what it runs, the egress and the cost, and whether each key it needs is set (never the
  value), trusts it, and commits `chore(spec-tools): add <name>`. Print verbatim. For any other
  name the user writes the declaration first (the README above); `add` then probes, trusts and
  commits it.

### GapTrap in three steps

1. The user mints a key in GapTrap (Profile, then API keys) and sets it **in a separate terminal**,
   never at this prompt: the transcript keeps what is typed here. Either `export
   GAPTRAP_API_KEY=...` in their shell profile, then restart Claude Code, or a line in a gitignored
   `.env` at the repo root, which is read on every run. The exact lines are in
   `${CLAUDE_PLUGIN_ROOT}/spec-tools/gaptrap/README.md`.
2. `/whip --tools add gaptrap`. It says `needs GAPTRAP_API_KEY: set` or `NOT set`, never the value,
   and a key GapTrap refuses shows up here as `capabilities probe failed`.
3. `/whip "<goal>"`.

Each review of new plan bytes costs one GapTrap unit, so GapTrap reviews on the first card and again
only when the user replies `review`. The shipped declaration is `policy=advisory`: a plain yes
approves whatever it says.
