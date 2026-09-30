---
name: go
description: Continuous backlog execution until 100% of tasks reach a terminal state (accepted/blocked)
argument-hint: "[--all | task-ids | filter description]   (no args = your focus)"
allowed-tools:
  - Bash
  - Glob
  - Read
  - TodoWrite
  - Task
  - Workflow
---

# /go - Continuous Backlog Execution

`/go` runs tasks to completion and does not stop to ask between them (fire-and-forget). With no
arguments it runs your saved **focus**; with arguments, the tasks you name; with `--all`, the whole
backlog (see **Run scope** below).

## State Machine (User-Specified)

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal states**:
- `accepted`: finished and passed quality review
- `blocked`: failed after the maximum retries (3), or has dependencies that cannot be resolved

## Purpose

What one `/go` run does:
1. Capture the trunk identity at startup, and refuse on a detached HEAD.
2. Loop until every task is in a terminal state.
3. Process every due state transition each iteration, gated on dependencies.
4. Partition pending tasks by `Worktree:` slug and dispatch at most one specialist per slug, in parallel across slugs.
5. After dispatch returns, integrate every newly accepted worktree into the local trunk in dependency (topological) order. This is the default; see "Integration mode" below.
6. Run the quality-gate auto-fix before processing.
7. Exit only when 100% of tasks are terminal, or when a human has to step in.

**`/go` does not stop after one pass.** It keeps looping until the backlog is complete and every accepted worktree has been folded into trunk.

## Run scope

```
/go                                          your FOCUS — the tasks /task last created, or the ones
                                             you selected with /whip-focus
/go --all                                    every actionable task in the backlog
/go api-014-token-refresh ui-021-login-form  exactly those two, plus their unmet dependencies
/go MUL-4821                                 native backend ids work too
/go frontend tasks only                      everything a frontend agent owns
/go bugfixes                                 the fix/bug tasks
/go high priority backend                    any predicate over the backlog
```

**A bare `/go` runs your focus**: a short list, kept per checkout, of the tasks *you* are working
on. `/task` sets it to the tasks it just created, so the usual sequence (plan, `/task`, `/go`) needs
no arguments and still runs only your own work. `/whip-focus` edits it by hand. The focus is never
committed or shared, so two people on one board each have their own.

**With no focus set**, a bare `/go` follows a per-store policy (`bareGo`, from `acfw-store info`).
On the `files` backend the backlog belongs to this checkout, so `/go` drains all of it, as it always
has. On a shared, API-backed board it does **not** launch: one person's bare `/go` would run
everyone's work, so it reports what would run and asks you to choose. `/go --all` is always the
explicit "yes, everything".

Every scoped form resolves, before launch, to a concrete list of task stems (`args.only`). Ids go
straight through. A natural-language filter is matched against the task store in **step 3** below,
shown to you, and confirmed once. Either way the orchestrator gets a fixed list. It never re-reads
your words mid-run, so the set cannot drift.

**Dropping a task from the focus does not pause it.** A scoped run pulls in unmet dependencies, so if
another task in the run needs the one you dropped, it comes straight back. To park a task in a way
the scheduler and the doctor both understand, use `/whip-move <task> draft` to pause it or
`/whip-move <task> archive` to cancel it.

Three rules hold for every scoped run:

- **Unmet dependencies are pulled in.** Otherwise a scoped task whose dependency sits outside your
  list would wait forever. The orchestrator adds the non-terminal transitive deps and names them in
  the run log. Deps already accepted or integrated are left alone.
- **Nothing outside the scope is touched.** Out-of-scope tasks are never dispatched, transitioned or
  integrated, not even by the post-loop drain. That is why `/go` is safe to run on a backlog other
  people share.
- **Completion is measured over your scope**, not the whole backlog, so a scoped run ends when
  *your* tasks are done. A stem the store cannot resolve at all aborts the run rather than quietly
  running less than you asked for. A stem that vanishes mid-run (someone else retired it) is held
  out and named instead, because by then the rest of the scope is already running.

The `RunReport` echoes `scopeFilter` (your words), `scopedTo` (what you asked for) and
`scopeResolved` (what ran, including pulled-in dependencies).

## Integration mode

**Default (LP-CAS, 3.0.0)**: the orchestrator lands each newly accepted task on the live trunk through the `integrate-lpcas` skill. The task's change becomes a single-parent candidate, is cherry-picked onto the live tip, is committed together with an in-tree ledger marker, passes the union gate, and lands by compare-and-swap. The marker's presence on trunk is the only integration oracle: no cached snapshot, no rebase. Conflicts go to the task's `assigned_agent`, acting as resolver. See `skills/integrate-lpcas/SKILL.md`. `workflows/whip-go.workflow.js` is the authoritative implementation; the bash loop further down mirrors it and runs only when the Workflow tool is unavailable.

**Override**: if the project's `CLAUDE.md` (or other persistent agent instructions) asks for a different integration strategy, such as "open a PR per PR Group via `gh pr create` instead of merging locally", follow it and skip Step 4.5. The loop then goes back to the 1.2.0 terminal check (`accepted ∪ blocked`), and the operator handles integration.

You can **pin the mode** in a form a script reads: set `ACFW_INTEGRATION_MODE=override|default` as an env var or as a key in `.acfwhip/config`. The config file is committed, so the delivery rules travel with the repo. `acfw-store info` reports the pin as `integrationMode`, empty when unpinned. When it is empty, the orchestrator decides by reading the project instructions already in Claude's context, as before.

An **unrecognized value is FATAL** (`acfw-store` exits 2). It never falls back to unpinned. This key decides whether accepted work lands on a branch a human may never review, and falling back would hand that decision to the model, which is what the pin exists to prevent. The config parser strips quotes and trailing whitespace but **not a trailing comment**, so `ACFW_INTEGRATION_MODE=override  # PR per group` is an unrecognized value, not a pin. Put comments on their own line.

### What override mode does and does not do

| | |
|---|---|
| **Does** | Skips Step 4.5, so nothing is cherry-picked onto trunk and no ledger marker is written. Treats `accepted` as terminal (`accepted ∪ blocked`). Keeps each accepted task's `worktree/<slug>` branch and worktree alive instead of reaping them, so the deliverable has a branch to open a PR from. Relaxes the cross-slug dependency gate: acceptance alone satisfies a dep, and **ordering becomes your job**. |
| **Does not** | Push anything. Run `gh pr create`. Read or set `PR Group` (it is authored, validated and stored, but drives no behavior). Check whether trunk is protected, has a remote, or is behind `origin`. Integration is left entirely to the operator: acf-whip stops at accepted. |

**If a clean trunk matters as much as review gating, use a non-files task store.** `/go` commits `.backlog/` state transitions to the trunk branch in **both** modes, and the writer (`skills/go/bin/apply-transition.sh`) refuses to run anywhere else. A files-backed run therefore puts a stream of `task: <stem> pending -> in-progress` commits on local trunk whatever the integration mode. With `beads`, `multica` or `linear` (see `adapters/`), task state lives outside git and trunk sees only deliverables. The LP-CAS ledger stays in git on every backend.

---

## Execution: workflow-first, legacy fallback

acf-whip ships a **dynamic-workflow orchestrator** (`workflows/whip-go.workflow.js`) that runs the
whole loop inside a deterministic script: the scan, the slug partition, the dependency gate, the full
state machine (including the **blocked→pending unblock** once deps resolve and the
**in-progress→blocked timeout** past the operator threshold), topological integration, and the stall
and terminal bookkeeping. Intermediate state lives in script variables, so **your context stays flat
across iterations**. The legacy loop grows your context every iteration. Prefer the workflow.

**If the `Workflow` tool is available to you** (dynamic workflows enabled, Claude Code ≥ 2.1.154):

1. Resolve the environment with one bash call. **Refuse on detached HEAD** (empty branch):
   ```bash
   echo "PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
   echo "TRUNK_ROOT=$(git rev-parse --show-toplevel)"
   echo "TRUNK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)"
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info
   ```
   If `TRUNK_BRANCH` is empty, **stop**: `/go` needs a branch checked out at the repo root.
   The `acfw-store info` line is one JSON object carrying everything the rest of this procedure
   needs: the active **task-store backend** (`store`, default `files`), its adapter, the run-lock path
   (`runLock`), the **integration pin** (`integrationMode`) that step 2 reads, the **run focus**
   (`focusFile`, `focusCount`) and the bare-`/go` policy (`bareGo`) that step 3 branches on, and the
   per-tier **model routing** (`models`) and **effort pin** (`efforts`) that step 4 passes through.
   Read it once here; do not re-run it.
2. Decide the integration mode from the pin you just read. If `integrationMode` is non-empty, use it
   **verbatim** as `args.mode` and do not reason about it further. Only when it is empty, decide by
   reading the project's `CLAUDE.md`/`AGENTS.md` (already in your context): `override` if they ask
   for PR-per-group or non-local-merge integration, otherwise `default` (auto-merge into local trunk).
3. **Resolve the run scope** from whatever the user typed after `/go`. Four branches, in this order:

   **(0) `--all`**: omit `only`. This runs the whole backlog and always bypasses the focus and the
   `bareGo` policy. It is how someone says "yes, everything" on a shared board.

   `--all` takes no other arguments. `/go --all api-014-token` reads like a narrowing but would run
   the entire board, which on a shared store is the outcome the `bareGo` policy exists to prevent.
   **Stop and ask which they meant** (`/go --all` or `/go api-014-token`) instead of picking one.

   **(a) No arguments**: the focus branch. The `acfw-store info` line from step 1 already gave you
   `focusCount`, `focusFile` and `bareGo`.

   - **`focusCount` > 0**: read the focus and check it is still worth running, in one call:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-focus" show --live
     ```
     Two answers are not a list of tasks, and both need handling before you read one:
     - **exit 2 with a store mismatch**: the focus was written against a different backend.
       `focusCount` is a raw line count that ignores that header, so you can hit this with
       `focusCount > 0`. Report it and stop; the remedy it prints (`/whip-focus clear`) is the answer.
     - **`live state unavailable (jq not installed)`**: the stems are the stored selection, not a
       report of what can still run. You cannot tell whether the focus is still worth running, so
       say so, show the list, and let the operator decide.

     If every task is already terminal, **do not launch**. Say so and give the three ways forward:
     `/whip-focus clear`, `/task <scope>` to create new work, or `/go --all`. Otherwise show the
     list with each task's live state and the `set by … at …` line, take **one confirmation**, and
     launch with `only: [<the stems>]`, `scopeSource: "focus"`, and
     `scopeFilter: "focus set by <setBy> <ts>"`. The confirmation matters because a focus is
     *standing* state: a `/task` run may have set it hours ago, or in another session.

     **One case skips that confirmation: a focus that matches an approved cycle exactly.** If the
     operator approved a plan with `/whip` and `/task --plan` then set the focus, they already said
     yes to this work on the approval card, and asking again adds nothing. A script makes this call,
     never you. Run it with Bash `timeout: 600000`; it reads the store only when the focus touches a
     cycle:
     ```bash
     out=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" status --if-cycle 2>/dev/null) \
       && printf '%s\n' "$out" \
       | grep -E '^  focus = the [0-9]+ runnable task\(s\) of approved cycle [0-9]{8}-[a-z0-9][a-z0-9-]*$'
     ```
     The `&&` matters. When `acfw-cycle` exits non-zero (store unreachable, bad config), the command
     stops there: the grep never runs and nothing prints. A printed line means `acfw-cycle` exited 0
     and confirmed four things from git and the task store: every focus task belongs to that one
     cycle, every unfinished task of the cycle is in the focus, the approval is valid at HEAD, and at
     least one task can run. In that case say one line (`running the focus: approved cycle <ID>, <n>
     task(s)`) and launch with `only: [<the stems>]`, `scopeSource: "focus"` and `scopeFilter:
     "focus = approved cycle <ID>"`. Anything else (no line, a non-zero exit, or a focus with no
     plan, which prints nothing) means you take the confirmation as above. Never decide the match
     yourself by comparing the focus list to a plan.
   - **`focusCount` is 0 and `bareGo` is `all`** (the `files` default): omit `only`. This runs the
     full backlog, as every release before 3.4.0 did.
   - **`focusCount` is 0 and `bareGo` is `refuse`** (the default on every shared, API-backed store):
     **do not launch.** Report how many tasks are actionable (run `acfw-store snapshot --digest` and
     add `counts.pending` and `counts.rejected`), then offer these three options and no others: name
     the ids (`/go <ids>`), set a focus (`/task …` or `/whip-focus set <ids>`), or run everything
     (`/go --all`). Do not pick one for them. On a board several people share, a bare `/go` that
     drains everything is one person deciding for the whole team. This branch exists to stop that.

   **(b) The arguments name tasks**: a stem (`api-014-token-refresh`), an id (`API-14`), a **native
   backend id** (`MUL-4821` on multica, `ENG-102` on Linear), or a unique stem prefix. Pass them
   straight through as `only: ["api-014-token-refresh", ...]`. Do not ask for confirmation: the user
   named exact tasks, and the store resolves each token itself (exact id → exact stem → exact backend
   id → unique prefix). An ambiguous prefix comes back with its candidates instead of a guess. A
   native id may not look like a stem, but do **not** send it to branch (c) for that reason. The
   snapshot has no title or body to match it against, so the filter branch would fail on a token the
   store resolves without trouble.

   A backend id resolves only for an issue that **is a whip task**, one that `/task` created (on
   Linear it carries the `acf-whip` label and this repo's attachment). A bare number (`512`), an
   issue URL, and a parent issue a person created by hand (say `ENG-101`, the feature the tasks came
   from) do **not** resolve, and the run stops with `scope-unresolved`. Given a URL, pass on only its
   identifier (`ENG-102`), and only when that issue is one of the tasks. For a whole feature, run the
   focus `/task` set (a bare `/go`), or name its tasks.

   **(c) Anything else is a filter predicate**, such as "frontend tasks only", "bugfixes",
   "high priority backend" or "the auth work". Resolve it to a concrete list *here*, before launching:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" snapshot --digest
   ```
   Match the predicate against the fields the snapshot projects on every backend
   (`stem` · `id` · `folder` · `slug` · `agent` · `priority` · `deps` · `touchesGlobs`):

   | Predicate | Match on |
   |---|---|
   | "frontend tasks" | `agent` (e.g. `frontend-engineer`), `touchesGlobs` (`src/web/**`), `slug` |
   | "bugfixes" | `stem` (`fix-*`, `bug-*`); stems are descriptive kebab-case by convention |
   | "high priority" / "blockers" | `priority` (blocker \| critical \| high \| medium \| low) |
   | "the auth work" | `slug`, `stem` |

   The snapshot has **no title or body**. If these fields cannot decide the predicate, say so and
   ask for ids instead of guessing. Then **show the matched task list and get one confirmation before
   launching.** The fire-and-forget rule below still holds: it forbids interrupting *between tasks*,
   and this is one check at launch. A natural-language filter is fuzzy, and committing a long,
   expensive run to it unchecked costs more than one question.
   **If nothing matches, stop and say so. Never fall back to the whole backlog.**

   Scope is resolved **once, at launch**. The workflow receives a fixed stem list, so tasks created
   mid-run do not join it. The orchestrator does pull in a scoped task's unmet dependencies and names
   them in the run log.

   **Branches (b) and (c) never write the focus.** An explicit `/go <ids>` is a one-off selection.
   If it quietly became the standing default, the next bare `/go` would run something the operator
   never chose, and once those tasks finished it would keep reporting "nothing to do" against a
   stale list. Only `/task` and `/whip-focus` set a focus. Pass `scopeSource: "args"` for both
   branches.
4. Launch the orchestrator (it runs in the background; bootstrap runs a doctor `--fix` hard gate and
   the loop re-checks integrity every iteration):
   ```
   Workflow({
     name: "acf-whip:whip-go",
     args: { pluginRoot: "<PLUGIN_ROOT>", trunkRoot: "<TRUNK_ROOT>", trunkBranch: "<TRUNK_BRANCH>",
             mode: "default" | "override", store: "<info.store>", runLockPath: "<info.runLock>",
             // step 3, branches (a-with-focus), (b) and (c). OMIT all three on branch (0) --all and
             // on a bare /go with no focus under bareGo=all.
             only: ["<stem-or-id>", ...], scopeFilter: "<the user's words, verbatim>",
             scopeSource: "focus" | "args",
             // step 2's `acfw-store info` resolved these from env > .acfwhip/config > defaults.
             // Pass both objects through verbatim; omit them only if `info` predates 3.4.0.
             models: <info.models>, efforts: <info.efforts> }
   })
   ```

   **Launch by name, never by path.** `scriptPath` is checked against the readable set: the working
   directory plus any `--add-dir` or `permissions.additionalDirectories` entry. A normal marketplace
   install puts the plugin under `~/.claude/plugins/cache/`, which is in neither, so a `scriptPath`
   launch is refused for everyone who installed the plugin the usual way. A plugin cannot declare
   permissions (plugins are not a settings source), but the registry resolves `acf-whip:whip-go`
   without touching a path.

   **If the `Workflow` call is refused or the workflow cannot be found**, do **not** edit the user's
   settings and do **not** retry with `scriptPath`. Say in one line why the orchestrator could not
   start, then run the legacy loop below. One case has no workflow route at all: under
   `CLAUDE_WORKFLOW_NAME_ONLY` the runtime lists only built-in workflows, so neither `name` nor
   `scriptPath` resolves and the legacy loop is the only correct path. That loop is
   **files-backend only**, so on any other store report the refusal and stop.

   **Optional args (3.2.0 per-task child workflows).** Every dispatched unit runs as its own nested
   workflow by default; these tune or disable that:

   | Arg | Default | Effect |
   |-----|---------|--------|
   | `escalate` | `true` | `false` reverts to byte-identical 3.1.0 single-agent dispatch. **Try this first if a run looks hung**: at the default depth, expect roughly 2-4× the per-iteration wall clock. |
   | `escalateReview` | `false` | Turns on the multi-lens review panel. Off by default because it is the only *subtractive* seam: it can reject work that would otherwise have shipped, against a hard 3-rejection terminal. |
   | `maxAmend` | `2` | Repair rounds when an authored harness throws. Two convergence gates usually cut it to one. |
   | `maxReject` | `3` | How many rejections a task may take before the orchestrator blocks it for redesign. Raise it for exploratory work; lower it to fail fast. It applies at all four decision sites (scheduler, retry self-heal, needsOperator report, and the architect's attempt briefing), so a run under a non-default cap stays consistent. The run report echoes the value. |
   | `maxBlock` | `3` | How many times a specialist may re-block the same task before it stops being re-unblocked and is surfaced for an operator. |
   | `agentBudget` | `8` | Agent ceiling for one harness (enforced inside the child, not advisory). |
   | `agentCap` | `1000` | The run's total agent budget. Drives the FULL → LEAN → DIRECT → CLOSE ladder. |
   | `shellModel` | `haiku` | Alias for `models.shell`, kept for compatibility. |

   **Model routing (3.4.0).** Agents are routed by what they do. Pass `models` through from
   `acfw-store info`; a project pins it once in `.acfwhip/config` (`ACFW_MODEL_SHELL`,
   `ACFW_MODEL_JUDGE`, `ACFW_MODEL_AUTHOR`) rather than per invocation.

   | Tier | Default | What it covers |
   |------|---------|----------------|
   | `models.shell` | `haiku` | Bootstrap, scan, the single writer, integrate, drain, scout, harness validator, unlock: every agent that runs a fixed command and copies stdout into a schema. |
   | `models.judge` | *(session)* | `/task` planners, the judge, the critic. |
   | `models.author` | *(session)* | `/task` task-document authors. |
   | *(per agent)* | *(their frontmatter)* | Specialists and reviewers run on the `model:` declared in `.claude/agents/<name>.md`, when it declares one. |
   | *(fixed)* | *(session)* | The workflow architect and the conflict resolver. Not knobs. |

   `efforts.shell` pins reasoning effort for the shell tier (`ACFW_EFFORT_SHELL`, env >
   `.acfwhip/config`, reported by `acfw-store info` as `efforts.shell`). It ships **unset** on
   purpose. The shell tier's model is missing from the documented effort-support table, and the
   effect of a low setting on verbatim-copy fidelity is undocumented. Now that a short relay is
   detected instead of trusted, a team can opt in and measure the effect safely. An unrecognised
   value is refused (`acfw-store` exits 2), not passed through, because a rejected option would fail
   every agent call in the run.

   The report's `agentsByTier` counts agents where they are **charged**, so it includes a retried
   call and every agent a child harness spends. `child` is its own tier. `untiered` catches any
   dispatch that went through neither helper, so it shows up as a number instead of vanishing.

   **Run-scope args (3.2.3).** All three come from step 3 and are omitted together on a
   full-backlog run:

   | Arg | Default | Effect |
   |-----|---------|--------|
   | `scopeSource` | `"args"` when `only` is set | `"focus"` marks a bare-`/go` run of the saved focus. It changes one decision: a paused or retired member of a focus is skipped and reported, while one named explicitly aborts the run, because you asked for a task that cannot run. |
   | `only` | *(none)* | Task stems/ids to run **instead of** the whole backlog. The orchestrator plans, transitions, integrates and counts completion over just these, plus any **unmet dependencies**, which it pulls in and names in the log. An id that does not exist aborts the run rather than silently running a smaller set. |
   | `scopeFilter` | `""` | The operator's raw words, recorded in the `RunReport`. For a natural-language filter it is the only record of what was asked for, since `only` holds the resolved stems. |

   The per-iteration scan runs two commands:

   ```
   acfw-store snapshot --digest --mode <mode> [--only <stem>...] --full-to <run-dir>/snap-full.json
   acfw-store doctor --quiet --active-only [--snapshot <that file>]
   ```

   The first is a small scheduling snapshot: counts, actionable tasks and a compact `satisfiedDeps`
   list, with terminal-accepted tasks collapsed and the result narrowed to the scope when there is
   one. The second checks full integrity over the active folders, with accepted tasks fed in as
   cheap stubs. A lived-in backlog scans in seconds instead of tens of seconds. Both go through the
   dispatcher (`acfw-store`), never a battery by path, which is why they work on every backend.

   The **Model routing** table above decides which model runs what. In short: the shell tier covers
   every agent that runs a fixed command and copies stdout into a schema, specialists and reviewers
   take the `model:` their own agent file declares, and only the architect and the conflict resolver
   are pinned to the session model.
5. When it completes, report the returned `RunReport` (completed?, iterations, finalCounts,
   integrated[], stopReason). If it returns `aborted: true`, surface `reason` and `fatals` and
   **stop**. An aborted report can still carry `integrationWarnings[]` if the run landed work before
   it aborted; relay those first, as described below. On a scoped run, also report `scopeResolved`
   so the operator sees which tasks ran and which dependencies were pulled in. Re-running `/go` is
   the documented resume: git and the task store (`.backlog/` on the default files backend) are the
   only durable state.

   **Four fields change what you should say, and none of them is `completed` alone:**
   - **`integrationWarnings[]`**: `WARN:` lines the integrator printed, each prefixed with its
     task's stem. One says the integrator dropped a task's edits under `docs/cycles/` (tasks never
     edit cycles; a plan changes only through `/whip`). Another says a landing overwrote
     uncommitted work at the root, and ends with a `Recover:` command. Relay every line verbatim,
     before anything else in your summary: that command is printed nowhere else.
   - **`heldOut[]`**: tasks the run refused to touch, and still refuses at the end. Each is
     `quarantined` (a task-level integrity FATAL), `paused` (an inactive member of a focus), or
     `vanished` (someone retired it mid-run). Name them. A run with anything held out inside its
     scope reports `stopReason: 'partial'` and `completed: false`. It finished everything it was
     *allowed* to touch, which is not the same as finishing the backlog, and the operator should not
     have to work that out from the counts.
     **`heldOutEver[]`** is the same list plus the entries whose hold was lifted mid-run (`lifted:
     true`): an operator fixed the card and the task went on to run. Those do not make a run
     `partial` and are not in `heldOut`. Mention them only if asked, but never claim a lifted task
     never ran.
   - **`fatalsNotGating[]`**: integrity findings that name nothing this run could act on. Mention
     the count and point at `/whip-doctor`; do **not** treat them as failures. One malformed card no
     longer stops runs that never touch it.
   - **`relay{}`**: whether the snapshot hop was verified. `stopReason: 'relay-truncated'` means the
     board was read correctly but the snapshot did not survive the relay through the scan agent
     intact. Nothing was mis-scheduled and nothing is lost. Tell the operator to narrow the run
     (`/go <ids>`, or set a focus) or raise `models.shell`. Never report it as missing task ids.
     Every backend that ships with acf-whip stamps this header, so on `files`, `beads`, `multica` and `linear`
     a snapshot that arrives *without* one is also `relay-truncated`: a model that drops entries is
     at least as likely to drop a header it does not understand. Only a third-party adapter may omit
     it. There the run says once that it could not verify completeness, and carries on.
     `stopReason: 'snapshot-inconsistent'` is different. The header verified, so the payload
     arrived exactly as the store emitted it, but a task the store itself resolved is missing from
     it. The snapshot script contradicted itself. Nothing was dispatched. Re-running and raising
     `models.shell` will not help, so do not suggest them. Tell the operator to report it with the
     snapshot command the reason quotes.

   `stopReason: 'scope-unresolved'` still means an id in `only` matched no task, but only when the
   store itself could not resolve it. A resolved id missing from the relayed snapshot is reported as
   a relay failure instead (`snapshot-inconsistent` when the header verified), because "check the
   ids" is the wrong advice for someone whose ids were fine. `'gated[]'` explains a `no-progress` exit by naming the dependency each pending task is
   waiting on.

   Also surface `escalation{}` and `agentsUsed`/`agentCap`. Without them an operator cannot tell a
   fully escalated run from one that silently degraded to 3.1.0 dispatch. In particular:
   - `stopReason: 'agent-cap-reached'` is a **clean** stop, not a failure. In-flight work was
     finished and integrated, every completed harness stage is on disk under the same attempt key,
     and re-running `/go` replays them for free and continues.
   - `escalation.authored === 0` with `escalation.fellBack > 0` means no harness was ever authored.
     Check that `skills/lib/bin/acfw-child-*` are executable and `.claude/agents/` is populated.
   - `escalation.stagesReplayed` is work a re-run did **not** have to redo.

   **After reporting the RunReport, do what its `nextStep` says.** This paragraph only points at the
   field; the exact command and flags live there, because after a long background run the completion
   payload is what a resumed turn reliably reads. The command prints nothing outside a planned cycle,
   so a run with no plan ends as it always did. Inside a cycle, print its output verbatim and add
   nothing of your own. A report with no `nextStep` (every `aborted: true` report) ends here. Never
   build the command yourself.
6. Do **not** also run the legacy loop below. The workflow replaces it.

**Only if the `Workflow` tool is not available** (dynamic workflows disabled, or an older Claude
Code), run the legacy single-context loop below. It enforces the same slug rules, but the loop lives
in your context and grows it.

**The legacy loop's integrity gate is stricter, on purpose**: it refuses on any FATAL, where the
orchestrator holds out only the task a task-level finding names. Per-task quarantine needs an index
that ties a finding to a task and a place to record what was held out. Both are script state the
prose loop does not have. Deciding by hand, in your context, which findings are safe to ignore is the
failure the classification was built to remove. If one malformed card blocks this path, fix it or
retire it (`/whip-move <task> archive`) instead of working around the gate.

**Run scope on the legacy path.** That loop is prose you execute, not a script that takes args, so
nothing threads the scope into it for you. Resolve the scope as in step 3, focus branch included, so a
bare `/go` means the same thing on both paths. Then treat the resolved stem list, plus any unmet
dependencies, as the *entire* backlog for this run: never select, transition or integrate a task
outside it, and state the resolved list before you begin. The `bareGo: refuse` policy applies here
too. A shared board does not become drainable because the orchestrator is unavailable.

---

# Legacy fallback loop (no dynamic workflows)

> Everything below runs only when the `Workflow` tool is unavailable. It is the byte-compatible
> version of the same `.backlog/` state machine, with Claude as the orchestrator.
>
> **files backend only**: this loop reads and moves `.backlog/<state>/` files directly, so it needs
> the default `files` task store. A project configured with another backend (`ACFW_STORE` in
> `.acfwhip/config`, such as `beads` or `multica`) needs dynamic workflows. If the `Workflow` tool is
> unavailable there, **stop** and tell the operator instead of running this loop.

## Continuous Execution Loop

```yaml
PRE-LOOP: Capture trunk identity (refuse on detached HEAD).
WHILE (terminal_tasks < total_tasks):
  iteration++
  1. Quality Gate Auto-Fix (stack-specific)
  2. Scan ALL Workflow States
  3. Process ALL Transitions (TodoWrite single call), gating on dependencies
  4. Partition pending by Worktree slug; dispatch one specialist per slug (parallel across slugs)
  4.5. Integrate Newly-Accepted (default mode): topo-sort by deps; LP-CAS onto live trunk
  5. Check Completion (exit if 100%, else CONTINUE)
  6. Prevent Infinite Loop (max 1000 iterations)
POST-LOOP: Final integration drain (defensive).
```

---

## Pre-Loop: Capture Trunk Identity

Before the first iteration, record the branch checked out at the repo root and export it as environment variables for every dispatched skill (`clean-checkout-before-task`, `integrate-lpcas`).

```bash
export ACFW_TRUNK_ROOT=$(git rev-parse --show-toplevel)
export ACFW_TRUNK_BRANCH=$(git -C "$ACFW_TRUNK_ROOT" symbolic-ref --short HEAD 2>/dev/null)
export ACFW_TRUNK_SHA_AT_START=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)

if [ -z "$ACFW_TRUNK_BRANCH" ]; then
  echo "❌ FATAL: HEAD is detached at $ACFW_TRUNK_ROOT. /go requires a branch checked out at the repo root." >&2
  exit 1
fi

# Give the loop's PR-mode switch its machine source. When the mode is pinned (env or committed
# config — see "Integration mode"), the pin wins; when unpinned, the orchestrator's prose
# decision (made in step 1 above) stands and this leaves the switch unset.
# Runs AFTER the detached-HEAD refusal (no subprocess on a run that is about to abort), and as an
# if/fi rather than `[ ... ] && export`: that idiom evaluates to exit 1 whenever the mode is not
# override, which is a landmine the day this line ends up last in a block or under `set -e`.
ACFW_MODE_PIN=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info | sed -E 's/.*"integrationMode":"([^"]*)".*/\1/')
if [ "$ACFW_MODE_PIN" = "override" ]; then
  export ACFW_INTEGRATION_OVERRIDE=1
  echo "🔒 Integration mode: override (pinned) — accepted tasks are terminal; you integrate."
fi
echo "🌳 Trunk: $ACFW_TRUNK_BRANCH @ $ACFW_TRUNK_SHA_AT_START"
```

## Pre-Loop: Backlog Integrity Gate (doctor)

Before the loop, run the integrity doctor over the active backlog as a **hard gate**. The `--fix` pass repairs the REPAIRABLE class first, including **deriving a missing `Worktree:` slug** for any active code task, so a pre-2.0.0 backlog dispatches instead of failing outright. Only a **FATAL** that survives the repair aborts. Findings on `accepted/` tasks are **advisory (WARN) and never block**: an accepted task is terminal and out of the dispatch path, so a missing slug or stale `Status:` there does not gate the run.

```bash
# Always the dispatcher, never a battery by path: the batteries are per-backend and the `files` one
# refuses to run against another store (see /whip-doctor). This loop is files-only for other reasons,
# but the doctor call has no reason to be the thing that hardcodes it.
export ACFW_TRUNK_ROOT
DOCTOR="${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store"
bash "$DOCTOR" doctor --fix >/dev/null 2>&1 || true   # self-heal REPAIRABLE (incl. derive missing slugs)
if ! REPORT=$(bash "$DOCTOR" doctor --quiet); then
  echo "❌ FATAL: backlog integrity gate failed. /go will not dispatch against an inconsistent backlog." >&2
  echo "$REPORT" | grep '^FATAL' >&2
  echo "Fix the FATAL findings (active-task errors: dangling/cyclic deps, status-folder mismatch) and re-run /go." >&2
  exit 1
fi
# Surface non-blocking findings as a compact grouped breakdown — a lived-in backlog can carry
# hundreds of historical accepted advisories, so never dump them line-by-line.
echo "$REPORT" | grep '^BREAKDOWN|' || true
```

The same doctor runs once per iteration (lite recheck, Step 0 below); a FATAL introduced mid-run also aborts the loop.

## Backlog state lives at root (single writer)

The orchestrator (this skill, running as the parent agent at `$ACFW_TRUNK_ROOT` on the trunk branch) is the **only writer of `.backlog/` files**. Specialists and quality-reviewer **do not** move task files between state folders. They report their decision in the `ACFW-RESULT` marker (defined below) when their Task() returns. The orchestrator parses the marker, does the file move, `git mv` and commit on the trunk branch, and continues.

**task-engineer transitions** (creation N/A→pending, retry rejected→pending, unblock blocked→pending, redesign rejected→blocked at the retry cap, `MAX_REJECT_RETRY`/`maxReject`, currently 3) also happen at root. task-engineer never invokes `clean-checkout-before-task` and never enters a worktree.

**Specialists** do code work in their worktrees on `worktree/<slug>`. Their commits on the worktree branch hold code only, never `.backlog/` changes.

### ACFW-RESULT marker

Every implementer specialist and every quality-reviewer ends its Task() output with one marker block, which the orchestrator parses:

```
ACFW-RESULT:
  transition: completed | blocked | accepted | rejected
  commit_sha: <sha on worktree/<slug>, or "n/a">
  rejection_increment: 0 | 1
  notes: <one-line reason; becomes the transition-log Reason field>
```

`transition` is one of:
- `completed` (implementer finished the work; orchestrator moves in-progress→completed at root, then schedules quality-reviewer)
- `blocked` (implementer hit an unresolvable blocker mid-work; orchestrator moves in-progress→blocked at root)
- `accepted` (quality-reviewer accepted; orchestrator moves in-review→accepted at root)
- `rejected` (quality-reviewer rejected; orchestrator moves in-review→rejected at root and increments Rejection Count)

If the marker is missing or malformed, the orchestrator treats the dispatch as a transient failure: the task stays in its current state and is retried next iteration.

### Lock-file backoff helper (shared, extracted)

`git_with_lock_backoff` is defined once, in `${CLAUDE_PLUGIN_ROOT}/skills/lib/acfw-git.sh`, which holds all of acf-whip's shared git logic. Source it before any orchestrator git operation:

```bash
. "${CLAUDE_PLUGIN_ROOT}/skills/lib/acfw-git.sh"
```

Backoff: 1s → 2s → 4s. Never `rm` the lock; let the holding process finish. (The shared helper captures git's exit status directly and uses a per-invocation temp error file, so it never masks a real failure as success and never clobbers a concurrent agent's error capture.)

### Integration oracle (LP-CAS)

The same file provides the **only** approved integration test. A task is integrated **iff** its in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`, `key` = task stem) is present in the tree of the live trunk tip. Never grep `Integrated-At:`. That field is inert display/ack metadata and can disagree with what is on trunk.

```bash
acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)"   # exit 0 = integrated
acfw_integrated_keys "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH"                        # all integrated keys, one per line
```

### Orchestrator move primitive

After every Task() return, parse the marker and perform the move at root:

```bash
# Parses the ACFW-RESULT marker, then delegates the move + transition-log + commit to the
# shared apply-transition.sh primitive (idempotent; single source of truth; safe on resume).
acfw_apply_result() {
  local task_file="${1}" from_state="${2}" result="${3}"
  local transition reject_inc notes new_state inc=0 dfile dseen dkey
  transition=$(echo "$result" | sed -nE 's/^[[:space:]]*transition:[[:space:]]*([a-z]+).*/\1/p')
  reject_inc=$(echo "$result" | sed -nE 's/^[[:space:]]*rejection_increment:[[:space:]]*([0-9]+).*/\1/p')
  notes=$(echo "$result" | sed -nE 's/^[[:space:]]*notes:[[:space:]]*(.*)/\1/p')
  # A NON-CODE task works in the root tree and never commits. Its deliverable_files are committed by
  # THIS call or not at all: the next clean-checkout stashes the root tree and the work is gone. The
  # workflow path stages them (safeStagePaths); this path used to drop them on the floor. Same refusal
  # set as apply-transition.sh and the acfw-store dispatcher — no empty, absolute, .., or state paths.
  # docs/cycles/ is skipped as well (3.5.0: tasks never edit cycles). This writer commits at the
  # shared root, where a human may be mid-amendment of plan.md: staging it would commit their
  # half-finished edit and void the approval at HEAD with no /whip card behind it. Skipped, never
  # refused, so the state move still happens, and an UNSTAGED edit stays uncommitted for the human
  # to judge. A STAGED one does not: the writer commits the whole root index, so a plan change the
  # human has run `git add` on rides into this transition's commit. Commit or unstage it before /go.
  # The bare folder counts too: `git add -- docs/cycles` stages the whole folder, a human's untracked
  # draft included. An ancestor (`docs`, `.`) is passed on: dropping it here would lose its other
  # files, and apply-transition.sh stages it with docs/cycles excluded.
  # The checks read dkey, the spelling git acts on: git reads docs//cycles, docs/./cycles and
  # ././docs as docs/cycles and docs, so a match on the spelling alone let those through. dseen is
  # what apply-transition.sh sees after its own `./` strip; it refuses that when empty or absolute
  # (exit 2 strands the move), so those are dropped here. The path passes on as given.
  STAGE_ARGS=()
  for dfile in $(echo "$result" | sed -nE 's/^[[:space:]]*deliverable_files:[[:space:]]*(.*)/\1/p' | tr ',[]"' '    '); do
    dfile="${dfile#./}"
    dseen="${dfile#./}"
    dkey="$dfile"
    while :; do
      case "$dkey" in
        *//*)  dkey="${dkey%%//*}/${dkey#*//}" ;;
        */./*) dkey="${dkey%%/./*}/${dkey#*/./}" ;;
        ./*)   dkey="${dkey#./}" ;;
        */.)   dkey="${dkey%/.}" ;;
        ?*/)   dkey="${dkey%/}" ;;
        *) break ;;
      esac
    done
    case "$dseen" in
      ""|/*|*..*) [ -n "$dfile" ] && echo "WARN: refusing --stage path '$dfile'" >&2; continue ;;
    esac
    case "$dkey" in
      .backlog|.backlog/*|.acfwhip|.acfwhip/*) echo "WARN: refusing --stage path '$dfile'" >&2; continue ;;
      docs/cycles|docs/cycles/*) echo "WARN: not staging '$dfile': tasks never edit cycles; change a plan with /whip" >&2; continue ;;
    esac
    [ -e "$dfile" ] && STAGE_ARGS+=(--stage "$dfile")
  done
  case "$transition" in
    completed) new_state=completed ;;
    blocked)   new_state=blocked   ;;
    accepted)  new_state=accepted  ;;
    rejected)  new_state=rejected  ;;
    *) echo "WARN: missing/invalid ACFW-RESULT for $(basename "$task_file"); transient retry next iter" >&2; return 1 ;;
  esac
  [ "$reject_inc" = "1" ] && [ "$transition" = "rejected" ] && inc=1
  bash "${CLAUDE_PLUGIN_ROOT}/skills/go/bin/apply-transition.sh" \
    ${STAGE_ARGS[@]+"${STAGE_ARGS[@]}"} \
    "$task_file" "$new_state" "${ASSIGNED_AGENT:-orchestrator}" "$notes" "$inc"
  rc=$?
  # Exit 4 = the task document is collapsed (no ID/Status): nothing was moved or committed.
  # Say so loudly — the writer refused for a reason and /whip-doctor names the recovery.
  [ $rc -eq 4 ] && echo "FATAL: transition refused for $(basename "$task_file") — collapsed task document; run /whip-doctor" >&2
  return $rc
}
```

Used after every specialist and quality-reviewer dispatch.

---

## Loop Implementation

### Iteration Start

```bash
iteration=0
max_iterations=1000
no_progress_count=0
previous_terminal_count=0
```

### Loop Condition

```bash
while [ $iteration -lt $max_iterations ]; do
  iteration=$((iteration + 1))
  echo "🔄 Iteration $iteration"

  # ... process workflow ...

  # Count terminal tasks. Override (PR) mode: accepted alone is terminal. Default (auto-merge)
  # mode: an accepted task is terminal once nothing remains to fold into trunk — its LEDGER MARKER
  # is on trunk, OR it is non-code ("none"), OR it has no worktree/<slug> branch (historical,
  # already on trunk). Equivalently: accepted MINUS the ones still pending integration (a real
  # branch, no marker). Mirrors the workflow's isTerminal.
  accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l | tr -d ' ')
  blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
    terminal_count=$((accepted_count + blocked_count))
  else
    pending_integration=0
    for f in .backlog/accepted/*.md; do
      [ -f "$f" ] || continue
      slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
      { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
      acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
      git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && pending_integration=$((pending_integration + 1))
    done
    terminal_count=$((accepted_count + blocked_count - pending_integration))
  fi
  # Denominator = the 7 ACTIVE folders only (draft/ and archive/ are excluded from automation and
  # must never inflate the completion target — matches the workflow's tasks[] population).
  total_count=$(ls -1 \
    .backlog/pending/*.md .backlog/in-progress/*.md .backlog/completed/*.md .backlog/in-review/*.md \
    .backlog/blocked/*.md .backlog/rejected/*.md .backlog/accepted/*.md 2>/dev/null \
    | grep -vE '/README\.md$' | wc -l | tr -d ' ')

  if [ $terminal_count -eq $total_count ] && [ $total_count -gt 0 ]; then
    echo "✅ Backlog 100% complete!"
    break
  fi

  # Check for progress
  if [ $terminal_count -eq $previous_terminal_count ]; then
    no_progress_count=$((no_progress_count + 1))
  else
    no_progress_count=0
  fi
  previous_terminal_count=$terminal_count

  if [ $no_progress_count -ge 3 ]; then
    echo "⚠️  No progress for 3 iterations. User intervention needed."
    break
  fi
done
```

---

## Step 0: Per-Iteration Integrity Recheck (doctor-lite)

At the top of each iteration, re-run the doctor in report-only mode; the pre-loop gate already applied the repairs. A FATAL introduced mid-run (say, a task-engineer retry that created a cycle, or a half-applied transition after a crash) aborts the loop instead of dispatching against inconsistent state.

```bash
if ! REPORT=$(ACFW_TRUNK_ROOT="$ACFW_TRUNK_ROOT" bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" doctor --quiet); then
  echo "❌ FATAL: integrity violation detected mid-run. Aborting before dispatch." >&2
  echo "$REPORT" | grep '^FATAL' >&2
  exit 1
fi
```

## Step 1: Quality Gate Auto-Fix (pre-processing)

Before processing any task, try to auto-fix common quality issues.

### Go

```bash
echo "🔧 Auto-fixing quality gates (Go)..."
gofmt -w .
goimports -w . 2>/dev/null || true
go mod tidy
go test ./... || true  # Don't fail on test errors
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Python

```bash
echo "🔧 Auto-fixing quality gates (Python)..."
ruff check . --fix || true
ruff format . || true
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Node.js/TypeScript

```bash
echo "🔧 Auto-fixing quality gates (Node.js)..."
npm run lint -- --fix 2>/dev/null || true
npm run format 2>/dev/null || true
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

### Next.js/React

```bash
echo "🔧 Auto-fixing quality gates (Next.js)..."
pnpm lint --fix 2>/dev/null || true
pnpm format 2>/dev/null || true
rm -rf .next 2>/dev/null || true  # Clear build cache
git_with_lock_backoff stash push -m "acf-whip-go-autofixes" || true
```

**Purpose**: clear trivial quality-gate failures (formatting, linting) before any task runs.

---

## Step 2: Scan All Workflow States

Scan every state folder to find the transitions that are due:

```bash
# Pending tasks (ready to start)
pending_tasks=$(ls -1 .backlog/pending/*.md 2>/dev/null || echo "")

# In-progress tasks (check for timeout)
inprogress_tasks=$(ls -1 .backlog/in-progress/*.md 2>/dev/null || echo "")

# Completed tasks (MANDATORY review trigger)
completed_tasks=$(ls -1 .backlog/completed/*.md 2>/dev/null || echo "")

# In-review tasks (should be empty, quality-reviewer must terminate)
inreview_tasks=$(ls -1 .backlog/in-review/*.md 2>/dev/null || echo "")

# Rejected tasks (retry if <3 attempts, block if ≥3)
rejected_tasks=$(ls -1 .backlog/rejected/*.md 2>/dev/null || echo "")

# Blocked tasks (check if dependencies resolved)
blocked_tasks=$(ls -1 .backlog/blocked/*.md 2>/dev/null || echo "")
```

### Check for Workflow Violations

```bash
if [ -n "$inreview_tasks" ]; then
  echo "⚠️  WARNING: Tasks in in-review/ folder (quality-reviewer must move to terminal state)"
  echo "   Tasks: $inreview_tasks"
  # Force review completion on next iteration
fi
```

---

## Step 3: Process All Transitions

Build the complete transition list in a single TodoWrite call.

### Transition Logic

#### A. Retry Rejected Tasks

For each task in `.backlog/rejected/`:
1. Read `rejection_count` from the task metadata.
2. If `rejection_count < 3`: retry it (increment the attempt).
3. If `rejection_count >= 3`: block it for redesign.

```javascript
// Example todo
{
  content: "Retry feature-001 (rejected→pending, attempt 2/3)",
  status: "pending",
  activeForm: "Retrying feature-001 after rejection"
}
```

#### B. Unblock Tasks with Resolved Dependencies

For each task in `.backlog/blocked/`:
1. Read `Dependencies` from task metadata.
2. For each dependency `dep`, check the **dependency-gating rule** below.
3. If every dep is satisfied, unblock it (blocked→pending).

#### C. Start Pending Tasks

For each task in `.backlog/pending/`:
1. For each dependency `dep`, apply the **dependency-gating rule** below. Tasks failing the check stay in `pending/` for this iteration.
2. Check priority (process by priority order).
3. Queue for start (pending→in-progress).

#### Dependency-gating rule (used by B and C, and also by Step 4a partition)

A task may dispatch only from a codebase that already contains all its dependencies. For each dep:

- **Same-slug dep** (dep's `Worktree:` equals this task's `Worktree:`): satisfied as soon as `dep` is in `.backlog/accepted/`. Its commits already live on the shared `worktree/<slug>` branch and will be present in the worktree when the within-slug serializer picks the next task.
- **Cross-slug dep** (different `Worktree:` slug): `dep` must be in `.backlog/accepted/` **and** its commits must already be on the local trunk. That means its **ledger marker is on trunk**, **or** it is a historical task with no `worktree/<slug>` branch (merged the old way, nothing left to integrate). A cross-slug dep blocks only while it is still pending integration: accepted, a live branch, no marker. A non-code (`none`) dep never integrates, so acceptance satisfies it.

In override (PR) mode no marker is ever written, so acceptance satisfies cross-slug deps too, and the operator owns the ordering. The doctor relaxes its `cross-slug-dep-not-integrated` FATAL to match (`--mode override`, or the resolved pin). **The scheduler and the doctor must agree here.** When they disagreed, this gate dispatched the dependent and the next per-iteration doctor recheck aborted the run on the state the scheduler had just chosen.

```javascript
{
  content: "Process feature-003 (pending→in-progress, deps integrated)",
  status: "pending",
  activeForm: "Processing feature-003"
}
```

#### D. Review Completed Tasks (mandatory)

For each task in `.backlog/completed/`:
1. The **orchestrator**, at root, pre-moves completed→in-review (atomic mv + commit on trunk).
2. Dispatch quality-reviewer with `TASK_FILE=$ACFW_TRUNK_ROOT/.backlog/in-review/<file>.md`.
3. When the Task() returns, the orchestrator parses ACFW-RESULT and applies in-review→accepted or in-review→rejected through `acfw_apply_result`.

```javascript
{
  content: "Review feature-004 (completed→in-review→[accepted|rejected])",
  status: "pending",
  activeForm: "Reviewing feature-004"
}
```

#### E. Timeout In-Progress Tasks (operator threshold, default 8h)

For each task in `.backlog/in-progress/`:
1. Read the timestamp from the transition log.
2. If it is older than `ACFW_INPROGRESS_TIMEOUT_HOURS` (env > `.backlog/.acfw-config` > default **8h**), time it out (in-progress→blocked).

```javascript
{
  content: "Timeout feature-005 (in-progress→blocked, stale)",
  status: "pending",
  activeForm: "Timing out feature-005"
}
```

### TodoWrite (Single Call)

```javascript
TodoWrite({
  todos: [
    // All retry transitions
    { content: "Retry feature-001 (rejected→pending, attempt 2/3)", status: "pending", activeForm: "Retrying feature-001" },

    // All unblock transitions
    { content: "Unblock feature-002 (dependencies resolved)", status: "pending", activeForm: "Unblocking feature-002" },

    // All start transitions
    { content: "Process feature-003 (pending→in-progress)", status: "pending", activeForm: "Processing feature-003" },
    { content: "Process feature-007 (pending→in-progress)", status: "pending", activeForm: "Processing feature-007" },

    // All review transitions (MANDATORY)
    { content: "Review feature-004 (completed→in-review)", status: "pending", activeForm: "Reviewing feature-004" },

    // All timeout transitions
    { content: "Timeout feature-005 (in-progress→blocked)", status: "pending", activeForm: "Timing out feature-005" }
  ]
})
```

---

## Step 4: Partition by Worktree, Then Spawn

**Concurrency rule (mandatory)**: parallel across worktrees, sequential within one. Each task declares `Worktree: <slug>` in its front-matter. Specialists invoke `clean-checkout-before-task` as Step 0, and that skill uses git's worktree branch registry as the lock. Do not bypass the partition.

### Step 4a: Partition pending tasks by Worktree

```bash
# For each pending task, extract its Worktree slug.
# Group tasks by slug. Within each group, order by priority (blocker > critical > high > medium > low).
# Skip any group whose .backlog/in-progress/ already has a task with the same Worktree slug.
# Skip any task whose dependencies are not yet satisfied (see dependency-gating rule above).
```

Implementation in shell:

```bash
# bash 3.2 throughout — macOS ships 3.2 and `declare -A` is a bash 4 feature that fails there with
# "declare: -A: invalid option", taking the whole legacy loop with it. Newline-delimited string sets
# with `grep -qxF` are the portable equivalent, and are what doctor.sh uses for the same job.
IN_PROGRESS_SLUGS=""
for f in .backlog/in-progress/*.md; do
  [ -f "$f" ] || continue
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  [ -n "$slug" ] && IN_PROGRESS_SLUGS="$IN_PROGRESS_SLUGS$slug
"
done

DISPATCH_QUEUE=()
DIRECT_DISPATCH=()   # non-code tasks (Worktree: none). This array was appended to and never READ,
                     # so every research/docs task was silently dropped from every iteration and sat
                     # in pending/ forever — the loop could never terminalize it. Consumed in 4b-bis.
SEEN_SLUGS=""
for f in $(ls -1 .backlog/pending/*.md 2>/dev/null | sort); do
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  # Dependency gate FIRST, for every pending task. It used to sit below the `slug = none` branch, so
  # non-code tasks skipped it entirely: a docs task depending on an unfinished research task was
  # dispatched immediately, while the workflow path (depsSatisfied) gates both kinds alike. Nothing
  # about having no worktree makes a dependency satisfied.
  # Cross-slug dep needs its ledger marker on trunk; same-slug dep needs accepted/.
  deps_ok=$(./.claude/skills/go/check-deps.sh "$f")  # conceptual; real impl inlines the check
  [ "$deps_ok" != "ok" ] && continue
  if [ "$slug" = "none" ]; then DIRECT_DISPATCH+=("$f"); continue; fi   # research/docs-only: dispatch directly, no worktree, no clean-checkout
  if [ -z "$slug" ]; then
    # An empty slug on a code task is a FATAL doctor violation that already aborted the run
    # at the integrity gate. If we somehow reach here, do NOT silently skip into limbo —
    # surface it and leave the task pending for the operator.
    echo "WARN: $(basename "$f") has an empty Worktree: slug. Run /whip-doctor; this is a FATAL integrity violation." >&2
    continue
  fi
  printf '%s' "$IN_PROGRESS_SLUGS" | grep -qxF "$slug" && continue   # group already busy
  printf '%s' "$SEEN_SLUGS" | grep -qxF "$slug" && continue   # already picked one task from this group this iteration
  SEEN_SLUGS="$SEEN_SLUGS$slug
"
  DISPATCH_QUEUE+=("$f")
done
```

The dep-check (inlined, not a separate script) for each task `$f`:

```bash
THIS_SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$f" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
DEPS=$(grep -E '^- \*\*Dependencies\*\*:' "$f" | sed -E 's/.*Dependencies\*\*:[[:space:]]*//')
[ "$DEPS" = "none" ] || [ -z "$DEPS" ] && return 0

for dep_id in $(echo "$DEPS" | tr ',' '\n' | tr -d '[:space:]'); do
  dep_file=$(ls .backlog/accepted/${dep_id}*.md 2>/dev/null | head -1)
  [ -z "$dep_file" ] && return 1   # dep not accepted
  dep_slug=$(grep -E '^- \*\*Worktree\*\*:' "$dep_file" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  if [ "$dep_slug" != "$THIS_SLUG" ] && [ "$dep_slug" != "none" ]; then
    # Cross-slug code dep: blocks only while genuinely pending integration — accepted, a live
    # worktree/<slug> branch, and no ledger marker on trunk. A branchless historical dep is already
    # on trunk (satisfied); a non-code "none" dep never integrates (satisfied).
    if ! acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$dep_file" .md)" \
       && git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$dep_slug"; then
      return 1
    fi
  fi
done
return 0
```

### Step 4b: Spawn one specialist per worktree-group

For each task in `DISPATCH_QUEUE`, spawn the assigned specialist. The spawns run in parallel: each works on a distinct `Worktree:` slug, so on a distinct branch and worktree, and they share no `.git/index`.

The orchestrator pre-moves each task `pending → in-progress` at root (single writer, atomic), then dispatches:

```bash
for f in "${DISPATCH_QUEUE[@]}"; do
  fname=$(basename "$f")
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  printf '| %s | pending | in-progress | orchestrator | dispatch |\n' "$TS" >> "$f"
  mv "$f" "$ACFW_TRUNK_ROOT/.backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" add ".backlog/pending/$fname" ".backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" commit -m "task: $fname pending -> in-progress" --quiet
done
```

Then issue the Task() calls in a single message (one per slug), passing the **root path** as `TASK_FILE`. The specialist prompt forbids moving the task file:

```markdown
Agent 1 (Worktree: alpha): go-engineer
  TASK_FILE=$ACFW_TRUNK_ROOT/.backlog/in-progress/feature-003.md
  Rules: invoke clean-checkout-before-task as Step 0; do code work
  inside .worktree/alpha; do NOT move the task file or commit any
  .backlog/ changes; end your response with the ACFW-RESULT marker.
Agent 2 (Worktree: beta): react-engineer (same rules)
Agent 3 (Worktree: gamma): quality-reviewer (same rules; transition is accepted | rejected)
```

After all Task() calls return, the orchestrator parses each agent's ACFW-RESULT marker and calls `acfw_apply_result` to make the matching `.backlog/` move at root (in-progress→completed, in-review→rejected, and so on).

**Within-group serialization**: tasks that share a slug are never dispatched in the same iteration. They wait until the in-progress task in their slug terminates.

### Step 4b-bis: Dispatch the non-code tasks (`Worktree: none`)

`DIRECT_DISPATCH` holds the tasks the partition set aside: research, docs and retro tasks, which have
no worktree, no clean-checkout and no branch. Having no slug, they are **not** serialized by slug, so
all of them dispatch every iteration alongside 4b. Skipping this step livelocks the loop: a non-code
task that is never dispatched never reaches a terminal state, so the loop cannot reach 100%.

Pre-move them the same way 4b does, then dispatch:

```bash
for f in ${DIRECT_DISPATCH[@]+"${DIRECT_DISPATCH[@]}"}; do
  fname=$(basename "$f")
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  printf '| %s | pending | in-progress | orchestrator | dispatch |\n' "$TS" >> "$f"
  mv "$f" "$ACFW_TRUNK_ROOT/.backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" add ".backlog/pending/$fname" ".backlog/in-progress/$fname"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" commit -m "task: $fname pending -> in-progress" --quiet
done
```

Their agent works in the **root tree** and does not commit, so its `ACFW-RESULT` marker **must** list
every file it created or changed:

```markdown
Agent (Worktree: none): research-agent
  TASK_FILE=$ACFW_TRUNK_ROOT/.backlog/in-progress/research-007.md
  Rules: do NOT run clean-checkout and do NOT create a worktree; work in the
  repo root; do NOT move the task file. End with the ACFW-RESULT marker, and
  list EVERY file you created or modified outside .backlog/ in
  deliverable_files — repo-relative. A file you do not list is never
  committed, and the next clean-checkout stashes it away permanently.
```

`acfw_apply_result` turns `deliverable_files` into `--stage` flags, so the deliverables go into the
same commit as the state move. That is the earliest moment possible, and it leaves a concurrent
checkout the smallest window in which to destroy them.

### Agent Type Selection

| Transition | Performed by | Notes |
|------------|--------------|-------|
| retry (rejected→pending) | task-engineer at root | Adjusts rejection_count narrative; orchestrator commits the move on trunk after task-engineer returns. task-engineer never enters a worktree. |
| unblock (blocked→pending) | task-engineer at root | Validates dependencies satisfied (cross-slug deps need their ledger marker on trunk). |
| dispatch (pending→in-progress) | **orchestrator** at root, before Task() | Single writer; atomic mv + commit on trunk before specialist starts. |
| start work | specialist agent inside worktree | Reads task at root path; does code work in `.worktree/<slug>`; commits code only on `worktree/<slug>`; never moves task file. Returns ACFW-RESULT. |
| in-progress→completed | **orchestrator** at root, on specialist's `transition: completed` signal | acfw_apply_result moves + commits on trunk. |
| in-progress→blocked | **orchestrator** at root, on specialist's `transition: blocked` signal | Same. |
| completed→in-review | **orchestrator** at root, before reviewer Task() | Pre-move + commit on trunk (mirrors dispatch). |
| in-review→accepted | **orchestrator** at root, on reviewer's `transition: accepted` signal | acfw_apply_result. |
| in-review→rejected | **orchestrator** at root, on reviewer's `transition: rejected` signal | acfw_apply_result; increments Rejection Count. |
| timeout (in-progress→blocked, stale past `ACFW_INPROGRESS_TIMEOUT_HOURS`, default 8h) | orchestrator at root | Synthesizes a `transition: blocked` with the note `timeout >=Nh — stale dispatch`. |

**The orchestrator is the only writer of `.backlog/` files.** Specialists' worktree-side commits contain code only. task-engineer transitions run one at a time at root and change no code.

### Specialist Agent Assignment

Read the `assigned_agent` field from the task metadata:
- `go-engineer`: Go backend tasks
- `python-engineer`: Python backend tasks
- `react-engineer`: React frontend tasks
- `nextjs-engineer`: Next.js tasks
- etc.

If no specialist is assigned, use task-engineer for guidance.

---

## Step 4.5: Integrate Newly-Accepted (default mode only)

After dispatch returns and the orchestrator has moved the reviewer-accepted tasks to `.backlog/accepted/`, land each newly accepted task on the live trunk with the **LP-CAS integrator**, one task at a time. The orchestrator (this skill, running as the parent agent) is the **only writer of trunk's `.git/index`**, so nothing in this step runs in parallel.

**Skip this step entirely in override mode**, whether it is pinned via `ACFW_INTEGRATION_MODE=override` or, when unpinned, directed by project instructions (CLAUDE.md, AGENTS.md, etc.). Then no ledger marker is ever written, the operator handles integration, and the loop's terminal check falls back to `accepted ∪ blocked`.

The skip is **executable, not advisory**. Until 3.2.1 it was prose only: `ACFW_INTEGRATION_OVERRIDE` gated the terminal counts and the post-loop drain but *not* this step, so a correctly pinned override run still cherry-picked every accepted task onto the local trunk. The pin changed how tasks were counted and nothing about where the code went.

**Run this check before Step 4.5a.** If it prints the skip line, do not run 4.5a or 4.5b; go straight to Step 5:

```bash
if [ "${ACFW_INTEGRATION_OVERRIDE:-}" = "1" ]; then
  echo "⏭️  Step 4.5 skipped (override mode) — accepted tasks stay on worktree/<slug> for you to PR."
fi
```

**If the mode is unpinned and you decided `override` by reading project instructions**, then `export ACFW_INTEGRATION_OVERRIDE=1` yourself during Pre-Loop. That one switch is what the terminal counts (Step 5), the post-loop drain and this guard all read. Set it and they agree. Leave it unset while acting as if in override mode, and the loop still folds every accepted task into trunk.

The integrator changes **only git**: the trunk ref and a disposable integration worktree. It never moves a task file; `.backlog/` moves stay the orchestrator's job (see exit 6 below).

### Step 4.5a: Topologically sort unintegrated accepted tasks

Enqueue every accepted task that has a code slug, a live `worktree/<slug>` branch, and **no ledger marker on trunk**. Sort so that, for any cross-slug dep, the dep integrates first (Kahn's algorithm over the dep edges among queue members).

```bash
declare -a INTEGRATE_QUEUE
for f in .backlog/accepted/*.md; do
  [ -f "$f" ] || continue
  slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
  { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
  acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
  git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && INTEGRATE_QUEUE+=("$f")
done

# Kahn over the dep edges AMONG QUEUE MEMBERS ONLY: a dep outside the queue is either already
# integrated (skipped above) or not a candidate, so it imposes no ordering here. `< <(...)` and not
# a pipe — a pipeline runs the `while` in a subshell, so SORTED_QUEUE would be empty in the caller
# and Step 4.5b would integrate nothing, which is the shape of the bug this block fixes.
declare -a SORTED_QUEUE
SORTED_QUEUE=()
if [ ${#INTEGRATE_QUEUE[@]} -gt 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && SORTED_QUEUE+=("$line")
  done < <(
    for f in "${INTEGRATE_QUEUE[@]}"; do
      printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$f" \
        "$(grep -E '^- \*\*Dependencies\*\*:' "$f" | head -1 | sed -E 's/.*Dependencies\*\*:[[:space:]]*//')"
    done | awk -F'\t' '
      { stem[NR]=$(1); file[NR]=$(2); deps[NR]=$(3); n=NR; idx[$(1)]=NR }
      END {
        for (i=1;i<=n;i++) {
          m=split(deps[i], d, ",")
          for (k=1;k<=m;k++) {
            gsub(/^[ \t]+|[ \t]+$/, "", d[k])
            if (d[k]=="" || d[k]=="none" || !(d[k] in idx)) continue
            j=idx[d[k]]; edge[j,++out[j]]=i; indeg[i]++
          }
        }
        qn=0; for (i=1;i<=n;i++) if (indeg[i]+0==0) q[++qn]=i
        head=1; emitted=0
        while (head<=qn) {
          i=q[head++]; print file[i]; placed[i]=1; emitted++
          for (k=1;k<=out[i]+0;k++) { j=edge[i,k]; if (--indeg[j]==0) q[++qn]=j }
        }
        # A cycle would strand its members. doctor already FATALs on a real one, so emit the
        # remainder in input order: degrade to unsorted, never to dropped deliverables.
        if (emitted<n) for (i=1;i<=n;i++) if (!(i in placed)) print file[i]
      }'
  )
fi
```

### Step 4.5b: Integrate sequentially

`ACFW_TRUNK_ROOT` and `ACFW_TRUNK_BRANCH` must be exported (Pre-Loop). Optionally export `ACFW_GATE_CMD` (the project's union quality gate, run with CWD = the candidate tree) and `ACFW_PARSE_SANITY_CMD` (a cheap parse/lint check, run before the heavy gate so a botched conflict resolution surfaces as a mechanism fault, not a coverage regression).

```bash
LP="${CLAUDE_PLUGIN_ROOT}/skills/integrate-lpcas/bin/integrate-lpcas.sh"
for task_file in ${SORTED_QUEUE[@]+"${SORTED_QUEUE[@]}"}; do
  OUT=$(bash "$LP" "$task_file"); rc=$?
  # rc 7: OUT carries `worktree:`, `assigned_agent:`, and a `conflicted_files:` block. Dispatch that
  # agent into that worktree as a conflict resolver (see below), then resume the SAME attempt:
  [ $rc -eq 7 ] && { bash "$LP" --post-resolver "$task_file"; rc=$?; }
done
```

Map each exit code exactly as `workflows/whip-go.workflow.js` does:

| exit | outcome | orchestrator action |
|------|---------|---------------------|
| 0 | integrated / already-integrated | Change + marker are on trunk. Nothing to write. |
| 3 | contaminated (quarantine) | Malformed or poison candidate. **Park this task for an operator**; do not retry, do not reject the others. |
| 4 | skipped | No candidate ref: a historical task already on trunk. Terminal; do not retry. |
| 6 | rejected (quality-fault) | The union gate failed on the candidate tree. **You** move `accepted → rejected` and increment Rejection Count, so the task re-enters the rejection self-heal instead of being re-queued as a candidate every iteration. |
| 7 | resolver-needed | Cherry-pick conflict. Dispatch the resolver, then re-invoke `--post-resolver`. |
| 9, 11, 12, 99 | transient | Mechanism fault / `cas-lost` / trunk unobservable / git lock. **Never** a quality reject: leave the task accepted and retry next iteration. |

Only exit 6 consumes the rejection budget. A conflict (7) or a mechanism fault (9) never does.

### Resolver dispatch (exit 7 only)

The integration worktree printed on the `worktree:` line is a **detached** checkout of the live trunk tip, mid-cherry-pick. Dispatch the task's `assigned_agent` into it via the Task tool with exactly this contract:

- **Allowed**: edit the conflicted files in place, then `git -C <worktree> add <file>` for each. Preserve **both** intents (the task's change and what is already on trunk).
- **Forbidden**: `git cherry-pick --continue` / `--commit` / `--abort` / `--quit` (the integrator owns the commit); `git reset`, `checkout`/`switch` to another commit, `rebase`, deleting the worktree; editing anything under `.backlog/` or `.acfwhip/`.
- If the conflict cannot be reconciled, leave the markers **unstaged**. `--post-resolver` then reports a mechanism fault (exit 9) and the task stays accepted for a later attempt.

Resolver dispatch lives in the orchestrator because bash cannot spawn a subagent. The script owns everything else: the already-integrated check, the single-parent and poison guards, the marker co-commit, the sanity and union gates, and the compare-and-swap landing.

---

## Step 5: Check Completion

Once every agent in the iteration has returned and Step 4.5 has integrated the newly accepted tasks:

```bash
# Count terminal states. Override mode: accepted alone is terminal. Default mode: an accepted task
# is terminal once nothing remains to fold into trunk — its LEDGER MARKER is on trunk, OR it is
# non-code ("none"), OR it has no worktree/<slug> branch (historical, already on trunk). = accepted
# MINUS those still pending integration (a live branch, no marker). Mirrors the workflow's isTerminal.
accepted_count=$(ls -1 .backlog/accepted/*.md 2>/dev/null | wc -l | tr -d ' ')
blocked_count=$(ls -1 .backlog/blocked/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$ACFW_INTEGRATION_OVERRIDE" = "1" ]; then
  integrated_count=$accepted_count   # treat accepted as terminal in override mode
  terminal_count=$((accepted_count + blocked_count))
else
  integrated_count=0; pending_integration=0
  for f in .backlog/accepted/*.md; do
    [ -f "$f" ] || continue
    if acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)"; then
      integrated_count=$((integrated_count + 1)); continue
    fi
    slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
    { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
    git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && pending_integration=$((pending_integration + 1))
  done
  terminal_count=$((accepted_count + blocked_count - pending_integration))
fi

# Denominator = the 7 ACTIVE folders only (draft/ and archive/ are excluded from automation).
total_count=$(ls -1 \
  .backlog/pending/*.md .backlog/in-progress/*.md .backlog/completed/*.md .backlog/in-review/*.md \
  .backlog/blocked/*.md .backlog/rejected/*.md .backlog/accepted/*.md 2>/dev/null \
  | grep -vE '/README\.md$' | wc -l | tr -d ' ')

echo "📊 Progress: $terminal_count / $total_count terminal ($integrated_count integrated, $accepted_count accepted, $blocked_count blocked)"
```

### Exit Conditions

**Success: 100% complete**
```bash
if [ $terminal_count -eq $total_count ] && [ $total_count -gt 0 ]; then
  echo "✅ Backlog 100% complete!"
  echo "   Integrated: $integrated_count"
  echo "   Accepted (unintegrated): $((accepted_count - integrated_count))"
  echo "   Blocked: $blocked_count"
  exit 0
fi
```

**Continue: work remaining**
```bash
if [ $terminal_count -lt $total_count ]; then
  echo "⏳ Work remaining. Continuing to next iteration..."
  # Loop continues
fi
```

**Intervention: no progress**
```bash
if [ $no_progress_count -ge 3 ]; then
  echo "⚠️  No progress for 3 iterations."
  echo "   Manual intervention needed."
  echo "   Review blocked tasks in .backlog/blocked/"
  exit 1
fi
```

**Abort: infinite-loop guard**
```bash
if [ $iteration -ge $max_iterations ]; then
  echo "❌ Maximum iterations reached ($max_iterations)"
  echo "   Aborting to prevent infinite loop."
  echo "   Review workflow state and blocked tasks."
  exit 1
fi
```

---

## Step 6: Loop Continuation

If Step 5 did not exit, go back to the top of the loop for the next iteration:

```bash
echo "🔄 Starting iteration $((iteration + 1))..."
# Return to Step 1: Quality Gate Auto-Fix
```

---

## Post-Loop: Final Integration Drain (default mode)

A defensive pass. If the last iteration accepted tasks but left the loop before reaching Step 4.5 (for example, through the no-progress exit), run the integration step once more before returning. Skip it in override mode.

```bash
if [ "$ACFW_INTEGRATION_OVERRIDE" != "1" ]; then
  LP="${CLAUDE_PLUGIN_ROOT}/skills/integrate-lpcas/bin/integrate-lpcas.sh"
  for f in .backlog/accepted/*.md; do
    [ -f "$f" ] || continue
    acfw_is_integrated "$ACFW_TRUNK_ROOT" "$ACFW_TRUNK_BRANCH" "$(basename "$f" .md)" && continue
    slug=$(grep -E '^- \*\*Worktree\*\*:' "$f" | head -1 | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
    { [ -z "$slug" ] || [ "$slug" = "none" ]; } && continue
    # Defensive drain. An exit 7 (resolver-needed) here is left for the next /go run rather than
    # dispatching a resolver post-loop; a branchless historical task has no branch to fold (skip).
    git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/worktree/$slug" && bash "$LP" "$f" >/dev/null 2>&1 || true
  done
fi
```

---

## Priority Enforcement (Optional)

If the project uses the 5-level priority system with SLAs:

### Priority Processing Order

1. **blocker**: process all of them before any other priority (sequential within a chain)
2. **critical**: process all of them before high, medium and low (sequential)
3. **high**: can run in parallel with other high tasks
4. **medium/low**: fully parallel

```bash
# Filter pending tasks by priority
blocker_tasks=$(grep -l "Priority.*blocker" .backlog/pending/*.md 2>/dev/null || echo "")
critical_tasks=$(grep -l "Priority.*critical" .backlog/pending/*.md 2>/dev/null || echo "")
high_tasks=$(grep -l "Priority.*high" .backlog/pending/*.md 2>/dev/null || echo "")
```

Process in order: blocker → critical → high → medium/low

---

## State Transition Authority

| From | To | Decided by |
|------|----|------------|
| N/A | pending | task-engineer |
| pending | in-progress | orchestrator, when it dispatches the specialist |
| in-progress | completed | specialist agent (`transition: completed`) |
| in-progress | blocked | specialist agent (`transition: blocked`) or the timeout |
| completed | in-review | orchestrator, when it dispatches the quality-reviewer |
| in-review | accepted | quality-reviewer (`transition: accepted`) |
| in-review | rejected | quality-reviewer (`transition: rejected`) |
| rejected | pending | task-engineer (retry) |
| rejected | blocked | task-engineer (≥3 retries) |
| blocked | pending | task-engineer (resolved) |

**Specialists and quality-reviewer decide; they never move the file.** They report through the `ACFW-RESULT` marker, and the orchestrator makes the move and writes the transition log at root, as the **Agent Type Selection** table above describes.

---

## Quality Gate Protocol

Every specialist agent **must** run the quality gates before it reports `transition: completed`:

```bash
# Example: Go quality gates
golangci-lint run ./...
go test ./... -v -race -cover
go build ./...
```

**Failure Protocol**:
- Attempts 1-10: fix the real issues.
- After 10 attempts: report `transition: blocked` with a failure report.

Stack-specific quality gates: `docs/development/quality-gates-{stack}.md`

---

## Success Criteria

A correct run:
- loops until 100% of tasks are terminal
- runs the quality-gate auto-fix every iteration
- processes every due state transition every iteration
- spawns agents in parallel for independent tasks
- checks completion after every iteration
- exits when 100% complete, or when intervention is needed

---

## Example Execution Output

```
🔥 /go - Continuous Backlog Execution Started

🔄 Iteration 1

🔧 Auto-fixing quality gates (Go)...
✓ gofmt applied
✓ go mod tidy completed
✓ Changes stashed

📊 Scanning workflow states...
✓ Pending: 5 tasks
✓ In-progress: 0 tasks
✓ Completed: 0 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 5 start transitions

🚀 Spawning agents (parallel)...
→ Agent 1: go-engineer for feature-001
→ Agent 2: go-engineer for feature-002
→ Agent 3: react-engineer for feature-003
→ Agent 4: go-engineer for feature-004
→ Agent 5: go-engineer for feature-005

[Agents execute...]

📊 Progress: 0 / 5 terminal (0 accepted, 0 blocked)
⏳ Work remaining. Continuing to next iteration...

---

🔄 Iteration 2

🔧 Auto-fixing quality gates (Go)...
✓ No changes needed

📊 Scanning workflow states...
✓ Pending: 0 tasks
✓ In-progress: 3 tasks
✓ Completed: 2 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 2 review transitions

🚀 Spawning agents...
→ Agent 1: quality-reviewer for feature-001
→ Agent 2: quality-reviewer for feature-002

[Agents execute...]

📊 Progress: 2 / 5 terminal (2 accepted, 0 blocked)
⏳ Work remaining. Continuing to next iteration...

---

🔄 Iteration 3

📊 Scanning workflow states...
✓ Pending: 0 tasks
✓ In-progress: 0 tasks
✓ Completed: 3 tasks
✓ In-review: 0 tasks
✓ Rejected: 0 tasks
✓ Blocked: 0 tasks

⚡ Processing transitions...
✓ TodoWrite: 3 review transitions

🚀 Spawning agents...
→ Agent 1: quality-reviewer for feature-003
→ Agent 2: quality-reviewer for feature-004
→ Agent 3: quality-reviewer for feature-005

[Agents execute...]

📊 Progress: 5 / 5 terminal (5 accepted, 0 blocked)

✅ Backlog 100% complete!

📊 Final Statistics:
   Total tasks: 5
   Accepted: 5 (100%)
   Blocked: 0 (0%)
   Iterations: 3
   Time: ~15 minutes

🎉 All tasks successfully completed!
```

---

## Anti-Patterns

| Anti-pattern | Never | Always |
|---|---|---|
| Single-pass execution | Process one iteration and exit | Loop until 100% complete |
| Manual intervention per task | Ask the user after each task. One confirmation at launch (step 3) is fine and expected; what is forbidden is interrupting *between* tasks. | Fire-and-forget until completion or blockage |
| Skipping the quality-gate auto-fix | Process tasks with known quality issues | Run the auto-fix first to clear trivial failures |
| Sequential processing | Process one task at a time | Spawn agents in parallel for independent tasks |

---

## Error Handling

**Infinite Loop Prevention**:
- Max 1000 iterations
- Exit if no progress for 3 iterations

**Workflow Violations**:
- Tasks stuck in in-review (quality-reviewer didn't terminate)
- Circular dependencies
- Missing assigned agents

**Quality Gate Failures**:
- Auto-fix applied
- Specialist retries (max 10)
- Specialist reports blocked after 10 failed attempts

**User Intervention Needed**:
- No progress for 3 iterations
- All non-blocked tasks stuck
- Circular dependency detected
