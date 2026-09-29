# Git Commit Conventions

## Commit Message Format

```
<type>(<scope>): <subject>

[optional body]
```

**Types**: feat, fix, docs, style, refactor, perf, test, build, ci, chore

**Subject**: Imperative mood, no capitalization, no period, max 50 chars

## File Staging Rules

**FORBIDDEN**: `git add -A`, `git add .`, `git add --all`, `git commit -a`. Nothing blocks these automatically; the rule holds only if whoever commits follows it.

**MANDATORY**: stage every file by name.
```bash
# ✅ CORRECT - Explicit file staging
git add src/specific/file.go
git add services/user-api/handler.go
git add .backlog/in-progress/task-123.md
```

## Atomic Commits

- One task = one commit
- Commit after each completed task
- No "cleanup" commits
- Project builds after every commit

## Tool Trailers

`ACFW-*` trailers written by acf-whip are load-bearing: never strip, reword or squash them away (see docs/acf/backlog/workflow.md).

---

**Last Updated**: 2026-09-28
