# Task Backlog System

## Overview

The `.backlog/` directory contains all task specifications in a structured workflow. Tasks move through states from `pending` to terminal states (`accepted` or `blocked`).

This README is the **single source of truth** for task workflow. All agents MUST read this as Priority 1 documentation.

## Directory Structure

```
.backlog/
├── draft/          # User-controlled drafts (EXCLUDED from automation)
├── pending/        # Tasks ready to start
├── in-progress/    # Currently being worked on
├── completed/      # Finished, awaiting quality review
├── in-review/      # Under quality-reviewer assessment
├── blocked/        # Blocked by dependencies or issues
├── rejected/       # Failed quality review (retry if < 3 attempts)
├── accepted/       # Passed quality review (DONE - terminal state)
└── archive/        # Historical tasks (optional)
```

## Task State Machine

```
pending → in-progress → completed → in-review → [accepted | rejected]
            ↓                                          ↓
         blocked                                    pending (retry)
```

**Terminal States**:
- `accepted` - Successfully completed and passed quality review
- `blocked` - Failed after max retries (3) or unresolvable dependencies

## Installed Agents

The following agents are available in this project:

### Universal Agents
- **task-engineer**: Task decomposition (WHAT/WHY only, no HOW)
- **quality-reviewer**: Binary accept/reject decisions
- **lean-architect**: System architecture (WHAT/WHY, max 2-3 line code snippets)
- **retro**: Process improvement and retrospectives
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

All implementer/reviewer commits land on `worktree/<slug>`, never on `main`. Integration to `main` (PR via `gh pr create` or fast-forward merge) is project-decided.

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
8. **Transition Log**: Timestamped state changes with agent names
9. **Implementation Notes**: Developer notes during work
10. **Quality Review Comments**: Round-by-round review feedback
11. **Evidence of Completion**: Quality gate outputs (complete commands + results)

## Priority Levels

This project uses a **3-level priority system**:

| Priority | Description | Cycle Time Target |
|----------|-------------|-------------------|
| **high** | Critical path, blocks other work | Start immediately |
| **medium** | Important but not blocking | Start after high |
| **low** | Nice to have, can be deferred | Start after medium |

## Evidence Requirements

**Every completed task MUST provide complete evidence**:

1. **Quality Gate Outputs**: ALL commands with complete output (not truncated)
2. **Test Results**: Full test output with coverage report
3. **Implementation Commit**: SHA, files changed, commit message
4. **Transition Log**: Timestamps, agents, state changes, reasons
5. **Task-Specific Verification**: Screenshots, API samples, metrics (as appropriate)

**Authenticity Checks** (quality-reviewer validates):
- Command outputs complete (no "..." omissions)
- Timestamps present
- Exit codes shown
- No placeholders
- Raw output format

## State Transition Authority

| From | To | WHO moves file & updates transition log |
|------|----|----------------------------------------|
| N/A | pending | task-engineer |
| pending | in-progress | Implementer agent (specialist) |
| in-progress | completed | Implementer agent |
| in-progress | blocked | Implementer agent (or timeout) |
| completed | in-review | quality-reviewer |
| in-review | accepted | quality-reviewer |
| in-review | rejected | quality-reviewer |
| rejected | pending | task-engineer (retry, max 3 attempts) |
| rejected | blocked | task-engineer (≥3 retries) |
| blocked | pending | task-engineer (dependencies resolved) |

**The agent DOING the work moves the file and updates the transition log.**

## Workflow Guidelines

### For task-engineer

1. **Read Style Guide**: `docs/acf/style/task-descriptions.md` (MANDATORY)
2. **Decompose Requirements**: Create atomic tasks with binary acceptance criteria
3. **WHAT/WHY Only**: NEVER specify HOW (specialists decide implementation)
4. **Max 2-3 Line Code Snippets**: Signatures/shapes only, NO implementations
5. **Use Task Template**: Follow structure from `docs/acf/backlog/task-template.md`
6. **Pre-Creation Validation**: Uniqueness, size ≤8h, tech stack specified, "Out of Scope" present
7. **Create in pending/**: Filename: `{category}-{XXX}-{descriptive-name}.md`
8. **Commit**: `task: create {category}-{id}-{name}`

### For Implementer Agents (Specialists)

1. **Step 0: clean-checkout-before-task**: Invoke the skill before any edit; it creates the worktree, validates the branch, logs the OK token. Without the token, quality-reviewer rejects.
2. **Read Priority 1 Docs**: This README, style guide, task template, manifest
3. **Move to in-progress**: Start of work (state move happens inside the worktree)
4. **Update Transition Log**: Every state change with timestamp
5. **Implement Task**: Decide HOW (task specifies WHAT/WHY); all edits happen inside `.worktree/<slug>` on branch `worktree/<slug>`
6. **Run Quality Gates**: ALL stack-specific quality gates MUST pass
7. **Provide Complete Evidence**: Command outputs, test results, coverage, commit SHA on `worktree/<slug>`
8. **Move to completed**: After all criteria met and evidence provided
9. **Commit with Task File**: Atomic commit (code + task file) on `worktree/<slug>`. Never commit on `main`.

### For quality-reviewer

1. **Step 0: clean-checkout-before-task**: Invoke the skill (idempotent; validates the worktree the implementer used)
2. **Verify clean-checkout token**: Transition log MUST contain at least one `clean-checkout | ok` line. Auto-reject if absent.
3. **Read Priority 1 Docs**: This README, workflow, quality gates
4. **Move to in-review**: Start of review (inside the worktree)
5. **Verify ALL Acceptance Criteria**: Every checkbox must be checked
6. **Check rejection_count**: If ≥5, escalate to task-engineer (don't reject again)
7. **Validate Quality Gates**: ALL commands must have complete output
8. **Check Test Coverage**: Meet thresholds (API 90-95%, Core 90%, Services 85-90%, Utils 85%)
9. **Binary Decision**: Accept OR reject (no partial approvals)
10. **MANDATORY: Move to Terminal State**: accepted/ OR rejected/ (NEVER leave in in-review/) inside the worktree
11. **Update rejection_count**: Increment if rejecting
12. **Commit**: `review: accept|reject {task-id}` on `worktree/<slug>`

## Quality Gates Integration

Stack-specific quality gates are documented in:
- `docs/development/quality-gates-{stack}.md`

**Common stacks**:
- Go: `docs/development/quality-gates-go.md`
- Python: `docs/development/quality-gates-python.md`
- Node.js: `docs/development/quality-gates-nodejs.md`
- React: `docs/development/quality-gates-react.md`
- Next.js: `docs/development/quality-gates-nextjs.md`

**Zero Bypass Tolerance**:
- ❌ FORBIDDEN: `git commit --no-verify`, `SKIP={hook}`, lowering thresholds
- ✅ REQUIRED: Fix actual issues, maintain quality standards

## Git Commit Protocol (MANDATORY)

**Task files MUST be committed at every stage transition**:

1. **Task Creation** → pending: `task: create {category}-{id}-{name}`
2. **Task Start** → in-progress: `task: start {category}-{id}-{name}`
3. **Implementation Progress**: Include task file WITH code changes (atomic commits)
4. **Task Completion** → completed: `task: complete {category}-{id}-{name}` (CRITICAL)
5. **Quality Review Start** → in-review: `review: begin quality review`
6. **Review Decision** → accepted/rejected: `review: accept|reject {category}-{id}-{name}`

**FORBIDDEN**:
- ❌ `git add -A` or `git add .`
- ❌ `git commit -a`
- ❌ Leaving task files uncommitted

**REQUIRED**:
- ✅ Explicit file staging
- ✅ Atomic commits (task file WITH code changes)
- ✅ Conventional commit messages

## Commands

### Task Decomposition
```bash
/task "Scope description"
```
Decomposes scope into atomic tasks. Uses task-engineer agents in parallel. NEVER implements.

### Continuous Backlog Execution
```bash
/go
```
Executes entire backlog until 100% complete (all tasks in accepted/blocked). Loops continuously.

### Retrospective Analysis
```bash
/retro
```
Analyzes blocked/rejected tasks, creates improvement tasks. Two-phase: retro agent → task-engineer.

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
- **Quality Gates**: `docs/development/quality-gates-{stack}.md` (stack-specific requirements)
- **Git Conventions**: `docs/acf/git/commit-conventions.md` (if exists)
- **Agent Manifests**: `docs/agents/{agent-name}.md` (Priority 1/2/3 documentation)

---

**Last Updated**: Auto-generated by ACF Whip SessionStart hook
**Installed Agents**: Scanned from `.claude/agents/*.md`
