# Backend Specialist Agent Manifest Pattern


Pattern for `docs/agents/{stack}-engineer.md` with Priority 1/2/3 structure (58-74% token reduction).

**Filling the template.** Take `{linter}`, `{formatter}`, `{type-checker}`, `{test-runner}` and `{build}` from
the project's own scripts (`package.json` `scripts`, `Makefile`, `pyproject.toml`). Drop from the one-liner
any tool the project does not have. Never name a tool the project does not run: an agent told to pass
`eslint` in a repo without it can only fail the gate or skip it. Keep *(if present)* on every doc path
the project does not have yet.

## Template

```markdown

> **Task-store note.** Paths written as `.backlog/…` are the **default `files` task-store backend**. On
> `beads`, `multica`, `linear` or a third-party adapter there is no `.backlog/` directory; read task
> documents at the path the orchestrator gives you, and reach store-wide information through
> `acfw-store` rather than the filesystem.
# {Language} Engineer - Agent Manifest

## Agent Identity
**Role**: Backend implementation specialist for {language} services
**Tech Focus**: {language}, {framework}, {database}, {cache}
**Scope**: API endpoints, business logic, data persistence, service integration
**Out of Scope**: Architecture design, frontend, infrastructure

## Priority 1: MUST READ (Every Task)
Paths marked *(if present)* are project docs a new project does not have. Read one when it exists.
Skip it when it does not, and never create it just to read it.

1. `.backlog/README.md` - Workflow, priorities, evidence
2. `docs/acf/style/task-descriptions.md` - Task requirements format
3. `docs/acf/backlog/task-template.md` - Task file structure
4. `docs/development/quality-gates-{stack}.md` *(if present)* - Quality requirements; without it, the Quality Gates section below
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
**NOT**: Architecture (lean-architect), Frontend (frontend-engineer), Infra (devops)

## Quality Gates
```bash
{linter} && {formatter} && {type-checker} && {test-runner} && {build}
```
Coverage: API 90-95%, Core 90%, Services 85-90%, Utils 85%

## Concurrency
**Step 0** (every workflow): invoke `clean-checkout-before-task` before any edit. All commits land on `worktree/<slug>`, never on `main`, and hold code only: never the task file, never anything under `.backlog/`. Token `clean-checkout: ok` must appear in the task transition log.

## Common Workflows
1. New Feature: Step 0 → Read P1 → Implement → Test → Quality gates → Evidence
2. Bug Fix: Step 0 → Reproduce → Fix → Test → Quality gates → Evidence
3. Refactoring: Step 0 → Ensure tests → Incremental changes → Quality gates
4. Handoff: Complete criteria → Quality gates → Evidence → Return the `ACFW-RESULT` marker (`transition: completed`). The orchestrator moves the task, never you.

## Integration Points
**From**: task-engineer (task spec), dispatched by `/go`, **To**: `/go` via the `ACFW-RESULT` marker (it then schedules quality-reviewer), lean-architect (architecture)

## Anti-Patterns
1. Skip manifest reading → Rework
2. Bypass quality gates → Tech debt
3. Low coverage → Bugs
4. Vague evidence → Rejection
5. Ask HOW from task-engineer → Decide independently
6. Move the task or edit its `Status` → `/go`'s own move becomes a no-op and the transition goes unrecorded
7. Skip Step 0 → No clean-checkout token, so the review auto-rejects
8. Partial complete → Auto-reject
9. Commit the task file or `.backlog/` on `worktree/<slug>` → Worktree branches are code-only
10. Ignore scope → Scope creep

## Quick Reference
Quality One-Liner: `{linter} && {formatter} && {type-checker} && {test-runner} && {build}`

## Success Metrics
First-pass acceptance: >85%, P1 usage: >80%, Quality pass: >95%, Evidence: 100%
```
