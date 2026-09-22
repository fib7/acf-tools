---
name: task
description: Decompose scope into atomic tasks using task-engineer agents. Pure orchestration - NEVER implements anything.
argument-hint: "[scope description]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - TodoWrite
  - Task
  - Workflow
  - mcp__perplexity__perplexity_search_web
  - mcp__context7__resolve-library-id
  - mcp__context7__get-library-docs
  - mcp__figma-dev-mode-mcp-server__get_code
---

# /task - Pure Orchestration & Task Decomposition

**CRITICAL**: This command ONLY orchestrates. It NEVER implements anything.

Pure delegation tool that decomposes complex scope into independent atomic tasks for parallel execution.

---

## Execution: workflow-first, legacy fallback

acf-whip ships a deterministic decomposition **workflow** that enforces worktree slugs and an
acyclic dependency graph **before any task file is written** (schema-required slugs → a JS
validation gate → a create-time doctor). Prefer it: the loop and the intermediate plan live in a
script, not in your context.

**If the `Workflow` tool is available to you** (dynamic workflows enabled, Claude Code ≥ 2.1.154):

1. Resolve the environment with one bash call at the repo root:
   ```bash
   echo "PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"
   echo "TRUNK_ROOT=$(git rev-parse --show-toplevel)"
   echo "TRUNK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)"
   bash "$CLAUDE_PLUGIN_ROOT/skills/lib/bin/acfw-store" info
   ```
   The `acfw-store info` line reports the active task-store backend (`store`, default `files`) —
   pass it through in step 2.
2. Launch the workflow (runs in the background; intermediate state never enters your context):
   ```
   Workflow({
     name: "acf-whip:whip-task",
     args: {
       scope: "<the full /task argument text, verbatim>",
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
       models: <info.models>
     }
   })
   ```
3. When it completes, report the returned summary: created task ids + slugs + dependencies, the
   commit sha, and the doctor verdict. Also say that a bare `/go` will now run exactly these tasks
   (the run returns `focus{}`): `/task` points this checkout's run focus at what it just created, so
   the operator never has to name ids for the work they just planned. `/go --all` remains the way to
   run the whole backlog. `models`/`agentsByTier` report which tier ran how many agents.
   If it returns `aborted: true`, surface the `defects` list and
   **STOP** — do NOT hand-write task files to route around the validation gate. If it returns
   `error`, **or the `Workflow` call is refused outright**, fall back to the legacy path below — a
   denied tool call returns no value at all, so the `error` branch never sees it. Never retry with
   `scriptPath` and never edit the user's settings.
4. Do **not** also run the legacy steps — the workflow replaces them.

**Launch by NAME, never by path.** `scriptPath` is checked against the readable set (the working
directory plus any added directory); on a real marketplace install the plugin lives under
`~/.claude/plugins/cache/`, which is neither, so a `scriptPath` launch is refused for every user who
installed this plugin normally. The registry resolves `acf-whip:whip-task` without touching a path.

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
mcp__perplexity__perplexity_search_web:
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

mcp__context7__get-library-docs:
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
