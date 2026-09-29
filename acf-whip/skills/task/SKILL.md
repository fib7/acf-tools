---
name: task
description: Decompose scope into atomic tasks using task-engineer agents. Pure orchestration - NEVER implements anything.
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

# /task - Pure Orchestration & Task Decomposition

**CRITICAL**: This command ONLY orchestrates. It NEVER implements anything.

Pure delegation tool that decomposes complex scope into independent atomic tasks for parallel execution.

---

## Plan mode: `/task --plan [<cycle>]`

`/task --plan` decomposes an approved cycle plan (`docs/cycles/<ID>/plan.md`, drafted and approved
through `/whip`) instead of free text. After you answer "yes" on an approval card, `/whip` starts it for
you. You can also run it by hand. If the argument does not start with `--plan`, skip this section: the
run is free text and everything below applies unchanged.

Do these in order:

1. **Read the argument.** Everything after `--plan` is ONE plan reference: a cycle ID
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
   itself. Do not pre-check approval, coverage or locks in prose.
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
     and nothing else. If `cycle.dropped` is not empty, name those ids: each one already belonged to
     an existing task, so the store refused it and this run's claim on it was taken back out of the
     cycle record. Someone else's task is then neither in the cycle record nor in your focus. One of
     this cycle's own tasks from an earlier run keeps the deliverables it already had.
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
- The writer runs `acfw-cycle record` **first**, so the task map is committed before any task exists.
  Every command that creates, stages, commits or sets the focus runs only after record succeeded, so
  a refused record creates nothing.
- A new task never reuses an existing id. The validation gate refuses an id the backlog already has.
  If one still collides when the store creates it, the writer takes it back out of the cycle record in
  the same command, so a teammate's task never counts as this plan's coverage or enters your focus.
- The run focus is **set** (replaced) to the cycle's unfinished tasks. A free-text `/task` adds to it.
- The decomposition lock is released on every exit the run controls, and only while it still carries
  this run's stamp, so a run never deletes another run's lock. If a run is killed, the lock expires
  after 30 minutes, and `/whip` prints its age and the `rm` command to clear it sooner. A run that
  outlives the 30 minutes and finds its lock taken over stops before recording anything.

**Lessons apply in both modes.** The planners and the critic run
`acfw-cycle lessons` (read-only) and copy a relevant rule into the `constraints` of any task that walks
into it. `/retro` records those rules in `docs/acf/lessons/`.

---

## Execution: workflow-first, legacy fallback

acf-whip ships a deterministic decomposition **workflow** that enforces worktree slugs and an
acyclic dependency graph **before any task file is written** (schema-required slugs → a JS
validation gate → a create-time doctor). Prefer it: the loop and the intermediate plan live in a
script, not in your context.

**If the `Workflow` tool is available to you** (dynamic workflows enabled, Claude Code ≥ 2.1.154):

1. Resolve the environment with one bash call at the repo root:
   ```bash
   echo "PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
   echo "TRUNK_ROOT=$(git rev-parse --show-toplevel)"
   echo "TRUNK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)"
   bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info
   echo "SPEC_TASK_TOOLS=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-spec" list --at task --machine 2>/dev/null | grep -c '^TOOL|')"
   ```
   The `acfw-store info` line is one JSON object; step 2 consumes three fields from it: the active
   task-store backend (`store`, default `files`), the per-tier model routing (`models`) and the
   shell-tier effort pin (`efforts`). Pass all three through verbatim. `SPEC_TASK_TOOLS` is the number
   of spec tools that review tasks (declared in `.acfwhip/spec-tools/` with `at=` naming `task`); it is
   `0` in a project without them, and then nothing about the run changes.
2. Launch the workflow (runs in the background; intermediate state never enters your context):
   ```
   Workflow({
     name: "acf-whip:whip-task",
     args: {
       scope: "<the full /task argument text, verbatim>",
       // Plan mode ONLY (3.5.0): the --plan reference, verbatim, INSTEAD of scope. Never pass both:
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
3. When it completes, report the returned summary: created task ids + slugs + dependencies, the
   commit sha, and the doctor verdict. Also say that a bare `/go` will now run exactly these tasks
   (the run returns `focus{}`): `/task` points this checkout's run focus at what it just created, so
   the operator never has to name ids for the work they just planned. `/go --all` remains the way to
   run the whole backlog. `models`/`agentsByTier` report which tier ran how many agents — counted
   where an agent is charged, so a retried call shows up as the two agents it actually cost.
   When the report has a `review` block, the tasks were reviewed by spec tools before they were
   written: report it as described under "Task-stage spec review" below. A task in `review.held`
   is **not** in the focus, and a bare `/go` will not run it. A task in `review.waiting` is in the
   focus, but it depends on a held task, so `/go` will not run it until that task is released: do
   not count it among the tasks a bare `/go` runs now.
   If it returns `aborted: true`, surface the `defects` list and
   **STOP** — do NOT hand-write task files to route around the validation gate. If it returns
   `error`, **or the `Workflow` call is refused outright**, fall back to the legacy path below — a
   denied tool call returns no value at all, so the `error` branch never sees it. Never retry with
   `scriptPath` and never edit the user's settings.
4. Do **not** also run the legacy steps — the workflow replaces them.

### Task-stage spec review

A spec tool is a reviewer a project declares in `.acfwhip/spec-tools/<name>` (`/whip --tools add
<name>` sets one up). One whose `at=` names `task` reviews every task `/task` authors, before it is
written to the task store. Without such a tool, none of this happens.

What the run does when one exists:
- Authors write every task document to `.acfwhip/run/staging/` first, on the `files` store too, so
  a bare `/go` never sees a task nobody reviewed.
- One shell agent runs the review. The script checks that every verdict line arrived and asks once
  more if some did not; finished tools come from the review cache, so that costs nothing.
- A task a `policy=block` tool rejects with findings gets ONE repair round: a task-engineer reads the
  findings and edits the body only. If the repair changed the title, the Metadata section or the
  Transition Log, the original document is put back. Then the task is reviewed again.
- A task a `policy=block` tool still rejects is **held in draft**. It is created (and, with `--plan`,
  recorded as the cycle's task), but in `draft`, with a Transition Log row like
  `| <time> | pending | draft | spec-review | held: no-tbd nogo n=2; /whip --review <stem> |`,
  and it is **not** added to your focus.
- A tool that could not run (verdict `skip`) or failed (`error`) never holds a task. An `advisory`
  tool never holds a task either; its findings are reported and nothing else happens.
- A `block` tool with no result it can stand behind for those exact bytes reports `nogo`, so the
  task is held: the tool is not trusted on this machine yet, its declaration has local edits, the
  task document holds a credential literal, or the review ran out of time. Its `path` in the report
  is then a `held.md` that says which, and no repair runs, because no edit to the task fixes it. If
  the verdicts could not be read back, even after the second try, every `block` tool that has no
  verdict for a task holds that task too. No tool gave a verdict there, so the entry is marked
  `unreviewed` and the row says `held: <tool> unreviewed (verdict not relayed)`. The run reads the
  list of tools twice (once at the start, once with the verdicts). If neither list arrived whole
  either, it cannot tell which tools block, so it holds each such task under the name `unknown`.
- A task that depends on a held task is not held, and it goes into your focus, but `/go` will not
  run it until the held task is released. It is listed in `review.waiting` with the held ids it
  waits on.

How to report `review`: say how many tasks were reviewed and by which tools (`review.tools`). If
`review.verdicts` is 0, say that no tool actually reviewed anything (spec tools are switched off
with `ACFW_SPEC=off`, or the declarations went away during the run). If `review.relay` starts with
`short:`, say that the verdicts did not all arrive and that some tasks may be held for that reason
alone. Name each repaired task, and say when `metaRestored` is true
(the repair touched metadata, so it was thrown away). For each entry of `review.held`, print the id,
each tool with its `n` (or `unreviewed` when the entry says so), and the `next` command. For each
entry of `review.waiting`, say which held task it waits on. For `review.notes`, give one line per
advisory finding, skip or error. Do not re-run the review yourself, and do not move a held task out
of draft.

Releasing a held task is the user's call: `/whip --review <stem>` shows why it was held. After fixing
the task, `/whip-move <stem> pending` releases it, and `/whip-focus add <stem>` (or `/go <stem>`)
runs it.

The legacy loop below runs no task-stage review. If `SPEC_TASK_TOOLS` was above 0 and you fall back
to it, tell the user that the tasks it wrote were not reviewed by spec tools, and that
`/whip --review <stem>` reviews one.

**Launch by NAME, never by path.** `scriptPath` is checked against the readable set (the working
directory plus any added directory); on a real marketplace install the plugin lives under
`~/.claude/plugins/cache/`, which is neither, so a `scriptPath` launch is refused for every user who
installed this plugin normally. The registry resolves `acf-whip:whip-task` without touching a path.

**The legacy loop has no plan mode.** A `/task --plan` run never falls back to it (see Plan mode,
rule 3).

**The legacy loop is `files`-backend ONLY.** It writes and commits task documents directly into
`.backlog/pending/`. On `beads`, `multica`, `linear` or a third-party adapter there is no such
directory, and files written there are invisible to the store — the tasks simply do not exist, while
the run reports success. `/go` states the same fence for its own fallback.

So **resolve the backend before falling back**: `bash "${CLAUDE_PLUGIN_ROOT}/skills/lib/bin/acfw-store" info`.
That call is made inside the `Workflow` branch above, so on this path you may not have run it yet. If
`store` is anything other than `files`, report the refusal and **STOP** — do not improvise, and do not
write `.backlog/` files on a store that does not use them.

**Only if the `Workflow` tool is NOT available or cannot resolve the workflow** (dynamic workflows
disabled, `CLAUDE_WORKFLOW_NAME_ONLY` set — which enumerates built-ins only, so no plugin workflow
resolves under either form — or older Claude Code) **AND the resolved store is `files`**:
run the legacy decomposition loop below (Steps 1–8). It produces the same task files — including the
mandatory `Worktree:` / `PR Group:` / `Touches Globs:` slug fields — but as a single-context
orchestration.

---

## 🔥 MANDATORY: Style Enforcement

**Before creating ANY tasks, read and enforce**: `docs/acf/style/task-descriptions.md`

### ABSOLUTE PROHIBITIONS

- Function/method implementations in task descriptions
- Algorithm pseudocode
- Step-by-step HOW instructions (specialists decide HOW)
- Vague language: "comprehensive", "robust", "enhance", "optimize"
- Code snippets beyond 2-3 lines (signatures/shapes only)

### REQUIRED

- Binary language: "API validates token" NOT "improve validation"
- WHAT/WHY only: NEVER HOW
- Testable criteria: "Returns 401 for missing token"
- Specific outcomes: "Response < 200ms" NOT "fast"

**Validation Step** (MANDATORY before spawning task-engineer agents):
1. Read `docs/acf/style/task-descriptions.md`
2. Verify your task decomposition follows rules
3. If any task violates rules, REVISE before agent spawning

---

## Command Flow

### Step 1: Read Style Guide

**MANDATORY FIRST STEP**:
```markdown
Read docs/acf/style/task-descriptions.md
```

This guide defines ABSOLUTE requirements for task descriptions:
- WHAT/WHY only (never HOW)
- Binary, testable language
- Max 2-3 line code snippets
- Banned words and phrases

### Step 2: Minimal Research (Scope Understanding ONLY)

#### Perplexity (MANDATORY)

Use Perplexity for best practices, patterns, pitfalls:

```markdown
mcp__perplexity__perplexity_search:
- "best practices for {feature-type} implementation {tech-stack}"
- "common pitfalls when building {feature-type}"
- "architecture patterns for {feature-type}"
- "testing strategies for {feature-type}"
```

**Focus**: What to build, why, what constraints. NOT how to implement.

#### Figma (MANDATORY if URL/node provided)

If Figma URL or node ID mentioned:

1. **Extract node ID** from URL:
   - Format: `https://figma.com/design/:fileKey/:fileName?node-id=1-2`
   - Extract: `1:2`

2. **Call get_code**:
```markdown
mcp__figma-dev-mode-mcp-server__get_code:
  nodeId: "1:2"
```

3. **Extract UI requirements**:
   - Component structure
   - Layout requirements
   - Interactive elements
   - Data bindings

**Use for**: WHAT to build (component specs), NOT HOW to implement.

#### Context7 (When Needed)

For library capabilities:

```markdown
mcp__context7__resolve-library-id:
  libraryName: "{library-name}"

mcp__context7__query-docs:
  context7CompatibleLibraryID: "/org/project"
  topic: "{feature-relevant-topic}"
```

**Use for**: What library can do, NOT how to use it.

#### File Analysis (Project Context)

Quick scans for existing patterns:

```bash
# Find related code
grep -r "similar-feature" --include="*.{go,py,ts,tsx}"

# Find architectural patterns
glob "**/*{service,controller,handler}*"
```

**Limit**: 5 minutes max. You're orchestrating, not researching deeply.

### Step 3: Decompose Scope Into Atomic Tasks

#### Atomic Decomposition Strategy

**One Logical Feature = One Task** (not micro-tasks):

✅ **GOOD**: Single task "User Authentication API"
- Includes: API endpoint, validation, token generation, tests, docs

❌ **BAD**: 5 micro-tasks
- "Create API endpoint"
- "Add input validation"
- "Implement JWT generation"
- "Write tests"
- "Update docs"

**Mixed Stack Work = Single Task**:

✅ **GOOD**: "User Profile Feature" (backend API + frontend component)
❌ **BAD**: Separate "Backend API" and "Frontend Component" tasks

#### Task Decomposition Rules

For each task, define:
- **WHAT**: Binary outcome, testable
- **WHY**: Business value, user impact
- **CONSTRAINTS**: Performance, security, compatibility requirements
- **OUT OF SCOPE**: What NOT to do (mandatory)

**DO NOT define**:
- HOW to implement
- Which libraries to use
- Code structure
- Implementation details

### Step 4: Validate Against Style Guide

**Self-check BEFORE spawning agents**:

For each task:
- ✅ Binary, testable description?
- ✅ WHAT/WHY only (no HOW)?
- ✅ Max 2-3 line code snippets?
- ✅ No banned words?
- ✅ Specific, measurable criteria?

If ANY task fails, REVISE before proceeding.

### Step 5: TodoWrite (Single Call, All Tasks)

Create todos for ALL tasks in single TodoWrite call:

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

**Include final verification task**: Dependency validation

### Step 6: Spawn task-engineer Agents (Parallel)

Launch ONE task-engineer agent per task in **SINGLE MESSAGE** with multiple Task calls:

```markdown
Task 1: task-engineer for User Authentication
Task 2: task-engineer for User Profile Management
Task 3: task-engineer for Password Reset Flow
Task 4: task-engineer for Dependency Verification
```

**Agent Instructions Template**:

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

### Step 7: Dependency Verification Agent (Final)

After all task-engineer agents complete, spawn ONE MORE agent to verify:

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

### Step 8: Exit Immediately

**DO NOT**:
- ❌ Implement any tasks
- ❌ Start work on backlog
- ❌ Review code
- ❌ Run tests
- ❌ Make commits beyond task file creation

**DO**:
- ✅ Report task creation summary
- ✅ Exit

Tasks are now in `.backlog/pending/` ready for `/go` command.

---

## Pre-Creation Validation

Before spawning task-engineer agents, validate:

### A. Uniqueness Check

Search pending tasks for similar work:
```bash
grep -r "authentication" .backlog/pending/
```

If similar tasks exist, adjust scope to avoid duplication.

### B. Service Setup

If creating new service:
- Setup + config = ONE task (not separate)
- Don't split infrastructure from implementation

### C. Tech Stack

Specify tech stack clearly:
- Language/framework
- Key libraries
- Quality gate commands

### D. Scope Boundary

Every task MUST include "Out of Scope" section:
- What NOT to do
- What to delegate
- What's future work

---

## Atomic Decomposition Examples

### ✅ GOOD: Proper Decomposition

**Scope**: "Implement user authentication system"

**Tasks**:
1. **User Authentication API** (backend-001-user-auth-api.md)
   - WHAT: JWT-based authentication with login/logout endpoints
   - WHY: Enable secure user access
   - Includes: API, validation, token generation, tests

2. **User Profile Management** (backend-002-user-profile-mgmt.md)
   - WHAT: CRUD endpoints for user profile data
   - WHY: Allow users to manage their information
   - Includes: API, validation, database, tests

3. **Password Reset Flow** (backend-003-password-reset-flow.md)
   - WHAT: Email-based password reset with secure tokens
   - WHY: Account recovery mechanism
   - Includes: API, email service, token management, tests

**Atomic**: Each task is complete, independent feature.

### ❌ BAD: Over-Decomposition

**Scope**: "Implement user authentication system"

**Tasks**:
1. Create database schema
2. Create API endpoint structure
3. Add input validation
4. Implement JWT generation
5. Write unit tests
6. Write integration tests
7. Update API documentation
8. Add monitoring

**Problem**: Micro-tasks that must be done together. No value delivered until all complete.

---

## Style Guide Violations (Common Mistakes)

### ❌ BAD: Implementation Details

```markdown
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
```

**Problem**: Telling specialist HOW to implement. 50+ lines of code.

### ✅ GOOD: WHAT/WHY Only

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

**Good**: Specialist knows WHAT and WHY. Decides HOW.

---

## Usage Examples

### Basic Usage

```bash
/task "Implement user authentication system with JWT tokens"
```

### With Context

```bash
/task "Add real-time notifications using WebSocket. Figma: https://figma.com/design/ABC123/App?node-id=1-2"
```

### Complex Scope

```bash
/task "Migrate user service from REST to GraphQL API. Maintain backward compatibility with v1 endpoints during transition."
```

### From an Approved Plan

```bash
/task --plan 20260928-owner-seat-notice
/task --plan docs/cycles/20260928-owner-seat-notice/plan.md
/task --plan        # the cycle /whip says is next
```

---

## Success Criteria

✅ Style guide read and understood
✅ Research completed (Perplexity, Figma, Context7 as needed)
✅ Scope decomposed into atomic tasks
✅ All tasks validated against style guide
✅ TodoWrite called once with all tasks
✅ task-engineer agents spawned in parallel (single message)
✅ Dependency verification agent spawned after creation
✅ Command exits without implementing

---

## Anti-Patterns

### ❌ Implementing Tasks

**Never**: Start coding, writing tests, running builds
**Always**: Delegate to task-engineer, exit immediately

### ❌ Deep Research

**Never**: Spend hours researching implementation details
**Always**: 5-10 minutes for scope understanding, delegate details to specialists

### ❌ Micro-Task Decomposition

**Never**: Break into database/API/tests as separate tasks
**Always**: One logical feature = one task

### ❌ HOW Instructions

**Never**: Tell specialists which libraries, patterns, approaches to use
**Always**: Define WHAT needs to be built, WHY, and constraints

---

## Output Format

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
