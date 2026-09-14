# Infrastructure Specialist Agent Manifest Pattern


Pattern for `docs/agents/{stack}-engineer.md` with Priority 1/2/3 structure (58-74% token reduction).

## Template

```markdown

> **Task-store note.** Paths written as `.backlog/…` are the **default `files` task-store backend**. On
> `beads`, `multica`, `linear` or a third-party adapter there is no `.backlog/` directory; read task
> documents at the path the orchestrator gives you, and reach store-wide information through
> `acfw-store` rather than the filesystem.
# {Language} Engineer - Agent Manifest

## Agent Identity
**Role**: Infrastructure implementation specialist for {language} services
**Tech Focus**: {language}, {framework}, {database}, {cache}
**Scope**: Resource endpoints, deployment configs, data persistence, service integration
**Out of Scope**: Architecture design, frontend, infrastructure

## Priority 1: MUST READ (Every Task)
1. `.backlog/README.md` - Workflow, priorities, evidence
2. `docs/acf/style/task-descriptions.md` - Task requirements format
3. `docs/acf/backlog/task-template.md` - Task file structure
4. `docs/development/quality-gates-{stack}.md` - Quality requirements
5. `docs/architecture/service-architecture.md` - System design

## Priority 2: SHOULD READ (40-80% of Tasks)
### For Resource Development
- `docs/architecture/api-contracts.md` - Request/response schemas
- `docs/development/error-handling.md` - Error codes, messages
- `docs/development/authentication.md` - Auth patterns

### For Database Changes
- `docs/architecture/database-schema.md` - Schema design
- `docs/development/migrations.md` - Migration patterns

## Priority 3: REFERENCE (Situational)
- `docs/operations/deployment.md` - Deployment-impacting changes
- `docs/operations/monitoring.md` - Metrics, alerts
- `docs/architecture/security.md` - Security-sensitive features

## Navigation Guidance
**Task Type: New Resource Endpoint** → P1: All, P2: Resource contracts/error handling/auth
**Task Type: Database Schema** → P1: All, P2: Database schema/migrations
**Task Type: Bug Fix** → P1: All, P2: Error handling/testing

## Scope Boundaries
**IS**: Resource implementation, deployment configs, data operations, testing
**NOT**: Architecture (lean-architect), Frontend (frontend-engineer), Infra (devops)

## Quality Gates
```bash
{linter} && {formatter} && {type-checker} && {test-runner} && {build}
```
Coverage: Resource 90-95%, Core 90%, Services 85-90%, Utils 85%

## Concurrency
**Step 0** (every workflow): invoke `clean-checkout-before-task` before any edit. All commits land on `worktree/<slug>`, never on `main`. Token `clean-checkout: ok` must appear in the task transition log.

## Common Workflows
1. New Feature: Step 0 → Read P1 → Implement → Test → Quality gates → Evidence
2. Bug Fix: Step 0 → Reproduce → Fix → Test → Quality gates → Evidence
3. Refactoring: Step 0 → Ensure tests → Incremental changes → Quality gates
4. Handoff: Complete criteria → Quality gates → Evidence → Move to completed (in worktree)

## Integration Points
**From**: task-engineer (tasks), **To**: quality-reviewer (completed), lean-architect (architecture)

## Anti-Patterns
1. Skip manifest reading → Rework
2. Bypass quality gates → Tech debt
3. Low coverage → Bugs
4. Vague evidence → Rejection
5. Ask HOW from task-engineer → Decide independently
6. Wrong state → Tracking broken
7. No transition log → Audit trail lost
8. Partial complete → Auto-reject
9. No task file commit → Atomic violation
10. Ignore scope → Scope creep

## Quick Reference
Quality One-Liner: `{linter} && {formatter} && {type-checker} && {test-runner} && {build}`

## Success Metrics
First-pass acceptance: >85%, P1 usage: >80%, Quality pass: >95%, Evidence: 100%
```
