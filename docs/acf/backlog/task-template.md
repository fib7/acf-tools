<!-- acf-whip-artifact: content/backlog/task-template.md v3.4.0 -->
# Task Template

## MANDATORY: Use this exact format for all task files

```markdown
# Task: [Clear Task Title]

## Metadata

- **ID**: [category-XXX-descriptive-name]
- **Status**: pending
- **Priority**: [blocker|critical|high|medium|low]
- **Estimated Hours**: [realistic estimate]
- **Assigned Agent**: [one of the project's INSTALLED agents — check `ls .claude/agents/*.md` (whip-init generates e.g. go-engineer, python-engineer, nodejs-engineer, nextjs-engineer, react-engineer, vue-engineer, infrastructure-engineer, quality-reviewer, task-engineer, research-agent). Must resolve to `.claude/agents/<name>.md`, else the doctor flags FATAL unknown-agent.]
- **Worktree**: [kebab-case-slug] (REQUIRED for code-mutating tasks; use "none" ONLY for research/docs-only tasks. Orchestrator dispatches one specialist per worktree-slug; tasks sharing a slug run strictly sequentially. An empty slug on a code task is a FATAL doctor violation and blocks `/go`.)
- **PR Group**: [kebab-case-slug] (defaults to the same value as Worktree; sibling tasks ship together as one PR)
- **Touches Globs**: [comma-separated file globs this task will modify, e.g. `services/user-api/**, go.mod`] or "none" (used by the doctor to WARN when two different-slug pending tasks overlap — a mis-partition signal)
- **Dependencies**: [task-id-1, task-id-2] or "none"
- **Integrated-At**: (INERT as of 3.0.0 / LP-CAS — kept only for display. Integration truth is the in-tree ledger marker `.acfwhip/integrated/<shard>/<key>.json` on trunk, written by `integrate-lpcas`; nothing reads this field.)
- **Rejection Count**: 0 (max 3; quality-reviewer increments on reject; at the cap the task is blocked for task-engineer redesign. A review reporting `faultClass: mechanism` — a broken environment, a lost clean-checkout token — does NOT increment it.)
- **Block-Count**: 0 (per-task re-block counter; `/go` increments when a specialist re-blocks a dispatched task and stops re-dispatching once it reaches the cap, parking the task for an operator)
- **Created By**: task-engineer
- **Created At**: $(date +"%Y-%m-%d %H:%M:%S") UTC
- **Documentation**: [existing docs agent must read first, or "none"]

## Description

[Clear description of what needs to be done, why it's needed, and expected outcome]

## Acceptance Criteria

- [ ] [Specific, testable criterion 1]
- [ ] [Specific, testable criterion 2]
- [ ] [Specific, testable criterion 3]
- [ ] All tests pass (unit, integration, e2e as applicable)
- [ ] Quality gates pass (golangci-lint/go test/ruff/mypy/pytest as applicable)
- [ ] Documentation updated if needed
- [ ] Changes committed with proper conventional commit message

## Technical Requirements

### Implementation Details

- [Specific technical requirement 1]
- [Specific technical requirement 2]
- [Files/services to modify]
- [Patterns to follow]

### Testing Requirements

- Unit tests for: [specific functions/components]
- Integration tests for: [specific flows, multi-service interactions]
- E2E tests for: [critical user paths]

### Performance Requirements

- [Response time targets]
- [Query performance requirements]
- [Resource usage constraints]

## Edge Cases to Handle

- [Edge case 1]: [How to handle]
- [Edge case 2]: [How to handle]
- [Error scenario]: [Error handling approach]

## Out of Scope

- [Explicitly what NOT to do]
- [What's handled elsewhere]
- [Future considerations]

## Quality Review Checklist

### For Implementer (Before Marking Complete)

- [ ] All acceptance criteria checked
- [ ] Tests written and passing
- [ ] Code follows project conventions
- [ ] No debug code or print statements
- [ ] Error handling implemented
- [ ] Performance requirements met
- [ ] Structured logging added

### For Quality Reviewer (quality-reviewer agent)

- [ ] Implementation matches requirements
- [ ] Code quality standards met
- [ ] Test coverage adequate (≥80% overall, 100% critical paths)
- [ ] Security best practices followed
- [ ] Documentation accurate
- [ ] Git commit follows conventions
- [ ] Architecture compliance (service boundaries, patterns)

## Transition Log

<!-- DO NOT EDIT MANUALLY - Agents update this section -->
<!-- Each transition MUST include: CURRENT timestamp, from_status, to_status, agent, reason -->
<!-- MANDATORY: Always get current timestamp before logging, NEVER use placeholders -->

| Date Time                    | From  | To      | Agent         | Reason/Comment        |
| ---------------------------- | ----- | ------- | ------------- | --------------------- |
| $(date +"%Y-%m-%d %H:%M:%S") | draft | pending | task-engineer | Initial task creation |

**Concurrency token (mandatory for code-mutating tasks)**: implementer specialists and quality-reviewer invoke `clean-checkout-before-task` as Step 0. The skill appends a line in this exact form, where `<status>` is literally `ok`:

```
| <UTC ts> | clean-checkout | <status> | clean-checkout-before-task | <slug> | <branch> |
```

Do **not** copy that line into a task document by hand. `<status>` is a placeholder here on purpose:
the completed row is what `snapshot.hasCleanCheckoutToken` and the reviewer's pre-review check both
grep for, so a document containing it claims a checkout that never happened — and silently disables
the one diagnostic aimed at that condition.

Quality-reviewer auto-rejects any task in `.backlog/in-review/` whose transition log lacks at least one `clean-checkout | ok` line.

**Integration (default mode, 3.0.0 / LP-CAS)**: `integrate-lpcas` lands the task's in-tree ledger marker
(`.acfwhip/integrated/<shard>/<key>.json`) on trunk, co-committed with the change in one single-parent
commit, after the union gate passes. The marker's presence on trunk IS the integration record; the
integrator does **not** write the task markdown. If the union gate fails, the orchestrator moves the task
to `.backlog/rejected/` (rejection +1) so it re-enters the self-heal; a cherry-pick conflict routes to a
resolver (mechanism), never a silent drop.

The existing rejection/retry/block machinery picks up from there.

## Implementation Notes

<!-- Implementer adds notes during development -->

[Space for implementation notes, discoveries, decisions made during development]

## Quality Review Comments

<!-- quality-reviewer agent adds review feedback here -->

### Review Round 1

- **Date**: [Date]
- **Reviewer**: quality-reviewer
- **Decision**: [accepted|rejected]
- **Comments**:
  - [Specific feedback point 1]
  - [Specific feedback point 2]

### Review Round 2 (if rejected)

- **Date**: [Date]
- **Reviewer**: quality-reviewer
- **Decision**: [accepted|rejected]
- **Comments**:
  - [Issue resolution confirmation]

## Version Control Log

<!-- Implementer agent updates this when committing task file changes -->

| Date Time           | Git Action | Agent   | Commit Hash | Message                                   |
| ------------------- | ---------- | ------- | ----------- | ----------------------------------------- |
| YYYY-MM-DD HH:MM:SS | add        | [agent] | [hash]      | "task: start [task-id]"                   |
| YYYY-MM-DD HH:MM:SS | commit     | [agent] | [hash]      | "task: complete [task-id] with [summary]" |

## Evidence of Completion

<!-- Paste evidence showing task is complete -->

```bash
# Go service quality gates
$ golangci-lint run ./...
✓ No errors

$ go test ./... -v -race -cover
✓ All tests pass (X tests)
✓ Coverage: Y%

$ go build ./...
✓ Build successful

# Python service quality gates
$ ruff check .
✓ No errors

$ mypy . --strict
✓ No type errors

$ pytest --cov --cov-report=term
✓ All tests pass (X tests)
✓ Coverage: Y%

# Docker health checks
$ make health
✓ All services healthy

# Integration tests (if applicable)
$ pytest tests/integration/
✓ All integration tests pass

# Git status
$ git status
On branch main
nothing to commit, working tree clean
```

## References

- [Link to related PR]
- [Link to design docs]
- [Link to API docs]
- [Link to discussion]
```

---

## Template Usage Rules

### Documentation Field Usage

- **PURPOSE**: Lists EXISTING documentation for input context
- **NOT FOR**: Output files this task will create (that goes in Description)
- **AUTO-LOADED** (don't list): CLAUDE.md, agent manifests (docs/agents/*.md)
- **VERIFY**: task-engineer validates all referenced files exist before task creation
- **USE "none"**: When only auto-loaded docs needed

**Examples**:
```markdown
# Foundation docs needed:
- **Documentation**: docs/architecture/system-architecture.md, docs/architecture/execution-platform.md

# Research relevant:
- **Documentation**: docs/research/temporal-workflow-patterns.md

# Only CLAUDE.md needed:
- **Documentation**: none
```

### 1. Task Creation (task-engineer)

- MUST use this exact template
- MUST fill all required fields
- MUST verify Documentation field references exist
- MUST NOT include implementation code
- MUST commit task file when creating

### 2. Task Pickup (implementation agents)

- MUST invoke `clean-checkout-before-task` as Step 0 with `TASK_FILE` = the **root** path the orchestrator passed (creates worktree, validates branch, appends OK token to the root file)
- All CODE reads, edits, and commits happen inside the worktree on `worktree/<slug>` (never on the trunk branch)
- MUST NOT move task files between `.backlog/<state>/` folders — that's the orchestrator's job at root
- MUST NOT commit `.backlog/` changes on `worktree/<slug>`
- MUST add evidence of completion to the root task file (write the file directly at its root path)
- MUST end response with the ACFW-RESULT marker (`transition: completed | blocked`)

### 3. Task Completion (implementation agents)

- MUST check all acceptance criteria
- MUST run quality gates and capture output (see docs/development/quality-gates.md)
- MUST add evidence to the root task file BEFORE returning the marker
- MUST commit code (and only code) on `worktree/<slug>`
- MUST return ACFW-RESULT with the final code commit SHA

### 4. Quality Review (quality-reviewer)

- MUST invoke `clean-checkout-before-task` as Step 0 (idempotent; validates the worktree the implementer used)
- MUST verify the transition log contains at least one `clean-checkout | ok` line; emit `transition: rejected` with `rejection_increment: 1` if absent
- MUST add review comments in designated section of the root task file
- MUST end response with the ACFW-RESULT marker (`transition: accepted | rejected`)
- MUST NOT move the task file (the orchestrator performs the in-review→accepted/rejected move at root)
- MUST provide specific feedback in `notes` and the Quality Review Comments section if rejecting

---

## Git Commit Protocol

**Where commits land**:
- **task-engineer** commits on the trunk branch at the repo root (`.backlog/pending/` creations, retry/unblock/redesign moves). NEVER enters a worktree.
- **`/go` orchestrator** commits all `.backlog/` state-machine moves on the trunk branch at the repo root (pending→in-progress, in-progress→completed/blocked, completed→in-review, in-review→accepted/rejected, accepted→accepted with `Integrated-At:`).
- **Implementer specialists and quality-reviewer** commit only **code** inside `.worktree/<slug>` on `worktree/<slug>`. They do NOT move task files and do NOT commit `.backlog/` changes on the worktree branch — they signal state via the ACFW-RESULT marker; the orchestrator performs the move at root.
- **`integrate-lpcas`** (orchestrator-driven, default mode) cherry-picks each accepted task's single-parent candidate onto the live trunk and CAS-lands it with a co-committed ledger marker. Override via `CLAUDE.md` (e.g. PR-per-group) is honored automatically.

### When Creating Task (task-engineer)

```bash
git add .backlog/pending/feature-001-yaml-processor.md
git commit -m "task: create feature-001-yaml-processor

- Define YAML processing requirements
- Set acceptance criteria
- Assign to go-engineer"
```

### When Starting Task (implementation agent)

```bash
git add .backlog/in-progress/feature-001-yaml-processor.md
git commit -m "task: start feature-001-yaml-processor"
```

### When Completing Task (implementation agent)

```bash
git add .backlog/completed/feature-001-yaml-processor.md
git add services/yaml-processor/processor.go
git add services/yaml-processor/processor_test.go
git commit -m "feat: implement YAML processor service

- Add YAML parsing with gopkg.in/yaml.v3
- Generate Temporal workflow specifications
- Integrate with Method Registry validation
- Include unit tests

Task: feature-001-yaml-processor"
```

### When Reviewing Task (quality-reviewer)

```bash
# If accepting
git add .backlog/accepted/feature-001-yaml-processor.md
git commit -m "review: accept feature-001-yaml-processor

- All criteria met
- Quality gates pass
- Test coverage adequate"

# If rejecting
git add .backlog/rejected/feature-001-yaml-processor.md
git commit -m "review: reject feature-001-yaml-processor

- Missing error handling in YAML parser
- Test coverage below 80%
- See review comments for details"
```

---

## File Naming Convention

```
[category]-[XXX]-[descriptive-name].md

Categories:
- feature: New functionality
- bug: Bug fixes
- infra: Infrastructure/DevOps
- test: Testing tasks
- docs: Documentation
- refactor: Code refactoring
- data: Data engineering (Dagster, Delta Lake)
- ml: Machine learning (model serving, BentoML)

Examples:
feature-001-yaml-processor-implementation.md
feature-002-temporal-pipeline-workflows.md
bug-001-catalog-stub-nil-pointer.md
infra-001-gke-multi-zone-deployment.md
test-001-user-api-integration-tests.md
docs-001-temporal-workflow-patterns.md
data-001-dagster-bronze-silver-transform.md
ml-001-bentoml-face-recognition-deployment.md
```

---

## Template Validation

**task-engineer MUST validate**:
- All required fields populated
- Priority is valid enum (blocker|critical|high|medium|low)
- Dependencies exist or "none"
- Assigned agent exists and is valid for ODP
- At least 3 acceptance criteria
- Technical requirements specific
- Edge cases identified

**quality-reviewer MUST validate**:
- All acceptance criteria have evidence
- Transition log complete
- Implementation notes present
- Quality gates evidence provided (language-appropriate)
- Version control log accurate
- Architecture compliance (service boundaries, event-driven patterns)

---

**Last Updated**: 2025-10-27
**Document Owner**: task-engineer
