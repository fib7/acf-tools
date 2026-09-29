<!-- acf-whip-artifact: content/backlog/task-template.md v3.5.0 -->
# Task Template

## Use this exact format for every task file

```markdown
# Task: [Clear Task Title]

## Metadata

- **ID**: [category-XXX-descriptive-name]
- **Status**: pending
- **Priority**: [blocker|critical|high|medium|low]
- **Estimated Hours**: [realistic estimate]
- **Assigned Agent**: [one of the project's installed agents; check `ls .claude/agents/*.md` (whip-init generates e.g. go-engineer, python-engineer, nodejs-engineer, nextjs-engineer, react-engineer, vue-engineer, infrastructure-engineer, quality-reviewer, task-engineer, research-agent). It must resolve to `.claude/agents/<name>.md`, or the doctor flags FATAL unknown-agent.]
- **Worktree**: [kebab-case-slug] (Required for code-mutating tasks; use "none" only for research or docs-only tasks. The orchestrator dispatches one specialist per slug at a time, so tasks that share a slug run one after another. If an active code task has no slug, `/whip-doctor --fix` (which `/go` runs at startup) derives one from its id.)
- **PR Group**: [kebab-case-slug] (defaults to the same value as Worktree; sibling tasks ship together as one PR)
- **Touches Globs**: [comma-separated file globs this task will modify, e.g. `services/user-api/**, go.mod`] or "none" (the doctor WARNs when two pending tasks on different slugs overlap, a sign the partition is wrong)
- **Dependencies**: [task-id-1, task-id-2] or "none"
- **Integrated-At**: (Since 3.0.0 / LP-CAS this is display and operator-ack metadata. The integrator never reads or writes it: integration truth is the in-tree ledger marker `.acfwhip/integrated/<shard>/<key>.json` on trunk, written by `integrate-lpcas`. Set it only through `/whip-move --integrated-at`.)
- **Rejection Count**: 0 (max 3. `/go` adds 1 when quality-reviewer rejects; at the cap it blocks the task for task-engineer to redesign. A review reporting `faultClass: mechanism`, such as a broken environment or a lost clean-checkout token, does not add to it.)
- **Block-Count**: 0 (per-task re-block counter. `/go` adds 1 each time a specialist re-blocks a dispatched task, and stops re-dispatching at the cap, parking the task for an operator)
- **Created By**: task-engineer
- **Created At**: $(date +"%Y-%m-%d %H:%M:%S") UTC
- **Documentation**: [existing docs agent must read first, or "none"]

## Description

[What needs to be done, why it is needed, and the expected outcome]

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

- [What not to do, stated explicitly]
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
grep for, so a document containing it claims a checkout that never happened, and silently disables
the one diagnostic aimed at that condition.

Quality-reviewer auto-rejects any task in `.backlog/in-review/` whose transition log lacks at least one `clean-checkout | ok` line.

**Integration (default mode, 3.0.0 / LP-CAS)**: once the union gate passes, `integrate-lpcas` lands the
task's in-tree ledger marker (`.acfwhip/integrated/<shard>/<key>.json`) on trunk, in one single-parent
commit together with the change. The marker on trunk is the integration record; the integrator never
writes the task markdown.
If the union gate fails, the orchestrator moves the task to `.backlog/rejected/` (rejection +1),
and the usual rejection, retry and block handling takes over from there. A cherry-pick conflict goes
to a resolver as a mechanism fault; it is never dropped silently.

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

- **Purpose**: lists documentation that already exists, as input context
- **Not for**: output files this task will create (those go in Description)
- **Auto-loaded** (do not list): CLAUDE.md, agent manifests (docs/agents/*.md)
- **Verify**: task-engineer checks that every referenced file exists before it creates the task
- **Use "none"**: when the auto-loaded docs are enough
- **Planned tasks**: a task decomposed from an approved cycle plan (`/task --plan`) lists that plan with a
  `(D<n>, ...)` suffix naming the deliverables it implements: `docs/cycles/<ID>/plan.md (D2, D4)`. The
  field is still a path list; the suffix points at the `### D<n>` sections of that plan. `/task` stamps
  this value, so do not edit it by hand. Deliverable coverage is read from the cycle's `record.md`, never
  from this field, and `plan.md` is read-only for the task

**Examples**:
```markdown
# Foundation docs needed:
- **Documentation**: docs/architecture/system-architecture.md, docs/architecture/execution-platform.md

# Research relevant:
- **Documentation**: docs/research/temporal-workflow-patterns.md

# Decomposed from an approved plan (/task --plan): implements D2 and D4 of it
- **Documentation**: docs/cycles/20260928-owner-seat-notice/plan.md (D2, D4)

# Only CLAUDE.md needed:
- **Documentation**: none
```

### 1. Task Creation (task-engineer)

task-engineer must:

- use this exact template
- fill every required field
- verify that every file named in the Documentation field exists
- leave out implementation code
- commit the task file when it creates it

### 2. Task Pickup (implementation agents)

An implementation agent must:

- invoke `clean-checkout-before-task` as Step 0, with `TASK_FILE` set to the **root** path the
  orchestrator passed. The skill creates the worktree, validates the branch and appends the OK token
  to the root file.
- do every code read, edit and commit inside the worktree on `worktree/<slug>`, never on the trunk
  branch
- never move a task file between `.backlog/<state>/` folders; the orchestrator does that at the root
- never commit `.backlog/` changes on `worktree/<slug>`
- add evidence of completion to the root task file, writing the file directly at its root path
- end its response with the ACFW-RESULT marker (`transition: completed | blocked`)

### 3. Task Completion (implementation agents)

An implementation agent must:

- check every acceptance criterion
- run the quality gates and capture their output (see docs/development/quality-gates.md)
- add the evidence to the root task file **before** it returns the marker
- commit code, and only code, on `worktree/<slug>`
- return ACFW-RESULT with the final code commit SHA

### 4. Quality Review (quality-reviewer)

quality-reviewer must:

- invoke `clean-checkout-before-task` as Step 0 (idempotent; it validates the worktree the
  implementer used)
- verify that the transition log contains at least one `clean-checkout | ok` line, and emit
  `transition: rejected` with `rejection_increment: 1` if it does not
- add review comments in the designated section of the root task file
- end its response with the ACFW-RESULT marker (`transition: accepted | rejected`)
- never move the task file; the orchestrator performs the in-review→accepted/rejected move at the root
- when rejecting, give specific feedback in `notes` and in the Quality Review Comments section

---

## Git Commit Protocol

**Where commits land**:
- **task-engineer** commits on the trunk branch at the repo root: new tasks in `.backlog/pending/`, plus the retry, unblock and redesign moves on the legacy markdown loop. It never enters a worktree.
- **The `/go` orchestrator** commits every other `.backlog/` state move, on the trunk branch at the repo root: pending→in-progress, in-progress→completed/blocked, completed→in-review, in-review→accepted/rejected, and on the workflow path rejected→pending, rejected→blocked and blocked→pending. An operator's `/whip-move` also commits one move at a time, at the root.
- **Implementer specialists** commit only **code**, inside `.worktree/<slug>` on `worktree/<slug>`. quality-reviewer commits nothing. Neither moves task files or commits `.backlog/` changes on the worktree branch: they signal state through the ACFW-RESULT marker, and the orchestrator performs the move at the root.
- **`integrate-lpcas`** (driven by the orchestrator in default mode) cherry-picks each accepted task's single-parent candidate onto the live trunk and lands it by compare-and-swap, with a co-committed ledger marker. An override in `CLAUDE.md` (for example, a PR per group) is honored automatically.

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

**task-engineer must check**:
- All required fields populated
- Priority is a valid value (blocker|critical|high|medium|low)
- Dependencies exist or "none"
- Assigned agent exists and is valid for this project
- At least 3 acceptance criteria
- Technical requirements are specific
- Edge cases identified

**quality-reviewer must check**:
- All acceptance criteria have evidence
- Transition log complete
- Implementation notes present
- Quality gates evidence provided (language-appropriate)
- Version control log accurate
- Architecture compliance (service boundaries, event-driven patterns)

---

**Last Updated**: 2026-09-29
**Document Owner**: task-engineer
