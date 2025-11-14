# Quality Gates

Universal zero-bypass quality enforcement patterns across tech stacks.

## Core Philosophy

**Zero Bypass Tolerance**: Quality gates are absolute. No `--no-verify`, no disabling rules, no lowering thresholds.

## Available Quality Gates

| Tech Stack | File | Status |
|------------|------|--------|
| **Next.js/TypeScript** | [nextjs-typescript.md](nextjs-typescript.md) | Ready to use |
| **Python/FastAPI** | [python-fastapi.md](python-fastapi.md) | Ready to use |
| **Go** | [go.md](go.md) | Ready to use |
| **Custom** | [template.md](template.md) | Template for your stack |

## Universal Structure

All quality gates follow this pattern:

1. **Zero Bypass Tolerance** - Absolute prohibition statement
2. **Quality Requirements** - Commands that must pass
3. **Code Standards** - Linting, type checking, formatting config
4. **Test Coverage** - Minimum coverage thresholds
5. **Pre-commit Hooks** - Automated enforcement
6. **Quality Gate Protocol** - Failure handling (10 attempts → blocked)
7. **Forbidden Bypass Methods** - Explicit list of prohibited practices
8. **Continuous Integration** - CI pipeline requirements

## Quick Reference

### Next.js/TypeScript
```bash
pnpm build          # Next.js build
pnpm typecheck      # TypeScript strict
pnpm lint           # ESLint
pnpm test --coverage # Jest/Vitest with coverage
```

### Python/FastAPI
```bash
uv run ruff check .           # Linting
uv run ruff format . --check  # Formatting
uv run mypy . --strict        # Type checking
uv run pytest --cov=src       # Tests with coverage
```

### Go
```bash
golangci-lint run ./...                 # Comprehensive linting
go test ./... -v -race -cover          # Tests with race detection
go build ./...                          # Build verification
```

## Failure Protocol (Universal)

1. **Attempts 1-10**: Fix actual issues
2. **After 10 attempts**: Move task to blocked with failure report

## Customization Guide

See [guidelines.md](guidelines.md) for creating quality gates for your tech stack.

## Key Principles

### 1. Zero Bypass Philosophy

Quality gates cannot be bypassed. Ever. This is non-negotiable.

**Why**: Bypassing quality gates creates technical debt, introduces bugs, and undermines team discipline.

**Enforcement**:
- Pre-commit hooks prevent bad commits
- CI blocks bad merges
- Code review catches manual bypasses

### 2. Failure Leads to Blocking

After 10 failed attempts, task moves to `blocked` status requiring human intervention.

**Why**: Prevents infinite loops of failed fixes. Forces architectural or requirement clarification.

### 3. Tech-Specific Commands

Each stack has specific tools. Don't mix paradigms.

**Examples**:
- TypeScript: `tsc --noEmit` (not "type checking")
- Python: `mypy --strict` (not "type hints validation")
- Go: `golangci-lint` (not "go vet")

### 4. Coverage Thresholds

Different code types have different criticality:

| Code Type | Coverage Threshold | Rationale |
|-----------|-------------------|-----------|
| **API endpoints** | 90-95% | Customer-facing, high impact |
| **Core logic** | 90% | Business logic must be verified |
| **Services** | 85-90% | Integration points need testing |
| **Utilities** | 85% | Support code, lower criticality |
| **UI components** | 80% | Visual testing supplements |

## Integration with ACF Workflow

Quality gates integrate with:

1. **Backlog Workflow**: Task cannot move from `completed` → `in-review` if gates fail
2. **Git Conventions**: Atomic commits require passing quality gates
3. **Parallel Execution**: Batch operations still enforce individual task quality
4. **Agent Responsibilities**: Each implementation agent knows their stack's gates

## References

- [Backlog Workflow](../backlog-workflow-template.md)
- [Git Commit Conventions](../git-commit-conventions-template.md)
- [Guidelines for Custom Gates](guidelines.md)
