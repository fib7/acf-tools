# Task Backlog System

## Overview

The `.backlog/` directory contains all task specifications in a structured workflow. Tasks move through states from `pending` to terminal states (`accepted` or `blocked`).

This README summarizes the task workflow for this project. `docs/acf/backlog/workflow.md` owns the
state machine and the State Transition Authority table: where this README disagrees with either of
those two, workflow.md wins. All agents MUST read this README as Priority 1 documentation.

## Directory Structure

```
.backlog/
├── draft/          # User-controlled drafts (EXCLUDED from automation)
├── pending/        # Tasks ready to start
├── in-progress/    # Currently being worked on
├── completed/      # Finished, awaiting quality review
├── in-review/      # Under quality-reviewer assessment
├── blocked/        # Blocked by dependencies or issues
├── rejected/       # Failed quality review (/go retries it, up to its retry cap)
├── accepted/       # Passed quality review (DONE - terminal state)
└── archive/        # Historical tasks (optional)
```

## Task State Machine

```
pending → in-progress → completed → in-review → [accepted|rejected]
            ↓                                          ↓
         blocked                                    rejected → pending (retry)
```

**Terminal States**:
- `accepted` - Passed quality review
- `blocked` - Stopped: its specialist blocked it, it timed out, or it hit `/go`'s retry cap. `/go`
  returns it to `pending` when its dependencies resolve and it is still under the cap.

## Installed Agents

The following agents are available in this project:

### Universal Agents
- **task-engineer**: Task decomposition (WHAT/WHY only, no HOW)
- **quality-reviewer**: Binary accept/reject decisions
- **lean-architect**: System architecture (WHAT/WHY, max 2-3 line code snippets)
- **retro**: Retrospectives: root causes, one-rule lessons, proposed action items (a human approves every change)
- **precommit**: Pre-commit hook configuration
- **research-agent**: Evidence-based research with Perplexity/Context7

### Implementation Agents
- **{{IMPLEMENTER_AGENTS}}**: Specialist implementation agents

## Priority 1 Documentation (MUST READ for Every Task)

ALL agents MUST read on receiving a task:

1. **This README** (`.backlog/README.md`) - Workflow, priorities, evidence requirements
2. **Task Description Style Guide** (`docs/acf/style/task-descriptions.md`) - ABSOLUTE requirements
3. **Task Template** (`docs/acf/backlog/task-template.md`) - Task file structure
4. **Workflow Details** (`docs/acf/backlog/workflow.md`) - State machine, transition rules
5. **Agent Manifest** (`docs/agents/{agent-name}.md`) - Agent-specific Priority 1/2/3 docs

## Concurrency Model (CRITICAL)

**Parallel across worktrees, sequential within a worktree.** Every code-mutating task declares:

- `Worktree: <slug>` (required) — implementer specialists run one-at-a-time per worktree slug
- `PR Group: <slug>` (defaults to Worktree value) — sibling tasks ship together

Implementer specialists and quality-reviewer invoke the `clean-checkout-before-task` skill as Step 0. The skill creates a git worktree at `.worktree/<slug>` on branch `worktree/<slug>`, validates the branch, stashes unrelated changes, and logs the `clean-checkout: ok` token to the task transition log. Without that token, quality-reviewer auto-rejects.

Specialist commits land on `worktree/<slug>` and hold code only: never a task file, never anything
under `.backlog/`, never a commit on trunk. quality-reviewer commits nothing.

**Integration is automatic by default.** Once a task is accepted, `/go` cherry-picks its change onto the **local** trunk and CAS-lands it with an in-tree ledger marker (LP-CAS). Nothing is pushed and no PR is opened — the change is on your local trunk, waiting for you to push. If your process requires a PR per group with human review, pin the mode instead of relying on prose:

```bash
# .acfwhip/config (committed) — or .backlog/.acfw-config, whichever this project has
ACFW_INTEGRATION_MODE=override
```

In `override` mode `/go` stops at `accepted`, writes no marker, keeps each `worktree/<slug>` branch alive for you to push and PR from, and hands ordering to you. Unpinned, `/go` decides per run by reading `CLAUDE.md`. See `docs/acf/backlog/workflow.md` § Integration.

See `docs/acf/backlog/workflow.md` for the full state machine and dispatch rules.

## Task File Template

Every task file MUST follow this structure (from `docs/acf/backlog/task-template.md`):

1. **Metadata**: ID, status, priority, hours, agent, **Worktree**, **PR Group**, dependencies, rejection_count, timestamps
2. **Description**: Binary outcome (WHAT/WHY only, no HOW)
3. **Acceptance Criteria**: Checkboxes, testable, binary
4. **Technical Requirements**: Implementation details, testing, performance
5. **Edge Cases to Handle**: Explicit handling requirements
6. **Out of Scope**: What NOT to do (MANDATORY section)
7. **Quality Review Checklist**: For implementer and quality-reviewer
8. **Transition Log**: Timestamped state changes with agent names. task-engineer writes the creation
   row. After that, `/go` writes the state rows, clean-checkout writes its token row, `/task` adds a
   hold row to a task it parks in `draft`, and `/whip-move` logs a manual move. Never a specialist or
   the reviewer.
9. **Implementation Notes**: Developer notes during work
10. **Quality Review Comments**: Round-by-round review feedback
11. **Evidence of Completion**: Quality gate outputs (complete commands + results)

## Priority Levels

Five levels, highest first. `/go` accepts all five; a small project can use just `high`, `medium` and
`low`.

| Priority | SLA (deadline) | Cycle Time Target (stretch goal) |
|----------|----------------|-----------------------------------|
| **blocker** | 1h | 30min |
| **critical** | 4h | 2h |
| **high** | 24h | 6h |
| **medium** | 1 week | 2 days |
| **low** | none | none |

Priority orders tasks within a worktree partition. It does not let tasks run in parallel across
partitions; the partition rule does that.

## Evidence Requirements

**Every completed task MUST provide complete evidence**:

1. **Quality Gate Outputs**: ALL commands with complete output (not truncated)
2. **Test Results**: Full test output with coverage report
3. **Implementation Commit**: SHA, files changed, commit message
4. **Transition Log**: written by `/go` (state rows) and clean-checkout (its token row), never by a
   specialist or the reviewer. A task under review must carry the clean-checkout token
5. **Task-Specific Verification**: Screenshots, API samples, metrics (as appropriate)

**Authenticity Checks** (quality-reviewer validates):
- Command outputs complete (no "..." omissions)
- Timestamps present
- Exit codes shown
- No placeholders
- Raw output format

## State Transition Authority

All state moves happen at the repo root, on the trunk branch.

| From | To | WHO performs the move |
|------|----|-----------------------|
| N/A | pending | task-engineer, through `/task` (creation only) |
| pending | in-progress | `/go`, before it dispatches the specialist |
| in-progress | completed | `/go`, on the specialist's `transition: completed` |
| in-progress | blocked | `/go`, on the specialist's `transition: blocked` (adds 1 to `Block-Count`), or on timeout |
| completed | in-review | `/go`, before it dispatches quality-reviewer |
| in-review | accepted | `/go`, on the reviewer's `transition: accepted` |
| in-review | rejected | `/go`, on the reviewer's `transition: rejected` (adds 1 to `Rejection Count`) |
| rejected | pending | `/go`, on retry, while the task is under its retry cap |
| rejected | blocked | `/go`, at the retry cap. The task waits for task-engineer to redesign it |
| blocked | pending | `/go`, when the dependencies resolve and both counts are under the cap |

**Only `/go` moves a task.** Specialists and quality-reviewer return an `ACFW-RESULT` marker and stop.
`/go`'s single writer then moves the file, rewrites `Status` to the new folder, appends the Transition
Log row, and commits all three together on trunk. An agent that moves the task itself turns that
commit into a no-op, which drops the counter increment and leaves `Status` out of step with the folder.
On the legacy markdown loop (no workflow support) the orchestrator dispatches task-engineer at the
repo root for retry, unblock and redesign, then commits the move itself. An operator can move one task
by hand with `/whip-move`, also at the repo root and never in a worktree.

## Workflow Guidelines

### For task-engineer

1. **Read Style Guide**: `docs/acf/style/task-descriptions.md` (MANDATORY)
2. **Decompose Requirements**: Create atomic tasks with binary acceptance criteria
3. **WHAT/WHY Only**: NEVER specify HOW (specialists decide implementation)
4. **Max 2-3 Line Code Snippets**: Signatures/shapes only, NO implementations
5. **Use Task Template**: Follow structure from `docs/acf/backlog/task-template.md`
6. **Pre-Creation Validation**: Uniqueness, size ≤8h, tech stack specified, "Out of Scope" present
7. **Create in pending/** at the repo root, never in a worktree: filename `{category}-{XXX}-{descriptive-name}.md`
8. **Creation is the only move you make**: `/task` commits the new task (`task: create ...`). Every
   later move belongs to `/go`.

### For Implementer Agents (Specialists)

1. **Step 0: clean-checkout-before-task**: Invoke the skill before any edit; it creates the worktree, validates the branch, logs the OK token. Without the token, quality-reviewer rejects.
2. **Read Priority 1 Docs**: This README, style guide, task template, manifest
3. **Leave task state alone**: `/go` moved the task to `in-progress` before it dispatched you. Do not
   move the task file, edit its `Status`, or write Transition Log rows.
4. **Implement Task**: Decide HOW (task specifies WHAT/WHY); all edits happen inside `.worktree/<slug>` on branch `worktree/<slug>`
5. **Run Quality Gates**: ALL stack-specific quality gates MUST pass
6. **Commit code only** on `worktree/<slug>`: never the task file, never anything under `.backlog/`,
   never a commit on trunk
7. **Provide Complete Evidence**: Command outputs, test results, coverage, commit SHA on
   `worktree/<slug>`, written into the task document at the path `/go` gave you
8. **Return the `ACFW-RESULT` marker**: `transition: completed` or `blocked`, with `commit_sha`.
   `/go` performs the move.

### For quality-reviewer

1. **Verify the clean-checkout token FIRST** — before Step 0, because Step 0 writes that same row.
   The transition log must contain a `clean-checkout | ok` line. If it does not: no worktree branch
   means nothing was ever checked out (reject, charge a rejection); a branch that exists means the row
   was lost (reject as a *mechanism* fault, charge nothing).
2. **Step 0: clean-checkout-before-task**: Invoke the skill (idempotent; validates the worktree the implementer used)
3. **Read Priority 1 Docs**: This README, workflow, quality gates
4. **Verify ALL Acceptance Criteria**: Every checkbox must be checked
5. **Validate Quality Gates**: ALL commands must have complete output
6. **Check Test Coverage**: Meet thresholds (API 90-95%, Core 90%, Services 85-90%, Utils 85%)
7. **Binary Decision**: Accept OR reject (no partial approvals)
8. **Return the `ACFW-RESULT` marker**: `transition: accepted | rejected`, with `fault_class` set to
   `mechanism` when the failure is not the task's fault. **The orchestrator performs the state move,
   on every backend.** Do not move the task, do not edit its `Status`, and do not maintain
   `rejection_count` — the runtime owns the retry cap and blocks a task that exhausts it.

> Moving the task yourself is worse than useless: the orchestrator's writer is idempotent, so a task
> you already moved makes its transition a no-op — which silently drops the rejection increment and
> leaves a `Status`/folder mismatch for `/whip-doctor` to find.

## Quality Gates Integration

Stack-specific quality gates live in `docs/development/quality-gates-{stack}.md` when `/whip-init`
installed one for your stack. Without one, each specialist's gate commands are in its manifest
(`docs/agents/<agent>.md`). `ACFW_GATE_CMD` in the project config (`.acfwhip/config` or
`.backlog/.acfw-config`, whichever exists), when set, is the gate `/go` runs on every change before it
lands on trunk.

**Zero Bypass Tolerance**:
- ❌ FORBIDDEN: `git commit --no-verify`, `SKIP={hook}`, lowering thresholds
- ✅ REQUIRED: Fix actual issues, maintain quality standards

## Git Commit Protocol (MANDATORY)

Two kinds of commit, made by different hands. Never mix them.

- **Task-state commits** land on trunk, at the repo root. `/go`'s single writer makes each one: the
  file move, the `Status` rewrite and the Transition Log row in one commit, subject
  `task: <stem>.md <from> -> <to>` (the task's file name, `.md` included, so
  `git log --grep 'task: api-001-login.md in-progress'` finds it). `/task` commits new tasks
  (`task: create ...`) and `/whip-move` commits a manual move. No specialist or reviewer ever makes
  one.
- **Code commits** land on `worktree/<slug>`, made by the specialist. They hold code only: never the
  task file, never anything under `.backlog/`.

**FORBIDDEN**:
- ❌ `git add -A` or `git add .`
- ❌ `git commit -a`
- ❌ Staging a task file or anything under `.backlog/` on a `worktree/<slug>` branch
- ❌ `git commit --no-verify`

**REQUIRED**:
- ✅ Explicit file staging
- ✅ Conventional commit messages

## Commands

### Where Am I
```bash
/whip
/whip "<goal>"
```
Shows the cycle stage, what needs you, and the one command to run next. With a goal, small work goes
straight to `/task`; risky work gets a plan you approve with one "yes".

### Task Decomposition
```bash
/task "Scope description"
```
Decomposes scope into atomic tasks. Uses task-engineer agents in parallel. NEVER implements.

### Continuous Backlog Execution
```bash
/go
/go <task-id>...
/go --all
```
A bare `/go` runs your focus: the tasks your last `/task` created. With no focus, the default `files`
store runs the whole backlog. `/go <task-id>...` runs exactly those tasks plus their unmet
dependencies, and `/go --all` runs everything. It loops until every task in scope is accepted or
blocked.

### Retrospective Analysis
```bash
/retro
```
Closes a planned cycle. A clean cycle closes with zero agents. When a task was reworked or stuck, or a
deliverable is not met, a retro agent writes the retro doc, at most 3 one-rule lessons in
`docs/acf/lessons/`, and a retro-actions cycle you approve like any plan. It never creates tasks, edits
agent files, or deletes a lesson itself. `/retro --force <task>...` analyzes work done without a plan.

### Generate Specialist Agents
```bash
/whip-add-agents
/whip-add-agents --backend=go --frontend=react
```
Analyzes repo and creates missing specialist agents + manifests following ACF conventions.

## References

- **Workflow Details**: `docs/acf/backlog/workflow.md` (state machine, transition rules)
- **Task Template**: `docs/acf/backlog/task-template.md` (task file structure)
- **Task Style Guide**: `docs/acf/style/task-descriptions.md` (WHAT/WHY only, binary criteria)
- **Quality Gates**: `docs/development/quality-gates-{stack}.md` (stack-specific requirements, if present)
- **Git Conventions**: `docs/acf/git/commit-conventions.md` (if exists)
- **Agent Manifests**: `docs/agents/{agent-name}.md` (Priority 1/2/3 documentation)

---

**Last Updated**: Auto-generated by ACF Whip SessionStart hook
**Installed Agents**: Scanned from `.claude/agents/*.md`
