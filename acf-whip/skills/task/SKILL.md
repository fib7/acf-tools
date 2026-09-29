---
name: task
description: Decompose a scope into atomic tasks using task-engineer agents. It only orchestrates and never implements anything.
argument-hint: "[scope description] | --plan [<cycle ID or docs/cycles/<ID>/plan.md>]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - TodoWrite
  - Task
  - Workflow
  - mcp__perplexity__perplexity_search
  - mcp__context7__resolve-library-id
  - mcp__context7__query-docs
  - mcp__figma-dev-mode-mcp-server__get_code
---

# /task: decompose a scope into backlog tasks

`/task` splits a scope into independent, atomic tasks that `/go` can run in parallel. It only
orchestrates. It **never** implements anything: writing the code is the job of the specialists `/go`
dispatches later.

## Usage

A scope in free text:

```bash
/task "Implement user authentication system with JWT tokens"
```

With a Figma link:

```bash
/task "Add real-time notifications using WebSocket. Figma: https://figma.com/design/ABC123/App?node-id=1-2"
```

A larger scope with a constraint attached:

```bash
/task "Migrate user service from REST to GraphQL API. Maintain backward compatibility with v1 endpoints during transition."
```

From an approved cycle plan (see Plan mode below):

```bash
/task --plan 20260928-owner-seat-notice
/task --plan docs/cycles/20260928-owner-seat-notice/plan.md
/task --plan        # the cycle /whip says is next
```

---

## Plan mode: `/task --plan [<cycle>]`

`/task --plan` decomposes an approved cycle plan (`docs/cycles/<ID>/plan.md`, drafted and approved
through `/whip`) instead of free text. After you answer "yes" on an approval card, `/whip` starts it for
you. You can also run it by hand. If the argument does not start with `--plan`, skip this section: the
run is free text and everything below applies unchanged.

Do these in order:

1. **Read the argument.** Everything after `--plan` is exactly one plan reference: a cycle ID
   (`20260928-owner-seat-notice`) or a path (`docs/cycles/<ID>/plan.md`, `docs/cycles/<ID>/`). If
   anything else follows it (free text, a second path), refuse and stop with:
   `--plan takes the plan and nothing else. Put extra work in the plan and re-approve it with /whip <cycle>, or run it separately as /task "<scope>".`
   Never merge free text into a plan run, and never quietly drop it.
2. **No reference given** (`/task --plan` alone): run
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-cycle" status` and read its `NEXT` line. If it reads
   `NEXT /task --plan <path>`, use that path. Otherwise print the status output verbatim and stop.
   Never guess a cycle.
3. **The Workflow tool is required.** Plan mode exists only in the workflow; the legacy loop below
   has no plan mode. If the `Workflow` tool is unavailable or the call is refused, print this and stop:
   `/task --plan needs the Workflow tool. Without it, run: /task "Implement docs/cycles/<ID>/plan.md (D1..Dn)"`
   That fallback decomposes the plan as free text with deliverable coverage off: the cycle record does
   not map those tasks to deliverables, so `/whip` cannot show coverage for them. Say so.
4. **Launch** with steps 1 and 2 of the workflow path below, passing `planPath: "<the reference, verbatim>"`
   and **no `scope`**. The workflow validates the reference and re-checks the approval against HEAD
   itself. Do not pre-check approval, coverage or locks yourself.
5. **Report** by what comes back:
   - `aborted: true` with `stopReason: "check-refused"`: print `reason` and `nextStep` verbatim and
     stop. The plan is not approved at HEAD, another decomposition of it holds the lock, `/go` is
     running, or git is in a state that refuses. Do not retry, do not route around it, and remove a
     lock only if the reason itself tells you to.
   - `aborted: true` with `error`: the reference is not a cycle. Print `error` and `nextStep`, stop.
   - `aborted: true` with `defects`: the same as a free-text run (workflow step 3).
   - `aborted: true` with `reason` and no `stopReason` or `defects`: the check answered with something
     the run could not use, or no specialist agents are installed. Print `reason` and `nextStep`
     verbatim and stop. The run already released the lock it took.
   - `phase: "noop"`: every deliverable already has tasks. Say so and print `nextStep`.
   - `phase: "complete"`: report as for free text, plus the `cycle` block: `cycle.decomposed` (the
     deliverables this run planned), `cycle.record` (the task map line), and `cycle.coverageGaps`
     (deliverables still without a task; advisory, and a re-run of `/task --plan` decomposes exactly
     those). Say that the focus now holds this plan's unfinished tasks, so a bare `/go` runs the cycle
     and nothing else. If `cycle.dropped` is not empty, name those ids. Each one already belonged to
     an existing task, so the store refused it and the writer took this run's claim on it back out of
     the cycle record. If the id is someone else's task, it ends up in neither the cycle record nor
     your focus. If it is one of this cycle's own tasks from an earlier run, that task keeps the
     deliverables it already had.
   - `phase: "complete"` with a `review` block: a spec tool reviewed the tasks (see "Task-stage spec
     review" below). A task in `review.held` is still this cycle's task and still covers its
     deliverables, but it sits in draft and the focus leaves it out. Print its `next` command. A task
     in `review.waiting` is in the focus but depends on a held one, so a bare `/go` does not run it yet.
   - `phase: "complete"` with `cycle.recorded: false`: nothing was created, whatever was authored.
     `created` is empty, the focus was not touched, and `cycle.unrecorded` lists the documents that
     were written but never created. Print `nextStep` verbatim. When `cycle.record` starts with
     `LOCK|lost`, another `/task --plan` took this plan over while this run was planning (this run ran
     longer than the 30-minute lock window). Do not re-run to "win" it: that run is decomposing the
     same deliverables. Run `/whip` to see where the cycle stands.

What plan mode does that free text does not:
- Planners read a **frozen copy** of the approved plan (`.acfwhip/run/cycle/<ID>/<content>.md`),
  never the working-tree `plan.md`, so an edit nobody approved can never be built.
- Only **uncovered** deliverables are decomposed. A fully covered plan is a no-op.
- Every task names the deliverables it implements. The validation gate rejects a task that names none,
  or names only deliverables that other tasks already cover (a duplicate).
- Each task carries `- **Documentation**: docs/cycles/<ID>/plan.md (D2, D4)` and, in its Out of Scope,
  `Implement only D2, D4 of docs/cycles/<ID>/plan.md; plan.md is read-only.`
- The writer runs `acfw-cycle record` **first**, which commits the task map before any task exists.
  Every command that creates, stages, commits or sets the focus runs only after the record succeeds.
  A refused record creates nothing.
- A new task never reuses an existing id. The validation gate refuses an id the backlog already has.
  If one still collides when the store creates it, the writer takes it back out of the cycle record in
  the same command, so a teammate's task never counts as this plan's coverage or enters your focus.
- The run focus is **set** (replaced) to the cycle's unfinished tasks. A free-text `/task` adds to it.
- The run releases the decomposition lock on every exit it controls, and only while the lock still
  carries its own stamp, so a run never deletes another run's lock. If a run is killed, the lock
  expires after 30 minutes; `/whip` prints its age and the `rm` command to clear it sooner. A run that
  outlives the 30 minutes and finds its lock taken over stops before recording anything.

**Lessons apply in both modes.** The planners and the critic run
`acfw-cycle lessons` (read-only) and copy a relevant rule into the `constraints` of any task that walks
into it. `/retro` records those rules in `docs/acf/lessons/`.

---

## Execution: workflow-first, legacy fallback

Prefer the **workflow**. It is a deterministic script that enforces worktree slugs and an acyclic
dependency graph **before it writes any task file**: the schema requires a slug on every task, a JS
validation gate rejects cycles, duplicate ids and malformed slugs, and a doctor runs at create time.
The loop and the intermediate plan live in the script, not in your context.

**If the `Workflow` tool is available to you** (dynamic workflows turned on, Claude Code ≥ 2.1.154):

1. Resolve the environment with one bash call at the repo root:
   ```bash
   echo "PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
   echo "TRUNK_ROOT=$(git rev-parse --show-toplevel)"
   echo "TRUNK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)"
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info
   echo "SPEC_TASK_TOOLS=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" list --at task --machine 2>/dev/null | grep -c '^TOOL|')"
   ```
   The `acfw-store info` line is one JSON object. Step 2 uses three of its fields: the active
   task-store backend (`store`, default `files`), the per-tier model routing (`models`) and the
   shell-tier effort pin (`efforts`). Pass all three through verbatim. `SPEC_TASK_TOOLS` counts the
   spec tools that review tasks (declared in `.acfwhip/spec-tools/` with `at=` naming `task`). It is
   `0` in a project without them, and then nothing about the run changes.
2. Launch the workflow. It runs in the background, and its intermediate state never enters your
   context:
   ```
   Workflow({
     name: "acf-whip:whip-task",
     args: {
       scope: "<the full /task argument text, verbatim>",
       // Plan mode only (3.5.0): the --plan reference, verbatim, instead of scope. Never pass both:
       // the workflow refuses the pair rather than merge free text into an approved plan.
       planPath: "<cycle ID or docs/cycles/<ID>/plan.md>",
       pluginRoot: "<PLUGIN_ROOT>",
       trunkRoot: "<TRUNK_ROOT>",
       trunkBranch: "<TRUNK_BRANCH>",
       store: "<info.store>",
       // OPTIONAL. Competing planners decompose the scope and a judge picks or merges. 2 is the
       // default; 1 skips the panel entirely, which is the right call for a small, well-understood
       // scope where the judge round is most of the cost. Pass it when the user asks for a faster
       // or a more thorough decomposition; omit otherwise.
       planners: 1 | 2 | 3,
       // OPTIONAL (3.4.0). Per-tier model routing, resolved by step 1's `acfw-store info` from
       // env > .acfwhip/config > defaults. Pass the object through verbatim; omit it if `info`
       // predates 3.4.0. `models.shell` (default haiku) covers the agents that only run a fixed
       // command and copy stdout into a schema — the registry ls, both writers, the doctor.
       // `models.judge` (planners, judge, critic) and `models.author` (task documents) ship unset,
       // which inherits the session model.
       models: <info.models>, efforts: <info.efforts>,
       // OPTIONAL (3.5.0). Pass SPEC_TASK_TOOLS from step 1 as a number when it is above 0, and
       // omit it when it is 0. It turns on the Review phase (see "Task-stage spec review" below).
       // Leaving it out when it is above 0 writes tasks no spec tool reviewed, so never drop it.
       specTaskTools: <SPEC_TASK_TOOLS>
     }
   })
   ```
3. When it completes, report the summary it returns: the created task ids with their slugs and
   dependencies, the commit sha, and the doctor verdict. Say that a bare `/go` now runs exactly these
   tasks (the run returns `focus{}`). `/task` points this checkout's run focus at what it just created,
   so nobody has to name ids for the work they planned; `/go --all` still runs the whole backlog.
   `models` and `agentsByTier` show how many agents each tier ran. They are counted where an agent is
   charged, so a retried call shows up as the two agents it cost.
   When the report has a `review` block, spec tools reviewed the tasks before they were written.
   Report it as described under "Task-stage spec review" below. A task in `review.held` is **not** in
   the focus, and a bare `/go` will not run it. A task in `review.waiting` is in the focus, but it
   depends on a held task, so `/go` will not run it until that task is released:
   do not count it among the tasks a bare `/go` runs now.
   If it returns `aborted: true`, show the `defects` list and **stop**. Do not hand-write task files to
   route around the validation gate. If it returns `error`, **or the `Workflow` call is refused
   outright**, fall back to the legacy path below. A denied tool call returns no value at all, so the
   `error` branch never sees it. Never retry with `scriptPath`, and never edit the user's settings.
4. Do **not** also run the legacy steps. The workflow replaces them.

### Task-stage spec review

A spec tool is a reviewer a project declares in `.acfwhip/spec-tools/<name>`; `/whip --tools add <name>`
sets one up. A tool whose `at=` names `task` reviews every task `/task` authors, before the task
reaches the store. Without such a tool, none of this happens.

What the run does when one exists:
- Authors write every task document to `.acfwhip/run/staging/` first, on the `files` store too, so
  a bare `/go` never sees a task nobody reviewed.
- One shell agent runs the review. The script checks that every verdict line arrived and asks once
  more if some did not. Finished tools answer from the review cache, so the second ask re-runs none
  of them.
- A task that a `policy=block` tool rejects with findings gets one repair round: a task-engineer reads
  the findings and edits the body only. If the repair changed the title, the Metadata section or the
  Transition Log, the run puts the original document back. Then the tools review the task again.
- A task a `policy=block` tool still rejects is **held in draft**. The run still creates it (and, with
  `--plan`, records it as the cycle's task), but in `draft`, with a Transition Log row like
  `| <time> | pending | draft | spec-review | held: no-tbd nogo n=2; /whip --review <stem> |`.
  It is **not** added to your focus.
- A tool that could not run (verdict `skip`) or failed (`error`) never holds a task. An `advisory`
  tool never holds a task either: its findings go in the report, and that is all.
- A `block` tool that has no result it can stand behind for those exact bytes reports `nogo`, and the
  task is held. That happens when the tool is not trusted on this machine yet, its declaration has
  local edits, the task document holds a credential literal, or the review ran out of time. Its `path`
  in the report is then a `held.md` that says which. No repair runs, because no edit to the task fixes
  any of these.
- If the run could not read the verdicts back, even after the second try, every `block` tool with no
  verdict for a task holds that task too. No tool gave a verdict there, so the entry is marked
  `unreviewed` and the row says `held: <tool> unreviewed (verdict not relayed)`. The run reads the
  list of tools twice, once at the start and once with the verdicts. If neither list arrived whole,
  it cannot tell which tools block, so it holds each such task under the name `unknown`.
- A task that depends on a held task is not held itself. It goes into your focus, but `/go` will not
  run it until the held task is released. `review.waiting` lists it with the held ids it waits on.

How to report `review`:
- Say how many tasks were reviewed, and by which tools (`review.tools`).
- If `review.verdicts` is 0, say that no tool reviewed anything: either spec tools are switched off
  with `ACFW_SPEC=off`, or the declarations went away during the run.
- If `review.relay` starts with `short:`, say that some verdicts did not arrive, and that some tasks
  may be held for that reason alone.
- Name each repaired task. Say when `metaRestored` is true: the repair touched metadata, so the run
  threw it away.
- For each entry of `review.held`, print the id, each tool with its `n` (or `unreviewed` when the
  entry says so), and the `next` command.
- For each entry of `review.waiting`, say which held task it waits on.
- For `review.notes`, give one line per advisory finding, skip or error.

Do not re-run the review yourself, and do not move a held task out of draft.

Releasing a held task is the user's call. `/whip --review <stem>` shows why it was held. Once the task
is fixed, `/whip-move <stem> pending` releases it, and `/whip-focus add <stem>` (or `/go <stem>`)
runs it.

The legacy loop below runs no task-stage review. If `SPEC_TASK_TOOLS` was above 0 and you fall back
to it, tell the user that no spec tool reviewed the tasks it wrote, and that `/whip --review <stem>`
reviews one.

**Launch by NAME, never by path.** The `Workflow` tool checks `scriptPath` against the readable set:
the working directory plus any added directory. A real marketplace install puts the plugin under
`~/.claude/plugins/cache/`, which is neither, so the tool refuses a `scriptPath` launch for every user
who installed this plugin the normal way. The registry resolves `acf-whip:whip-task` without touching
a path.

**The legacy loop has no plan mode.** A `/task --plan` run never falls back to it (see Plan mode,
rule 3).

**The legacy loop is `files`-backend only.** It writes and commits task documents straight into
`.backlog/pending/`. On `beads`, `multica`, `linear` or a third-party adapter there is no such
directory. Files written there are invisible to the store, so the tasks do not exist even though the
run reports success. `/go` has the same fence on its own fallback.

**Resolve the backend before you fall back:** `bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info`.
Step 1 of the workflow path makes that call, so on this path you may not have run it yet. If `store`
is anything other than `files`, report the refusal and **stop**. Do not improvise, and do not write
`.backlog/` files on a store that does not use them.

Run the legacy decomposition loop below (Steps 1–8) **only when both of these hold**:
- The `Workflow` tool is unavailable, cannot resolve the workflow, or workflow step 3 sent you here
  (an `error` return or a refused call). The tool is out of reach when dynamic workflows are off, on older Claude
  Code, or when `CLAUDE_WORKFLOW_NAME_ONLY` is set: that variable limits the tool to built-in
  workflows, so no plugin workflow resolves by name or by path.
- The resolved store is `files`.

The loop writes the same task files, including the mandatory `Worktree:`, `PR Group:` and
`Touches Globs:` slug fields, but runs the whole orchestration in your own context.

---

## Style rules (mandatory)

Before you create any task, read `docs/acf/style/task-descriptions.md` and hold every task to it.

### Never put in a task

- Function or method implementations
- Algorithm pseudocode
- Step-by-step HOW instructions (the specialist decides HOW)
- Vague words: "comprehensive", "robust", "enhance", "optimize"
- Code snippets longer than 2-3 lines (signatures and shapes only)

### Always

- Binary language: "API validates token", not "improve validation"
- WHAT and WHY only, never HOW
- Testable criteria: "Returns 401 for missing token"
- Specific outcomes: "Response < 200ms", not "fast"

You read the guide in Step 1 and check every task against it in Step 4. Revise any task that breaks a
rule before you spawn a task-engineer agent.

---

## Command flow (legacy loop)

### Step 1: Read the style guide

Do this first:
```markdown
Read docs/acf/style/task-descriptions.md
```

Every rule in it binds every task. In short: WHAT and WHY only (never HOW), binary and testable
language, code snippets of 2-3 lines at most, and none of the banned words.

### Step 2: Minimal research (scope only)

#### Perplexity (required)

Search for best practices, patterns and pitfalls:

```markdown
mcp__perplexity__perplexity_search:
- "best practices for {feature-type} implementation {tech-stack}"
- "common pitfalls when building {feature-type}"
- "architecture patterns for {feature-type}"
- "testing strategies for {feature-type}"
```

You are after what to build, why, and under which constraints. Not how to implement it.

#### Figma (required when the scope gives a Figma URL or node)

1. **Extract the node ID** from the URL:
   - Format: `https://figma.com/design/:fileKey/:fileName?node-id=1-2`
   - Extract: `1:2`

2. **Call get_code**:
```markdown
mcp__figma-dev-mode-mcp-server__get_code:
  nodeId: "1:2"
```

3. **Pull out the UI requirements**:
   - Component structure
   - Layout requirements
   - Interactive elements
   - Data bindings

Use them for WHAT to build (component specs), not HOW to implement it.

#### Context7 (when needed)

To learn what a library can do (not how to use it):

```markdown
mcp__context7__resolve-library-id:
  libraryName: "{library-name}"

mcp__context7__query-docs:
  context7CompatibleLibraryID: "/org/project"
  topic: "{feature-relevant-topic}"
```

#### Project files

Scan for existing patterns:

```bash
# Find related code
grep -r "similar-feature" --include="*.{go,py,ts,tsx}"

# Find architectural patterns
glob "**/*{service,controller,handler}*"
```

Spend 5 minutes at most. You are orchestrating, not researching in depth.

### Step 3: Decompose the scope into atomic tasks

One logical feature is one task. Do not break it into micro-tasks.

**Good:** one task, "User Authentication API", covering the API endpoint, validation, token
generation, tests and docs.

**Bad:** five micro-tasks:
- "Create API endpoint"
- "Add input validation"
- "Implement JWT generation"
- "Write tests"
- "Update docs"

Work that spans the stack is still one task:
- **Good:** "User Profile Feature" (backend API + frontend component)
- **Bad:** separate "Backend API" and "Frontend Component" tasks

For each task, define:
- **WHAT**: a binary, testable outcome
- **WHY**: the business value or user impact
- **CONSTRAINTS**: performance, security, compatibility requirements
- **OUT OF SCOPE**: what not to do (mandatory)

Leave out:
- HOW to implement it
- Which libraries to use
- Code structure
- Implementation details

### Step 4: Check every task against the style guide

Before you spawn any agent, check each task:
- Binary, testable description?
- WHAT and WHY only, no HOW?
- Code snippets of 2-3 lines at most?
- No banned words?
- Specific, measurable criteria?

Revise any task that fails before you go on.

### Step 5: One TodoWrite call for all tasks

Create a todo for every task in a single TodoWrite call:

```javascript
TodoWrite({
  todos: [
    {
      content: "Create backlog task: User authentication API with JWT tokens",
      status: "pending",
      activeForm: "Creating backlog task for user authentication"
    },
    {
      content: "Create backlog task: User profile management endpoints",
      status: "pending",
      activeForm: "Creating backlog task for user profile management"
    },
    {
      content: "Create backlog task: Password reset flow with email verification",
      status: "pending",
      activeForm: "Creating backlog task for password reset"
    },
    {
      content: "Verify task dependencies and uniqueness",
      status: "pending",
      activeForm: "Verifying task dependencies"
    }
  ]
})
```

**Format**:
- `content`: "Create backlog task: {precise-deliverable-description}"
- `status`: "pending"
- `activeForm`: "Creating backlog task for {specific-component}"

End the list with one todo for the dependency check.

### Step 6: Spawn task-engineer agents in parallel

Launch one task-engineer agent per task, all in **one message** with several Task calls:

```markdown
Task 1: task-engineer for User Authentication
Task 2: task-engineer for User Profile Management
Task 3: task-engineer for Password Reset Flow
Task 4: task-engineer for Dependency Verification
```

Prompt each agent with this template:

```markdown
**Agent**: task-engineer

**Task**: Create task specification for: {feature-description}

**MANDATORY Reading**:
1. docs/acf/style/task-descriptions.md (ABSOLUTE style requirements)
2. .backlog/README.md (workflow, priorities, evidence)
3. docs/acf/backlog/task-template.md (task file structure)

**Scope**:
{WHAT to build}
{WHY it's needed}
{Constraints: performance, security, compatibility}

**Research Context** (from /task command):
{Perplexity findings: best practices, pitfalls, patterns}
{Figma specs: UI requirements} (if applicable)
{Context7 findings: library capabilities} (if applicable)

**Out of Scope**:
{What NOT to do}

**Requirements**:
- Follow task-descriptions.md style guide (WHAT/WHY only, max 2-3 line snippets)
- Use task template from task-template.md
- Set priority: {priority-level}
- Assign to: {specialist-agent}
- Identify dependencies: {task-ids or "none"}
- **Worktree**: {kebab-case-slug} — REQUIRED for code-mutating tasks; tasks touching the same
  surface SHARE a slug; use literal "none" ONLY for research/docs-only tasks. An empty `Worktree:`
  on a code task is a FATAL doctor violation that blocks `/go`. NEVER use one-slug-per-task.
- **PR Group**: {kebab-case-slug} — defaults to the same value as Worktree
- **Touches Globs**: {comma-separated file globs} or "none" — the files this task modifies
- File naming: {category}-{XXX}-{descriptive-name}.md
- Create in: .backlog/pending/
- Commit: task: create {category}-{id}-{name}

**Pre-Creation Validation**:
- Uniqueness: grep .backlog/pending/ for similar tasks
- Task size: ≤8 hours (split if larger)
- Tech stack: Specify clearly
- "Out of Scope": Mandatory section present
- Worktree/PR Group/Touches Globs present (code tasks) or all "none" (non-code)

**Deliverable**:
Task file in .backlog/pending/ following all requirements.
```

### Step 7: Verify dependencies

When every task-engineer agent has finished, spawn one more to check the set:

```markdown
**Agent**: task-engineer

**Task**: Verify task dependencies and uniqueness

**Scope**:
- Check all tasks in .backlog/pending/ created by previous agents
- Verify task IDs are sequential and unique
- Check dependencies are valid (no circular deps)
- Confirm no duplicate work
- Validate file naming conventions
- **Verify every code-mutating task has a kebab-case `Worktree:` slug (never empty, never equal to
  the task id), a `PR Group:`, and `Touches Globs:`; non-code tasks must use `Worktree: none` and
  `Touches Globs: none`. Run the doctor as the final check: `bash ${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store doctor` — fix any FATAL before exit.**

**Deliverable**:
Validation report confirming tasks are ready for execution.
If issues found, fix them.
```

### Step 8: Report and exit

Report the task creation summary, then exit. Do not implement any task, start work on the backlog,
review code, run tests, or make any commit other than the task files.

The tasks now wait in `.backlog/pending/` for `/go`.

---

## Pre-creation validation

Before you spawn task-engineer agents, check four things.

**Uniqueness.** Search pending tasks for similar work:
```bash
grep -r "authentication" .backlog/pending/
```

If a similar task exists, adjust the scope so the work is not done twice.

**Service setup.** For a new service, setup and config are one task. Do not split infrastructure from
implementation.

**Tech stack.** Name it: the language and framework, the key libraries, and the quality gate commands.

**Scope boundary.** Every task **must** have an "Out of Scope" section that says what not to do, what
to delegate, and what is future work.

---

## Decomposition examples

### Good: one task per feature

**Scope**: "Implement user authentication system"

**Tasks**:
1. **User Authentication API** (backend-001-user-auth-api.md)
   - WHAT: JWT-based authentication with login/logout endpoints
   - WHY: Only signed-in users get access
   - Includes: API, validation, token generation, tests

2. **User Profile Management** (backend-002-user-profile-mgmt.md)
   - WHAT: CRUD endpoints for user profile data
   - WHY: Users manage their own information
   - Includes: API, validation, database, tests

3. **Password Reset Flow** (backend-003-password-reset-flow.md)
   - WHAT: Email-based password reset with secure tokens
   - WHY: Users who lose their password can recover the account
   - Includes: API, email service, token management, tests

Each task is a complete, independent feature.

### Bad: over-decomposition

The same scope, split into:
1. Create database schema
2. Create API endpoint structure
3. Add input validation
4. Implement JWT generation
5. Write unit tests
6. Write integration tests
7. Update API documentation
8. Add monitoring

These micro-tasks only make sense together, and none of them delivers anything until all eight are
done.

---

## Style guide violations

### Bad: implementation details

````markdown
## Task Description
Implement authentication using this approach:

1. Install jsonwebtoken library
2. Create middleware function:
```javascript
function authenticateToken(req, res, next) {
  const token = req.headers['authorization'];
  // ... 30 lines of implementation
}
```
3. Use bcrypt for password hashing
4. Configure JWT_SECRET in .env
````

This tells the specialist how to build it, in 50+ lines of code.

### Good: WHAT and WHY only

```markdown
## Task Description
API authenticates users and issues JWT tokens.

**WHAT**: POST /api/v1/auth/login endpoint
**WHY**: Enable secure user authentication
**CONSTRAINTS**:
- Response < 200ms
- Secure token generation (industry standard)
- Token expiry: 1 hour

## Acceptance Criteria
- [ ] Accepts email + password
- [ ] Returns 200 with JWT token for valid credentials
- [ ] Returns 401 for invalid credentials
- [ ] Returns 400 for missing fields
- [ ] Token expires in 1 hour
- [ ] Tests cover all scenarios
```

The specialist knows what to build and why, and decides how.

---

## Done when (legacy loop)

- You read the style guide.
- Research is done: Perplexity, plus Figma and Context7 as needed.
- The scope is split into atomic tasks.
- Every task passed the style check.
- TodoWrite was called once, with all tasks.
- The task-engineer agents were spawned in parallel, in one message.
- The dependency verification agent ran after the tasks were created.
- The command exited without implementing anything.

---

## Anti-patterns

| Don't | Do instead |
|---|---|
| Start coding, writing tests or running builds | Delegate to task-engineer agents and exit |
| Spend hours researching implementation details | Spend 5-10 minutes on the scope; specialists work out the details |
| Split one feature into database, API and test tasks | One logical feature, one task |
| Tell specialists which libraries, patterns or approaches to use | Define what to build, why, and the constraints |

---

## Output format

The legacy loop reports progress in this shape:

```
🔥 Task Decomposition Started

Step 1: Reading style guide...
✓ Style guide loaded: docs/acf/style/task-descriptions.md

Step 2: Minimal research...
✓ Perplexity: Best practices for authentication systems
✓ Perplexity: Common pitfalls in JWT implementation
✓ Context7: Library capabilities for auth tokens

Step 3: Decomposing scope...
✓ Identified 3 atomic tasks:
  1. User authentication API (backend)
  2. User profile management (backend)
  3. Password reset flow (backend + email)

Step 4: Validating against style guide...
✓ All tasks follow WHAT/WHY pattern
✓ No implementation details
✓ Binary, testable criteria
✓ Max 2-3 line code snippets

Step 5: Creating todos...
✓ TodoWrite: 4 tasks (3 features + 1 verification)

Step 6: Spawning task-engineer agents (parallel)...
→ Agent 1: Creating backend-001-user-auth-api.md
→ Agent 2: Creating backend-002-user-profile-mgmt.md
→ Agent 3: Creating backend-003-password-reset-flow.md
→ Agent 4: Verifying dependencies

[Agents execute in parallel...]

✅ Task decomposition complete!

Created tasks:
- backend-001-user-auth-api.md (high priority, go-engineer)
- backend-002-user-profile-mgmt.md (high priority, go-engineer)
- backend-003-password-reset-flow.md (medium priority, go-engineer)

Dependencies verified: No circular dependencies, IDs sequential

Next step: Run /go to execute backlog automatically
```
