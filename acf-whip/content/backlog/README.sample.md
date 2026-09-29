# Task Backlog System

## Overview

`.backlog/` holds this project's task files, one per task, each in the folder for its current state.
A task starts in `pending` and stops in one of the two terminal states, `accepted` or `blocked`.

This README summarizes the task workflow for this project. `docs/acf/backlog/workflow.md` owns the
state machine and the State Transition Authority table: where this README disagrees with either of
those two, workflow.md wins. Every agent must read this README as Priority 1 documentation.

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
- `accepted`: passed quality review.
- `blocked`: stopped. Its specialist blocked it, it timed out, or it hit `/go`'s retry cap. `/go`
  returns it to `pending` when its dependencies resolve and it is still under the cap.

## Installed Agents

### Universal Agents
- **task-engineer**: Task decomposition (WHAT/WHY only, no HOW)
- **quality-reviewer**: Binary accept/reject decisions
- **lean-architect**: System architecture (WHAT/WHY, max 2-3 line code snippets)
- **retro**: Retrospectives: root causes, one-rule lessons, proposed action items (a human approves every change)
- **precommit**: Pre-commit hook configuration
- **research-agent**: Evidence-based research with Perplexity/Context7

### Implementation Agents
- **{{IMPLEMENTER_AGENTS}}**: Specialist implementation agents

## Priority 1 Documentation (read for every task)

Every agent must read these when it receives a task:

1. **This README** (`.backlog/README.md`): workflow, priorities, evidence requirements
2. **Task Description Style Guide** (`docs/acf/style/task-descriptions.md`): its rules have no exceptions
3. **Task Template** (`docs/acf/backlog/task-template.md`): task file structure
4. **Workflow Details** (`docs/acf/backlog/workflow.md`): state machine, transition rules
5. **Agent Manifest** (`docs/agents/{agent-name}.md`): the agent's own Priority 1/2/3 docs

## Concurrency Model

**Parallel across worktrees, sequential within a worktree.** Every code-mutating task declares:

- `Worktree: <slug>` (required). Implementer specialists run one at a time per slug.
- `PR Group: <slug>` (defaults to the Worktree value). Sibling tasks ship together.

Implementer specialists and quality-reviewer invoke the `clean-checkout-before-task` skill as Step 0.
It creates a git worktree at `.worktree/<slug>` on branch `worktree/<slug>`, validates the branch,
stashes unrelated changes, and logs the `clean-checkout: ok` token to the task's transition log.
Without that token, quality-reviewer rejects the task automatically.

Specialist commits land on `worktree/<slug>` and hold code only: never a task file, never anything
under `.backlog/`, never a commit on trunk. quality-reviewer commits nothing.

**Integration is automatic by default.** Once a task is accepted, `/go` cherry-picks its change onto
the **local** trunk and lands it by compare-and-swap, together with an in-tree ledger marker (LP-CAS).
Nothing is pushed and no PR is opened: the change waits on your local trunk until you push it. If your
process needs a PR per group with human review, pin the mode in config rather than describing it in
prose:

```bash
# .acfwhip/config (committed) — or .backlog/.acfw-config, whichever this project has
ACFW_INTEGRATION_MODE=override
```

In `override` mode `/go` stops at `accepted`, writes no marker, keeps each `worktree/<slug>` branch
alive for you to push and open a PR from, and leaves the ordering to you. Unpinned, `/go` decides each
run by reading `CLAUDE.md`. `docs/acf/backlog/workflow.md` has the full state machine and dispatch
rules, and covers both modes under § Integration.

## Task File Template

Every task file must follow this structure, from `docs/acf/backlog/task-template.md`:

1. **Metadata**: ID, status, priority, hours, agent, **Worktree**, **PR Group**, dependencies, rejection_count, timestamps
2. **Description**: the binary outcome (WHAT/WHY only, no HOW)
3. **Acceptance Criteria**: checkboxes, each testable and binary
4. **Technical Requirements**: implementation details, testing, performance
5. **Edge Cases to Handle**: each case and how it must be handled
6. **Out of Scope**: what not to do. The section is required.
7. **Quality Review Checklist**: for the implementer and quality-reviewer
8. **Transition Log**: Timestamped state changes with agent names. task-engineer writes the creation
   row. After that, `/go` writes the state rows, clean-checkout writes its token row, `/task` adds a
   hold row to a task it parks in `draft`, and `/whip-move` logs a manual move. Never a specialist or
   the reviewer.
9. **Implementation Notes**: the implementer's notes while working
10. **Quality Review Comments**: review feedback, one block per round
11. **Evidence of Completion**: every quality gate command with its full output

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

Every completed task must carry complete evidence:

1. **Quality Gate Outputs**: every command, with its whole output, never truncated
2. **Test Results**: the full test output, with a coverage report
3. **Implementation Commit**: SHA, files changed, commit message
4. **Transition Log**: written by `/go` (state rows) and clean-checkout (its token row), never by a
   specialist or the reviewer. A task under review must carry the clean-checkout token
5. **Task-Specific Verification**: screenshots, API samples or metrics, as the task needs

quality-reviewer also checks that the evidence is authentic:
- Command outputs complete (no "..." omissions)
- Timestamps present
- Exit codes shown
- No placeholders
- Raw output format

## State Transition Authority

All state moves happen at the repo root, on the trunk branch.

| From | To | Who performs the move |
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

1. **Read the Style Guide**: `docs/acf/style/task-descriptions.md`. Required.
2. **Decompose Requirements**: split the scope into atomic tasks with binary acceptance criteria
3. **WHAT/WHY Only**: never specify HOW; the specialist decides the implementation
4. **Max 2-3 Line Code Snippets**: signatures and shapes only, never an implementation
5. **Use the Task Template**: follow the structure in `docs/acf/backlog/task-template.md`
6. **Pre-Creation Validation**: Uniqueness, size ≤8h, tech stack specified, "Out of Scope" present
7. **Create in pending/** at the repo root, never in a worktree: filename `{category}-{XXX}-{descriptive-name}.md`
8. **Creation is the only move you make**: `/task` commits the new task (`task: create ...`). Every
   later move belongs to `/go`.

### For Implementer Agents (Specialists)

1. **Step 0: clean-checkout-before-task**: invoke the skill before any edit. It creates the worktree,
   validates the branch and logs the OK token; without the token, quality-reviewer rejects.
2. **Read Priority 1 Docs**: this README, the style guide, the task template, your manifest
3. **Leave task state alone**: `/go` moved the task to `in-progress` before it dispatched you. Do not
   move the task file, edit its `Status`, or write Transition Log rows.
4. **Implement the Task**: you decide HOW; the task gives WHAT and WHY. Every edit happens inside
   `.worktree/<slug>` on branch `worktree/<slug>`.
5. **Run Quality Gates**: every stack-specific quality gate must pass
6. **Commit code only** on `worktree/<slug>`: never the task file, never anything under `.backlog/`,
   never a commit on trunk
7. **Provide Complete Evidence**: Command outputs, test results, coverage, commit SHA on
   `worktree/<slug>`, written into the task document at the path `/go` gave you
8. **Return the `ACFW-RESULT` marker**: `transition: completed` or `blocked`, with `commit_sha`.
   `/go` performs the move.

### For quality-reviewer

1. **Check the clean-checkout token first, before Step 0**, because Step 0 writes that same row.
   The transition log must contain a `clean-checkout | ok` line. If it does not: no worktree branch
   means nothing was ever checked out (reject, charge a rejection); a branch that exists means the row
   was lost (reject as a *mechanism* fault, charge nothing).
2. **Step 0: clean-checkout-before-task**: invoke the skill. It is idempotent and validates the
   worktree the implementer used.
3. **Read Priority 1 Docs**: this README, the workflow, the quality gates
4. **Verify every acceptance criterion**: each checkbox must be checked
5. **Validate Quality Gates**: every command must show its complete output
6. **Check Test Coverage**: Meet thresholds (API 90-95%, Core 90%, Services 85-90%, Utils 85%)
7. **Binary Decision**: accept or reject; there is no partial approval
8. **Return the `ACFW-RESULT` marker**: `transition: accepted | rejected`, with `fault_class` set to
   `mechanism` when the failure is not the task's fault. **The orchestrator performs the state move,
   on every backend.** Do not move the task, do not edit its `Status`, and do not maintain
   `rejection_count`. The runtime owns the retry cap and blocks a task that exhausts it.

> Moving the task yourself does damage. The orchestrator's writer is idempotent, so it finds the task
> already moved and makes its transition a no-op. That drops the rejection increment without a trace
> and leaves a `Status`/folder mismatch for `/whip-doctor` to find.

## Quality Gates Integration

Stack-specific quality gates live in `docs/development/quality-gates-{stack}.md` when `/whip-init`
installed one for your stack. Without one, each specialist's gate commands are in its manifest
(`docs/agents/<agent>.md`). `ACFW_GATE_CMD` in the project config (`.acfwhip/config` or
`.backlog/.acfw-config`, whichever exists), when set, is the gate `/go` runs on every change before it
lands on trunk.

**Zero Bypass Tolerance**: no `git commit --no-verify`, no `SKIP={hook}`, no lowered thresholds. Fix
the failure instead.

## Git Commit Protocol

Two kinds of commit, made by different hands. Never mix them.

- **Task-state commits** land on trunk, at the repo root. `/go`'s single writer makes each one: the
  file move, the `Status` rewrite and the Transition Log row in one commit, subject
  `task: <stem>.md <from> -> <to>` (the task's file name, `.md` included, so
  `git log --grep 'task: api-001-login.md in-progress'` finds it). `/task` commits new tasks
  (`task: create ...`) and `/whip-move` commits a manual move. No specialist or reviewer ever makes
  one.
- **Code commits** land on `worktree/<slug>`, made by the specialist. They hold code only: never the
  task file, never anything under `.backlog/`.

**Never**:
- `git add -A` or `git add .`
- `git commit -a`
- Stage a task file or anything under `.backlog/` on a `worktree/<slug>` branch
- `git commit --no-verify`

**Always**:
- Stage files by explicit path
- Write conventional commit messages

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
Splits a scope into atomic tasks, with task-engineer agents working in parallel. It never implements
anything.

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
Scans the repo and creates the specialist agents and manifests it is missing, following ACF
conventions.

## References

- **Workflow Details**: `docs/acf/backlog/workflow.md` (state machine, transition rules)
- **Task Template**: `docs/acf/backlog/task-template.md` (task file structure)
- **Task Style Guide**: `docs/acf/style/task-descriptions.md` (WHAT/WHY only, binary criteria)
- **Quality Gates**: `docs/development/quality-gates-{stack}.md` (stack-specific requirements, if present)
- **Git Conventions**: `docs/acf/git/commit-conventions.md` (if present)
- **Agent Manifests**: `docs/agents/{agent-name}.md` (Priority 1/2/3 documentation)

---

**Generated by**: `/whip-init`, or `/whip-add-agents` when this file is missing. Afterwards both only
update the Implementation Agents line.
**Installed Agents**: Scanned from `.claude/agents/*.md`
