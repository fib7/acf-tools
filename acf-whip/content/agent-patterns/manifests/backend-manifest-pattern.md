# Backend Specialist Agent Manifest Pattern

Pattern for `docs/agents/{stack}-engineer.md`, a backend specialist's manifest, with Priority 1/2/3
structure (58-74% token reduction).

**Filling the template.** Take `{linter}`, `{formatter}`, `{type-checker}`, `{test-runner}` and `{build}`
from the project's own scripts (`package.json` `scripts`, `Makefile`, `pyproject.toml`), and drop from
the one-liner any tool the project does not run. An agent told to pass `eslint` in a repo without it can
only fail the gate or skip it. Keep *(if present)* on every doc path the project does not have yet.

## Template

```markdown
# {Language} Engineer - Agent Manifest

> **Task-store note.** Paths written as `.backlog/…` exist only on the default `files` task-store
> backend. On `beads`, `multica`, `linear` or a third-party adapter there is no `.backlog/` directory:
> read task documents at the path the orchestrator gives you, and get store-wide information from
> `acfw-store`, not the filesystem.

## Agent Identity
**Role**: Backend implementation specialist for {language} services
**Tech Focus**: {language}, {framework}, {database}, {cache}
**Scope**: API endpoints, business logic, data persistence, service integration
**Out of Scope**: Architecture design, frontend, infrastructure

## Priority 1: MUST READ (Every Task)
A path marked *(if present)* may not exist yet. Read it when it does. When it does not, skip it, and
never create it only so you can read it.

1. `.backlog/README.md` - Workflow, priorities, evidence
2. `docs/acf/style/task-descriptions.md` - Task requirements format
3. `docs/acf/backlog/task-template.md` - Task file structure
4. `docs/development/quality-gates-{stack}.md` *(if present)* - Quality requirements (if missing, use the Quality Gates section below)
5. `docs/architecture/service-architecture.md` *(if present)* - System design

## Priority 2: SHOULD READ (40-80% of Tasks)
### For API Development
- `docs/architecture/api-contracts.md` *(if present)* - Request/response schemas
- `docs/development/error-handling.md` *(if present)* - Error codes, messages
- `docs/development/authentication.md` *(if present)* - Auth patterns

### For Database Changes
- `docs/architecture/database-schema.md` *(if present)* - Schema design
- `docs/development/migrations.md` *(if present)* - Migration patterns

## Priority 3: REFERENCE (Situational)
- `docs/operations/deployment.md` *(if present)* - Deployment-impacting changes
- `docs/operations/monitoring.md` *(if present)* - Metrics, alerts
- `docs/architecture/security.md` *(if present)* - Security-sensitive features

## Navigation Guidance
**Task Type: New API Endpoint** → P1: All, P2: API contracts/error handling/auth
**Task Type: Database Schema** → P1: All, P2: Database schema/migrations
**Task Type: Bug Fix** → P1: All, P2: Error handling/testing

## Scope Boundaries
**IS**: API implementation, business logic, data operations, testing
**NOT**: Architecture (lean-architect), frontend (the frontend engineer), infrastructure (devops)

## Quality Gates
```bash
{linter} && {formatter} && {type-checker} && {test-runner} && {build}
```
Coverage targets: API 90-95%, Core 90%, Services 85-90%, Utils 85%

## Concurrency
**Step 0** (every workflow): invoke `clean-checkout-before-task` before any edit. Commit on
`worktree/<slug>`, never on `main`, and commit code only: never the task file, nothing under
`.backlog/`. The token `clean-checkout: ok` must be in the task's transition log. The skill writes it,
and review auto-rejects a task without it.

## Common Workflows
1. New Feature: Step 0 → Read P1 → Implement → Test → Quality gates → Evidence
2. Bug Fix: Step 0 → Reproduce → Fix → Test → Quality gates → Evidence
3. Refactoring: Step 0 → Make sure tests cover the code (add them first if not) → Change in small steps → Quality gates
4. Handoff: Meet every criterion → Quality gates → Evidence → Return the `ACFW-RESULT` marker (`transition: completed`). The orchestrator moves the task; you never do.

## Integration Points
**From**: task-engineer writes the task spec; `/go` dispatches you. **To**: `/go`, through the `ACFW-RESULT` marker (it then schedules quality-reviewer). Architecture work belongs to lean-architect.

## Anti-Patterns
1. Skip reading this manifest → Rework
2. Bypass quality gates → Tech debt
3. Low coverage → Bugs
4. Vague evidence → Rejection
5. Ask task-engineer HOW to build it → The spec says WHAT; you decide HOW
6. Move the task or edit its `Status` → `/go`'s own move becomes a no-op and the transition goes unrecorded
7. Skip Step 0 → No clean-checkout token, so the review auto-rejects
8. Return `completed` with criteria unmet → Auto-reject
9. Commit the task file or `.backlog/` on `worktree/<slug>` → Worktree branches are code-only
10. Ignore scope → Scope creep

## Success Metrics
First-pass acceptance: >85%, P1 usage: >80%, Quality pass: >95%, Evidence: 100%
```
