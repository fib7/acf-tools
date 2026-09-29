# Quality Gates

Universal zero-bypass quality enforcement patterns across tech stacks.

## Core Philosophy

**Zero Bypass Tolerance**: Quality gates are absolute. No `--no-verify`, no disabling rules, no lowering thresholds.

## Available Quality Gates

| Tech Stack | File | Status |
|------------|------|--------|
| **Node.js** (plain Node, Express, Fastify, NestJS, React, Vue) | [nodejs.md](nodejs.md) | Ready to use |
| **Next.js/TypeScript** | [nextjs-typescript.md](nextjs-typescript.md) | Ready to use |
| **Python/FastAPI** | [python-fastapi.md](python-fastapi.md) | Ready to use |
| **Go** | [go.md](go.md) | Ready to use |
| **Custom** | [template.md](template.md) | Template for your stack |

## Which Doc a Project Gets

`/whip-init` and `/whip-add-agents` pick the doc with [detect-stack.sh](detect-stack.sh), run from the
project root. It prints `gate_stack` (which `.pre-commit-config-<gate_stack>.yaml` to install and the
backend's `docs/development/quality-gates-<gate_stack>.md` destination) and `gates_doc` (the source
file here):

| Detected | gate_stack | gates_doc |
|----------|------------|-----------|
| `go.mod` | go | go.md |
| `requirements.txt`, `pyproject.toml`, `setup.py`, `setup.cfg` or `Pipfile` | python | python-fastapi.md |
| `package.json` with `next` | nodejs | nextjs-typescript.md |
| any other `package.json`, including one with no framework at all | nodejs | nodejs.md |

First match wins, top to bottom: a Go module with a `package.json` for tooling gets the Go gates.

A frontend gets gates of its own. Whenever `package.json` has `next`, `react` or `vue`, the detector
also prints `frontend_gate_stack=nodejs` and `frontend_gates_doc` (`nextjs-typescript.md` for Next.js,
`nodejs.md` otherwise), installed as `docs/development/quality-gates-nodejs.md`. So in a FastAPI plus
React repo the python-engineer reads the Python gates and the react-engineer reads the Node.js gates.
When the backend is Node.js too, both are the same file.

`--backend=<stack>` and `--frontend=<stack>` override detection for that slot, so a skill's flags
pick the gates. A stack with no shipped doc (`--backend=rust`) gets an empty `gate_stack`.

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

### Node.js
```bash
npm test                          # the project's own runner (node --test, jest, vitest)
npm run lint --if-present         # only when package.json defines it
npm run typecheck --if-present    # TypeScript projects
npm run build --if-present        # projects with a build step
```

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
