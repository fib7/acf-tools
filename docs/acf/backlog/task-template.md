# Task Template

## MANDATORY: Use this exact format for all task files

```markdown
# Task: [Clear Task Title]

## Metadata

- **ID**: [category-XXX-descriptive-name]
- **Status**: pending
- **Priority**: [blocker|critical|high|medium|low]
- **Estimated Hours**: [realistic estimate]
- **Assigned Agent**: [go-engineer|python-ml-engineer|data-engineer|temporal-engineer|ml-ops-engineer|k8s-engineer|event-engineer|react-engineer|database-engineer|devops|test-engineer|quality-reviewer|task-engineer|retro|precommit|lean-architect]
- **Dependencies**: [task-id-1, task-id-2] or "none"
- **Rejection Count**: 0 (max 5; quality-reviewer increments on reject; after 5th rejection, task-engineer redesigns)
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

- MUST add transition log entry BEFORE starting work
- MUST commit task file when moving to in-progress
- MUST update implementation notes during work (commit after each update to avoid conflicts)
- MUST add evidence of completion

### 3. Task Completion (implementation agents)

- MUST check all acceptance criteria
- MUST run quality gates and capture output (see docs/development/quality-gates.md)
- MUST add evidence to task file BEFORE marking complete
- MUST update transition log
- MUST commit task file + implementation files together (atomic commit)

### 4. Quality Review (quality-reviewer)

- MUST add review comments in designated section
- MUST update transition log with decision
- MUST commit task file with review
- MUST provide specific feedback if rejected

---

## Git Commit Protocol

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
