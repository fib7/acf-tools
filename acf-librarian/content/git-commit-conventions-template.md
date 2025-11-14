# Git Commit Conventions

## Commit Message Format

```
<type>(<scope>): <subject>

[optional body]
```

**Types**: feat, fix, docs, style, refactor, perf, test, build, ci, chore

**Subject**: Imperative mood, no capitalization, no period, max 50 chars

## File Staging Rules (CRITICAL)

**STRICTLY FORBIDDEN** (no automated enforcement - manual discipline required):
- `git add -A` - NEVER
- `git add .` - NEVER
- `git add --all` - NEVER
- `git commit -a` - NEVER

**MANDATORY**:
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

---

**Last Updated**: 2025-10-27
