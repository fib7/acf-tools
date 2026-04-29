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

## Worktree-Aware Commits

For any code-mutating task with a `Worktree:` field set, all implementer and quality-reviewer commits land on `worktree/<slug>` inside `.worktree/<slug>`, **never on `main`**. The implementer enters the worktree via the `clean-checkout-before-task` skill (Step 0). All subsequent `git add`/`git commit` operations execute inside that worktree. This is the mechanism that prevents `.git/index.lock` contention and pre-commit stash/unstash bundling defects when multiple specialists run in parallel.

Integration of `worktree/<slug>` into `main` (PR via `gh pr create` or fast-forward merge) is project-decided and outside the per-task commit protocol. The plugin does not prescribe an integration policy.

**Tasks WITHOUT a `Worktree:` field** (research-only or doc-only outside `docs/`-restricted scope) commit on `main` directly. task-engineer commits its task-creation files on `main`.

---

**Last Updated**: 2026-04-28
