# Spec tools: reviewers and workbenches

A spec tool checks a plan before you approve it, checks the tasks `/task` writes from it, or lets
you edit the plan somewhere else and merge it back. You plug one in with a single committed file.
No acf-whip code changes, no wrapper for most tools.

- **Reviewer**: its findings appear on the approval card. `advisory` findings inform you; a `block`
  tool must say GO on the exact bytes you approve, or you override it by name.
- **Workbench**: `/whip --push` sends the plan out (a notes folder, a web editor), `/whip --pull`
  3-way merges it back and keeps your local edits.

The protocol is `spec-tools/CONTRACT.md`. This page is how to use it.

## Where tools run

| Hook | When | What happens |
|---|---|---|
| PLAN | before every approval card, and after every pull | tools with `at=plan` review the plan; findings go on the card |
| APPROVE | your "yes" | `block` tools need GO at those exact bytes, or "yes, override <tool>" (recorded with your email) |
| TASK | inside `/task`, before tasks are written | tools with `at=task` review each task; one repair round; a task a `block` tool still rejects is held in draft |
| STATUS | bare `/whip` | one line listing tools; cards for broken, misnamed or untrusted declarations and credential literals; plans OUT in a workbench |
| RETRO | `/retro` | the committed `reviewed` and `overridden` rows are an input |

Never in `/go`. A false positive there costs one of a task's three lives, and the spec is frozen at
approval. A tool that cannot run (skip) or fails (error) never blocks anything. A block tool the
engine never started, or cut short, because the 540 s budget ran out is not a pass: review again,
and finished tools come from the cache. At the task stage a `block` tool also holds a task when its
result cannot stand for those bytes: a locally edited declaration, a dirty driver, a tool not yet
trusted, or the budget.

## One-line reviewers

Any command that exits 0 for "fine" and 1 for "problems" works as-is. On a NO-GO with no structured
output, its first 20 output lines become findings, and a leading `12:` or `file:12:` becomes the
line number. Save one of these as `.acfwhip/spec-tools/<name>` and commit it:

```
# .acfwhip/spec-tools/no-tbd: refuse plans that still say TBD, TODO or FIXME
review=grep -nwE 'TBD|TODO|FIXME' "$ACFW_SPEC_FILE"; test $? -eq 1
at=plan,task
policy=block
```

```
# .acfwhip/spec-tools/vale: a prose linter (needs vale and a .vale.ini)
review=vale --output=line "$ACFW_SPEC_FILE"
at=plan
```

```
# .acfwhip/spec-tools/mdlint: markdown structure
review=npx --no-install markdownlint-cli2 "$ACFW_SPEC_FILE"
at=plan
```

```
# .acfwhip/spec-tools/house-rules: your own script, committed next to your code
review=bash scripts/check-plan.sh "$ACFW_SPEC_FILE"
at=plan
```

`grep` exits 0 when it finds a match, which is why `no-tbd` inverts it with `test $? -eq 1`: a match
becomes NO-GO, no match becomes GO, and a grep error becomes NO-GO rather than GO. The plan text
reaches the command through `$ACFW_SPEC_FILE` (a frozen, read-only copy), never by substitution.

`house-rules` is advisory on purpose. The engine checks the declaration itself, not the files a
`review=` command calls, so a local edit to `scripts/check-plan.sh` would change what a block gate
checks without anyone seeing it. To make your own script a block gate, commit it as a driver,
`.acfwhip/adapters/acfw-spec-house-rules` (see "Writing a driver"), and declare
`driver=house-rules` with `policy=block`. A local edit to a committed driver demotes it to advisory
until the edit is committed.

## Adding a shipped example

```
/whip --tools add no-tbd        # or: bash <acf-whip>/skills/lib/bin/acfw-spec add no-tbd
```

`add` copies the example into `.acfwhip/spec-tools/`, checks it for credentials, probes it (driver,
verbs, which environment variables it needs and whether they are set, egress, cost), trusts it on
this machine, and commits it. Shipped examples:

| Name | Kind | What it is |
|---|---|---|
| `no-tbd` | review | the grep above; `at=plan,task`, `policy=block` |
| `vale` | review | prose linting through the fallback |
| `claude-critic` | review | a one-shot `claude -p` critic; paid, so `rerun=ask` |
| `spec-critic` | agent | an LLM critic run as a subagent in your session; can also draft a revision as a workbench |
| `dir` | driver | a folder workbench (`ACFW_WORKBENCH_DIR`): Obsidian, iCloud Drive, Dropbox |
| `gaptrap` | driver | GapTrap's hosted spec analysis, and a workbench once GapTrap ships spec export |

## Declaration keys

| Key | Meaning |
|---|---|
| `review=<command>` | run a command (review only) |
| `driver=<name>` | run the executable `acfw-spec-<name>`, found in `$ACFW_SPEC_TOOL_PATH`, then `.acfwhip/adapters/`, then acf-whip's `spec-tools/<name>/`, then `$PATH` |
| `agent=<prompt.md>` | hand the prompt file (in `.acfwhip/spec-tools/`) to a subagent; plan stage only |
| `at=plan`, `task`, `plan,task` | when it runs by itself; leave it out for a tool you only run on request |
| `policy=advisory` or `block` | default advisory |
| `rerun=every` or `ask` | `ask` runs on the first card that gets a GO or NO-GO, then only when you reply "review"; the card shows the last result as "stale since your edit". Default: `ask` for a driver whose capabilities print `COST|` or were never probed, else `every`. Agent tools default to `every`; set `rerun=ask` for a paid critic |
| `timeout=<seconds>` | 5 to 540, default 120 |

Exactly one of `review=`, `driver=`, `agent=`. The file is read line by line and never executed as
shell, so an unknown key or a comment after a value is an error rather than a silent default. The
file name must be lowercase letters, digits and dashes with no extension. A file like `no_tbd` or a
copied `no-tbd.example` is ignored, and `/whip` shows a card saying so.

**Where a block tool gates.** A `block` tool whose committed `at=` names `plan`, or has no `at=`,
gates plan approval. One whose committed `at=` names `task` holds tasks in draft. A task-only block
tool never gates a plan.

**Policy and `at=` come from the committed file.** An uncommitted or edited declaration still runs,
but advisory, and its result cannot satisfy a block gate until you commit it. The same holds for a
driver in `.acfwhip/adapters/` with uncommitted edits (or a committed symlink whose target has
them), and for a driver found through `$ACFW_SPEC_TOOL_PATH` or `$PATH`. A local edit can add a
stage to `at=`, never remove one. A committed declaration that no longer parses still gates if it
could mean `block`. So editing the declaration, or a driver or prompt under `.acfwhip/`, never
loosens a gate. "Clean" is checked by content against HEAD, so `git update-index
--assume-unchanged` or `--skip-worktree` does not hide an edit. A GO counts at approval only when
the committed declaration and the committed driver or prompt produced it: after a teammate's fix to
a driver lands, the old GO is shown as stale until the tool reviews again. Files a `review=`
command calls elsewhere in the repo are not covered: see `house-rules` above.

## The card

```
REVIEW spec tools at content=3f9c2a71b0de
  no-tbd (block, egress see its command): NO-GO, 1 finding(s)
  gaptrap (advisory, egress app.gaptrap.ai): stale since your edit (last NO-GO, 3 finding(s), at content 81d0c5e2a9f4); reply review to re-run
  F1 medium L14 no-tbd: - AC2.1 TBD later
  block: no-tbd has no usable GO at this content; approval needs a GO, or your reply "yes, override no-tbd"
  replies: yes · ignore F<n>: <reason> · review · yes, override no-tbd
```

Findings are numbered F1 to F8, critical and high first and never cut. Questions are Q1 to Q5.
From the second round on, each finding is labeled `new` or `persisting`, and resolved ones are
counted. Your replies:

| Reply | Effect |
|---|---|
| `Q<n>: <answer>` / `defaults` | the answer is written into the plan (a D or AC edit, or an Assumptions line) |
| `ignore F<n>: <reason>` | recorded in the plan as a Risks line `- Accepted: <the finding>, because <your reason>.` |
| `review` | re-run every tool, including `rerun=ask` ones |
| `push` | send the plan to a workbench |
| `yes` | approve these exact bytes |
| `yes, override <tool>` | approve although a block tool has no GO; recorded in the Plan Log with your email |

Every decision becomes plain plan text. There is no waiver file. An edit changes the content hash,
which re-arms the approval and brings a fresh card.

## Workbench round-trip

With the `dir` example (a folder you edit with any app):

```
export ACFW_WORKBENCH_DIR="$HOME/Notes/plans"     # in your shell or a gitignored .env
/whip --tools add dir
/whip --push                   # copies plan.md to $ACFW_WORKBENCH_DIR/<cycle-id>.md; the plan is OUT
# edit it there, on any device; keep editing plan.md locally too if you like
/whip --pull                   # 3-way merge: fast-forward, no-op, clean merge, or conflict
```

- While OUT, approval is refused. Pull it back, or `/whip --pull --drop` to forget the remote copy.
- A conflict leaves `plan.md` untouched and writes the marked-up merge under
  `.acfwhip/run/workbench/<cycle-id>/`. Re-run with `--ours` or `--theirs`; the side you discard is
  saved there as a patch.
- `--file <path>` merges any file instead (for example a changed copy of a plan you imported), and
  `--clipboard` merges what you copied.
- The pull is refused (nothing changes) if `## Deliverables` disappeared, or, once tasks exist, if a
  `### D<n>` id they use was renumbered or removed. Before tasks exist, deliverables may be merged,
  split or dropped; the output notes each change.
- A pull never approves and never commits. A fresh review and a fresh card follow.
- `/whip --from <tool> <ref>` starts a new cycle from a document in a workbench. With `dir`, the
  ref is a file name in the folder, or a path to a file inside it. A file anywhere else is refused:
  import it with `/whip <path>`.
- A push never overwrites folder edits that were never pulled (a phone edit that synced after your
  last pull). The `dir` driver saves that copy under `.acfwhip/run/spec/<cycle-id>/state/dir/`,
  refuses once, and tells you to merge it with `/whip --pull --file <that copy>`. The next push
  goes through.

Push and pull events go into the plan's Plan Log with the approval, as `ref=<id> base=<content>`.

Push and pull take a cycle's plan, not a task. A task a `block` tool held in draft is fixed where it
lives: the file under `.backlog/draft/` on the `files` store, the backend's own editor on the others.
Then `/whip --review <task>` reviews it again, and `/whip-move <task> pending` plus
`/whip-focus add <task>` release it.
Links stay in `.acfwhip/run/` (gitignored) and never reach git.

## Writing a driver

A driver is one executable named `acfw-spec-<name>`, in any language. Commit it to
`.acfwhip/adapters/` and declare `driver=<name>`. The smallest useful one:

```bash
#!/usr/bin/env bash
case "${1:-$ACFW_SPEC_VERB}" in
  capabilities) echo "VERBS|review"; echo "EGRESS|none"; exit 0 ;;
  review)
    n=$(grep -c '^### D' "$ACFW_SPEC_FILE")
    [ "$n" -le 7 ] && exit 0
    echo "FINDING|medium|too-many-deliverables|-|$n deliverables; split the plan (7 at most)"
    exit 1 ;;
  *) echo "verb not supported" >&2; exit 3 ;;
esac
```

Try it by hand: `ACFW_SPEC_VERB=review ACFW_SPEC_FILE=docs/cycles/<id>/plan.md ./acfw-spec-mine`.

Rules that matter:
- Make `fp` stable across runs: hash the finding's pattern and text, never a per-run id. That is
  what lets the card say `persisting` and lets a decision stick.
- A paid or remote tool should write its job id into `$ACFW_SPEC_STATE` before it starts waiting,
  so a timeout or kill resumes the same job next time instead of paying again. Print `COST|` from
  `capabilities` so it defaults to `rerun=ask`.
- Print `REF|` as a plain id. Put links in `URL|` only. Never print a key, a token, or a link that
  grants access.
- A `SUMMARY|` line is optional for a driver, but it must agree with your exit code. A mismatch
  counts as NO-GO, and so does any `verdict=nogo` among several SUMMARY lines. If your tool echoes
  plan text, prefix what it echoes so a plan line starting with `SUMMARY|` never reaches stdout raw.
- Write only inside `$ACFW_SPEC_OUT` and `$ACFW_SPEC_STATE`. Stop before `$ACFW_SPEC_DEADLINE`;
  after it, your whole process group is killed.

## Agent tools

`agent=<prompt.md>` runs a prompt as a subagent in your Claude Code session. Use it for tools that
only work there: an MCP server behind OAuth, a slash-command analyzer, or an LLM critic that uses
your session. The prompt file has one section per verb (`## review`, `## push`, `## pull`); see
`examples/spec-critic.md`. acfw-spec prints `AGENT|...` work orders and exits 21, the session
dispatches the subagents, and the next run collects their results. The subagent must end its
review with `SUMMARY|verdict=go` or `SUMMARY|verdict=nogo`. Agent tools never run at the task stage.
They default to `rerun=every`; a critic that costs real tokens should say `rerun=ask`.
If you edit the plan while an agent drafts a push, the push records what the agent drafted from,
and the pull merges your edits in rather than replacing them.

## GapTrap

GapTrap (app.gaptrap.ai) analyzes a spec for gaps and returns GO or NO-GO with findings and
questions. It is the worked example of a paid, remote tool. Setup in three steps:

1. Create a key in GapTrap under Profile, API keys. In a separate terminal, add
   `export GAPTRAP_API_KEY=...` to your shell profile and restart Claude Code, or add
   `GAPTRAP_API_KEY=...` to a gitignored `.env`, which is read on every run. An export typed into
   another terminal never reaches a running Claude Code. Never paste the key into a chat or a file
   that gets committed. The exact lines are in `gaptrap/README.md`.
2. `/whip --tools add gaptrap`. It prints the driver, whether the key is set (never its value),
   the verbs, egress and cost, then commits the declaration.
3. `/whip "<goal>"`.

Details, cost and what leaves your machine: `spec-tools/gaptrap/README.md`.

## Safety

- **No credentials in committed files.** `secret-patterns` lists the shapes. A match in a
  declaration, prompt, repo driver, tracked `.mcp.json` or `.env`, or in a plan or task about to be
  sent, stops every tool with exit 20. Delete the literal, commit, and rotate the key: deleting it
  does not remove it from git history. Until the deletion is committed, the refusal stays, because
  the next push would still carry the key. A JSON `"X-Api-Key": "..."` pair counts only in
  committed configuration such as `.mcp.json` (a `${VAR}` reference is fine there). In a plan or a
  task, JSON examples with fields like `"partitionKey"` or `"nextPageToken"` are just text.
  Nothing the engine prints repeats the value: warnings, cards, status lines, push and pull output
  and the REVIEW block show `<redacted>` in its place, including a token inside a workbench link.
- **Trust on first use.** A new or changed declaration is printed in full with a version key and
  skipped until you reply "run tools" on this machine. A teammate's commit cannot run a new command
  on your machine without you seeing all of it first. "run tools" trusts the version you were
  shown in full. The status card is only a pointer: it cuts long commands at 160 characters, so a
  "run tools" after the card prints the whole declaration and asks you to reply "run tools" again.
  If the declaration changed after the notice (a `git pull` in between), it is shown again instead
  of trusted. A declaration holding a control character (a carriage return mid-line, an escape
  sequence, a bidi override) is refused as an error, so the notice always shows what runs.
  `acfw-spec trust <name>=<key>` trusts exactly one version. Trust covers the declaration and any
  driver or prompt it names under `.acfwhip/`. A `review=` command that calls a script elsewhere
  in the repo runs whatever that script contains at the time, the same as your test suite does.
- **Egress is consent.** Committing a declaration is the team's consent to send plans where it
  says. `add` and every REVIEW line show the egress.
- **Kill switch.** `ACFW_SPEC=off` runs nothing. A block tool then still needs your override at
  approval, so turning tools off never approves anything by itself.

## Troubleshooting

| Message | Meaning |
|---|---|
| `declaration error: unknown key 'polcy'` | fix the file and commit; until then it does not run |
| `runs advisory until committed` | the declaration or its driver has local edits; commit them |
| `new or changed on this machine, so it did not run` | reply "run tools" (`acfw-spec trust <name>`) |
| `stale since your edit` | a `rerun=ask` tool ran on older bytes; reply "review" to re-run |
| `timed out after 120s` | raise `timeout=` (at most 540) or make the tool faster |
| `review budget ran out before this tool started` or `... while it ran` | the tools ahead of it used the 540 s budget; reply "review" (finished tools come from the cache). A block tool cut short is not a pass |
| a task held with `nogo n=0`, path `held.md` | a block tool had no result it could stand behind (local edit, dirty driver, not trusted, budget); `held.md` says which. Fix that, then `/whip --review <stem>` |
| a task held with `<tool> unreviewed (verdict not relayed)` (or `unknown unreviewed`) | /task could not read the review verdicts back, even after one retry, so a block tool held the task without a verdict (`unknown` when the tool list did not come back either); no tool said NO-GO. Run `/whip --review <stem>`; if it passes, `/whip-move <stem> pending`, then `/whip-focus add <stem>` |
| `was NOT trusted: this exact version was not shown in full yet` | you saw the status card, not the full declaration (or it changed since); read what it prints, then reply "run tools" again |
| `holds a control or invisible formatting character` | retype that line of the declaration; a hidden character could make the notice show a different command than the one that runs |
| `stale: the tool changed since this result` | the declaration, driver or prompt changed (often a `git pull`); reply "review" to re-run it |
| `the committed declaration changed since this result` | a commit or pull changed a block tool; reply "run tools" if asked, then "review" |
| `its SUMMARY\| line(s) disagree with exit code` | the tool's SUMMARY line and its exit code differ, which counts as NO-GO; often the tool echoed a plan line that starts with `SUMMARY\|` |
| `is not a valid spec tool name` | rename the file to lowercase letters, digits and dashes, no extension, and commit |
| `the workbench copy ... changed since this checkout last synced it` | merge the saved copy: `/whip --pull --file <path>`, then push again |
| exit 26 on approve | the plan is OUT in a workbench: `/whip --pull` or `/whip --pull --drop` |

State lives in `.acfwhip/run/spec/` (frozen inputs, results, per-tool state) and
`.acfwhip/run/workbench/` (OUT markers, merge bases, conflicts). Both are gitignored and safe to
delete; the next review starts fresh.
